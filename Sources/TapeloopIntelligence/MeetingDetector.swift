#if os(macOS)
    import CoreAudio
    import Foundation
    import TapeloopCore

    /// A process that is currently capturing audio input.
    public struct AudioProcessInfo: Hashable, Sendable {
        /// The process id.
        public var pid: pid_t
        /// The process's bundle identifier; empty when it has none.
        public var bundleID: String

        /// Creates a value.
        public init(pid: pid_t, bundleID: String) {
            self.pid = pid
            self.bundleID = bundleID
        }
    }

    /// Lists the processes that are using audio input. The seam that lets tests replace Core Audio.
    public protocol AudioProcessProvider: Sendable {
        /// The processes whose audio input is running right now.
        func processesUsingInput() -> [AudioProcessInfo]
        /// Starts calling `onChange` on `queue` whenever the answer of ``processesUsingInput()`` may have changed.
        /// Returns `false` when the provider cannot do that; the detector then polls.
        func startWatching(on queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) -> Bool
        /// Stops the calls started by ``startWatching(on:onChange:)``.
        func stopWatching()
    }

    extension AudioProcessProvider {
        public func startWatching(on queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) -> Bool { false }
        public func stopWatching() {}
    }

    /// Reads Core Audio's process objects (macOS 14.2+): the system object's `kAudioHardwarePropertyProcessObjectList`,
    /// then each process's `kAudioProcessPropertyIsRunningInput`, `…BundleID` and `…PID`. Needs no permission.
    /// Below macOS 14.2 it returns nothing (see ``isSupported``).
    public final class CoreAudioProcessProvider: AudioProcessProvider, @unchecked Sendable {
        private let isInteresting: @Sendable (String) -> Bool
        private let lock = NSLock()
        /// Bundle IDs by process object (an object keeps its ID for the life of its process), so each poll costs one
        /// list read plus one input query per interesting process, not three queries per process.
        private var bundles: [AudioObjectID: String] = [:]
        /// Listeners while watching: the process list, and "is running input" of each interesting process.
        private let listenerQueue = DispatchQueue(
            label: "\(TapeloopInfo.bundleIdentifier).meetings.listen", autoreleaseFrequency: .workItem)
        private var watchQueue: DispatchQueue?
        private var onChange: (@Sendable () -> Void)?
        private var listBlock: AudioObjectPropertyListenerBlock?
        private var inputBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

        /// Creates a provider. Only processes whose bundle ID passes `isInteresting` are checked for input.
        public init(isInteresting: @escaping @Sendable (String) -> Bool = { _ in true }) {
            self.isInteresting = isInteresting
        }

        /// Whether this Mac has Core Audio process objects (macOS 14.2 or later).
        public static var isSupported: Bool {
            if #available(macOS 14.2, *) { true } else { false }
        }

        /// The processes whose audio input is running right now.
        public func processesUsingInput() -> [AudioProcessInfo] {
            guard #available(macOS 14.2, *) else { return [] }
            let objects = Self.processObjects()
            let known = lock.withLock { () -> [AudioObjectID: String] in
                // Forget processes that ended; learn the bundle IDs of new ones.
                bundles = bundles.filter { objects.contains($0.key) }
                return bundles
            }
            var learned: [AudioObjectID: String] = [:]
            var result: [AudioProcessInfo] = []
            for object in objects {
                let bundle: String
                if let cached = known[object] {
                    bundle = cached
                } else {
                    bundle = Self.string(object, kAudioProcessPropertyBundleID) ?? ""
                    learned[object] = bundle
                }
                guard isInteresting(bundle), Self.uint32(object, kAudioProcessPropertyIsRunningInput) == 1,
                    let pid = Self.pid(object)
                else { continue }
                result.append(AudioProcessInfo(pid: pid, bundleID: bundle))
            }
            if !learned.isEmpty { lock.withLock { bundles.merge(learned) { $1 } } }
            return result
        }

        /// Watches with Core Audio property listeners, so nothing runs while no meeting app changes its input.
        public func startWatching(on queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) -> Bool {
            guard #available(macOS 14.2, *) else { return false }
            stopWatching()
            // Listeners are delivered on a private queue and hop to `queue`, so adding and removing listeners
            // never happens inside a listener's own callback.
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                queue.async { [weak self] in
                    self?.refreshInputListeners()
                    onChange()
                }
            }
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            guard
                AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block) == noErr
            else { return false }
            lock.withLock {
                watchQueue = queue
                self.onChange = onChange
                listBlock = block
            }
            queue.async { [weak self] in self?.refreshInputListeners() }
            return true
        }

        public func stopWatching() {
            let (list, inputs) = lock.withLock {
                let taken = (listBlock, inputBlocks)
                listBlock = nil
                inputBlocks = [:]
                watchQueue = nil
                onChange = nil
                return taken
            }
            if let list {
                var address = Self.address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, list)
            }
            for (object, block) in inputs {
                var address = Self.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(object, &address, listenerQueue, block)
            }
        }

        /// Listens to "is running input" of every interesting process, and stops listening to ended ones.
        private func refreshInputListeners() {
            guard #available(macOS 14.2, *) else { return }
            let (queue, onChange, watched) = lock.withLock { (watchQueue, self.onChange, inputBlocks) }
            guard let queue, let onChange else { return }
            let objects = Self.processObjects()
            var current = watched
            for (object, block) in watched where !objects.contains(object) {
                var address = Self.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(object, &address, listenerQueue, block)
                current[object] = nil
            }
            for object in objects where current[object] == nil {
                let bundle =
                    lock.withLock { bundles[object] } ?? Self.string(object, kAudioProcessPropertyBundleID) ?? ""
                lock.withLock { bundles[object] = bundle }
                guard isInteresting(bundle) else { continue }
                let block: AudioObjectPropertyListenerBlock = { _, _ in queue.async { onChange() } }
                var address = Self.address(kAudioProcessPropertyIsRunningInput)
                if AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr {
                    current[object] = block
                }
            }
            lock.withLock { if watchQueue != nil { inputBlocks = current } }
        }

        @available(macOS 14.2, *)
        private static func processObjects() -> [AudioObjectID] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let system = AudioObjectID(kAudioObjectSystemObject)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
            var objects = [AudioObjectID](
                repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            let status = objects.withUnsafeMutableBytes { bytes in
                AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!)
            }
            guard status == noErr else {
                Log.meetings.error("Reading the process list failed: \(status)")
                return []
            }
            return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        }

        private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }

        private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
            var address = address(selector)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
        }

        private static func pid(_ object: AudioObjectID) -> pid_t? {
            guard #available(macOS 14.2, *) else { return nil }
            var address = address(kAudioProcessPropertyPID)
            var value: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
        }

        private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
            var address = address(selector)
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
            }
            guard status == noErr, let value else { return nil }
            return value.takeRetainedValue() as String
        }
    }

    /// A meeting starting or ending.
    public enum MeetingEvent: Equatable, Sendable {
        /// A meeting app has used the microphone for 5 s. The span's `start` is when its input began.
        case started(MeetingSpan)
        /// A meeting app has not used the microphone for 10 s. The span's `end` is when its input stopped, not when
        /// the 10 s ran out.
        case ended(MeetingSpan)

        /// The span the event is about.
        public var span: MeetingSpan {
            switch self {
            case .started(let span), .ended(let span): span
            }
        }
    }

    /// Notices meetings: a known meeting app (``MeetingApp``) capturing microphone input.
    ///
    /// It polls an ``AudioProcessProvider`` every `pollInterval` seconds on a private serial queue and debounces:
    /// a meeting starts once an app's input has been running for ``startDelay`` (5 s) without a break, and ends once
    /// its input has been off for ``endDelay`` (10 s), so muting, unmuting or switching devices does not split it.
    /// Several processes of one app (helpers) count as one; two different apps are tracked separately.
    /// Tapeloop's own process, which also records the microphone, is ignored.
    ///
    /// Thread-safe. `onEvent` is called on the detector's private queue, never on the main thread.
    public final class MeetingDetector: @unchecked Sendable {
        /// How long input must run before a meeting starts.
        public static let startDelay: TimeInterval = 5
        /// How long input must be off before a meeting ends.
        public static let endDelay: TimeInterval = 10

        /// Whether meeting detection works on this Mac (macOS 14.2 or later).
        public static var isSupported: Bool { CoreAudioProcessProvider.isSupported }

        /// The apps being watched.
        public let apps: [MeetingApp]
        private let pollInterval: TimeInterval
        private let provider: AudioProcessProvider
        private let clock: @Sendable () -> Date
        private let ownPID = getpid()
        private let queue = DispatchQueue(
            label: "\(TapeloopInfo.bundleIdentifier).meetings", autoreleaseFrequency: .workItem)

        private struct Track {
            /// When the current uninterrupted run of input began.
            var inputSince: Date
            /// The last poll that saw input.
            var lastSeen: Date
            /// When input stopped, while waiting out `endDelay`.
            var stoppedAt: Date?
            /// The meeting, once it has started.
            var span: MeetingSpan?
        }

        private let lock = NSLock()
        private var tracks: [String: Track] = [:]
        private var lastTick: Date?
        private var timer: DispatchSourceTimer?
        /// Whether the provider reports changes, so the timer is needed only while a meeting starts, runs or ends.
        private var eventDriven = false
        private var onEvent: (@Sendable (MeetingEvent) -> Void)?

        /// Creates a detector. Nothing happens until ``start(onEvent:)``.
        public init(
            apps: [MeetingApp] = MeetingApp.known, pollInterval: TimeInterval = 2,
            provider: AudioProcessProvider? = nil,
            clock: @escaping @Sendable () -> Date = Date.init
        ) {
            self.apps = apps
            self.pollInterval = max(0.1, pollInterval)
            self.provider =
                provider
                ?? CoreAudioProcessProvider(isInteresting: { MeetingApp.app(forBundleID: $0, in: apps) != nil })
            self.clock = clock
        }

        deinit { timer?.cancel() }

        /// The meetings going on now, oldest first.
        public var current: [MeetingSpan] {
            lock.withLock { tracks.values.compactMap(\.span).sorted { $0.start < $1.start } }
        }

        /// Starts polling. `onEvent` is called on a private serial queue. Calling it again replaces the handler.
        /// Below macOS 14.2 it logs and does nothing (check ``isSupported`` to tell the user).
        public func start(onEvent: @escaping @Sendable (MeetingEvent) -> Void) {
            lock.withLock { self.onEvent = onEvent }
            guard Self.isSupported || !(provider is CoreAudioProcessProvider) else {
                Log.meetings.notice("Meeting detection needs macOS 14.2 or later")
                return
            }
            provider.stopWatching()
            let watching = provider.startWatching(on: queue) { [weak self] in
                guard let self else { return }
                self.tick(now: self.clock())
            }
            lock.withLock { eventDriven = watching }
            queue.async { [weak self] in
                guard let self else { return }
                self.setPolling(!watching)
                self.tick(now: self.clock())
            }
            Log.meetings.info("Meeting detection started (\(watching ? "on changes" : "polling", privacy: .public))")
        }

        /// Stops polling and forgets ongoing meetings without sending `ended` events (turning detection off is not
        /// the end of a meeting).
        public func stop() {
            provider.stopWatching()
            let timer = lock.withLock {
                let timer = self.timer
                self.timer = nil
                eventDriven = false
                onEvent = nil
                tracks = [:]
                lastTick = nil
                return timer
            }
            timer?.cancel()
            Log.meetings.info("Meeting detection stopped")
        }

        /// One poll: reads the processes using input at `now`, updates the meetings and sends events.
        /// Called by the timer; tests call it directly to drive time. Returns the events it sent.
        @discardableResult
        func tick(now: Date) -> [MeetingEvent] {
            let processes = provider.processesUsingInput()
            var active: Set<String> = []
            var appsByID: [String: MeetingApp] = [:]
            for process in processes where process.pid != ownPID && !process.bundleID.isEmpty {
                guard let app = MeetingApp.app(forBundleID: process.bundleID, in: apps) else { continue }
                active.insert(app.id)
                appsByID[app.id] = app
            }
            let (events, handler, needsTimer) = lock.withLock {
                let events = update(active: active, apps: appsByID, now: now)
                // In event mode the timer only advances the start and end delays.
                return (events, onEvent, eventDriven ? !tracks.isEmpty : nil)
            }
            if let needsTimer { setPolling(needsTimer) }
            for event in events {
                switch event {
                case .started(let span):
                    Log.meetings.info("Meeting started: \(span.info.appName, privacy: .public)")
                case .ended(let span):
                    Log.meetings.info("Meeting ended: \(span.info.appName, privacy: .public)")
                }
                handler?(event)
            }
            return events
        }

        /// Runs the poll timer, or stops it.
        private func setPolling(_ on: Bool) {
            let old: DispatchSourceTimer? = lock.withLock {
                if on == (timer != nil) { return nil }
                let old = timer
                timer = nil
                if on {
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(250))
                    timer.setEventHandler { [weak self] in
                        guard let self else { return }
                        self.tick(now: self.clock())
                    }
                    self.timer = timer
                    timer.resume()
                }
                return old
            }
            old?.cancel()
        }

        /// The debounce state machine. Call with `lock` held.
        private func update(active: Set<String>, apps appsByID: [String: MeetingApp], now: Date) -> [MeetingEvent] {
            // Polls far apart (the Mac slept) mean we do not know what happened in between.
            let gap = lastTick.map { now.timeIntervalSince($0) } ?? 0
            let missedPolls = gap > pollInterval * 3
            lastTick = now
            var events: [MeetingEvent] = []

            for id in active {
                if var track = tracks[id] {
                    if track.span == nil, missedPolls { track.inputSince = now }
                    track.lastSeen = now
                    track.stoppedAt = nil
                    tracks[id] = track
                } else {
                    tracks[id] = Track(inputSince: now, lastSeen: now)
                }
                if var track = tracks[id], track.span == nil,
                    now.timeIntervalSince(track.inputSince) >= Self.startDelay,
                    let app = appsByID[id]
                {
                    let span = MeetingSpan(
                        start: track.inputSince, info: MeetingInfo(appName: app.name, bundleID: app.id))
                    track.span = span
                    tracks[id] = track
                    events.append(.started(span))
                }
            }

            for (id, var track) in tracks where !active.contains(id) {
                guard var span = track.span else {
                    tracks[id] = nil  // A blip shorter than startDelay.
                    continue
                }
                let stoppedAt = track.stoppedAt ?? (missedPolls ? track.lastSeen : now)
                track.stoppedAt = stoppedAt
                if now.timeIntervalSince(stoppedAt) >= Self.endDelay {
                    span.end = stoppedAt
                    events.append(.ended(span))
                    tracks[id] = nil
                } else {
                    tracks[id] = track
                }
            }
            return events.sorted { $0.span.start < $1.span.start }
        }
    }
#endif
