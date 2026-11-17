#if os(macOS)
    @preconcurrency import AVFoundation
    import Foundation
    import TapeloopCore

    /// The always-on recorder: runs the enabled sources, keeps each one's compressed rolling buffer, and hands out
    /// what a save needs.
    ///
    /// Thread-safe. Capture happens on audio threads; everything else may be called from any thread (the app calls
    /// it from the main actor). It reports changes through `onChange`, on the main queue.
    public final class RecorderEngine: @unchecked Sendable {
        /// The state of one source.
        public enum SourceState: Equatable, Sendable {
            /// Not enabled in Settings.
            case off
            /// Enabled and capturing.
            case running
            /// Enabled but paused by the user (or by sleep / a locked screen).
            case paused
            /// Enabled but the permission is missing.
            case needsPermission
            /// Enabled but it failed; the text says why.
            case failed(String)
        }

        /// A summary for the UI, taken at one moment.
        public struct Status: Sendable {
            /// Each enabled source's state.
            public var sources: [SourceKind: SourceState]
            /// Whether the user paused recording.
            public var isPaused: Bool
            /// Bytes held in RAM, all sources.
            public var bytesInRAM: Int
            /// Bytes held on disk, all sources (opt-in spill).
            public var bytesOnDisk: Int
            /// The span the buffer covers, all sources together.
            public var range: TimeRange?
            /// The most recent half-second level per source (0 to 1).
            public var levels: [SourceKind: Float]
            /// When each source last heard sound above the silence threshold.
            public var lastSoundAt: [SourceKind: Date]
            /// A disk problem, if the spill failed.
            public var diskError: String?
            /// The plan in force (RAM only, spill, or shortened).
            public var plan: MemoryBudget.Plan

            /// Whether at least one source is capturing.
            public var isRecording: Bool { sources.values.contains(.running) }
            /// Whether something needs the user's attention (a missing permission or a failure).
            public var needsAttention: Bool {
                sources.values.contains {
                    switch $0 {
                    case .needsPermission, .failed: true
                    default: false
                    }
                }
            }
        }

        private let lock = NSLock()
        private var settings: RecorderSettings
        private var sinks: [SourceKind: CaptureSink] = [:]
        private var sources: [SourceKind: any AudioSource] = [:]
        private var states: [SourceKind: SourceState] = [:]
        private var paused = false
        private var suspended = false
        private var pressureSource: DispatchSourceMemoryPressure?
        private let spillFolder: URL
        private let makeSource: @Sendable (SourceKind, SourceOptions) -> (any AudioSource)?
        private var options = SourceOptions()

        /// Device and exclusion choices that shape the sources.
        public struct SourceOptions: Equatable, Sendable {
            /// The microphone's device UID; `nil` follows the system default.
            public var inputDeviceUID: String?
            /// Apps left out of the system audio, by bundle ID.
            public var excludedBundleIDs: [String]

            /// Creates options.
            public init(inputDeviceUID: String? = nil, excludedBundleIDs: [String] = []) {
                self.inputDeviceUID = inputDeviceUID
                self.excludedBundleIDs = excludedBundleIDs
            }
        }

        /// Called on the main queue whenever the status may have changed.
        public var onChange: (@Sendable () -> Void)?

        /// Receives every captured PCM buffer (for live transcription), on the source's capture thread. It must copy
        /// what it needs and return quickly: the buffer is only valid during the call.
        public typealias PCMObserver = @Sendable (SourceKind, AVAudioPCMBuffer, Date) -> Void
        private let observerBox = ObserverBox()

        /// Sets or clears the PCM observer.
        public func setPCMObserver(_ observer: PCMObserver?) {
            observerBox.set(observer)
        }

        /// Creates the engine. Nothing runs until `start`.
        ///
        /// - Parameters:
        ///   - spillFolder: where the opt-in disk part lives (emptied on start and on `wipe`).
        ///   - makeSource: builds a source for a kind; tests inject fakes. The default builds the real microphone
        ///     and system audio sources.
        public init(
            settings: RecorderSettings, spillFolder: URL,
            options: SourceOptions = SourceOptions(),
            makeSource: @escaping @Sendable (SourceKind, SourceOptions) -> (any AudioSource)? = RecorderEngine
                .defaultSource
        ) {
            self.settings = settings
            self.spillFolder = spillFolder
            self.makeSource = makeSource
            self.options = options
        }

        /// The real sources: the microphone, and the system audio on macOS 14.2 or later.
        public static let defaultSource: @Sendable (SourceKind, SourceOptions) -> (any AudioSource)? = {
            kind, options in
            switch kind {
            case .microphone: return MicrophoneSource(deviceUID: options.inputDeviceUID)
            case .system:
                if #available(macOS 14.2, *) { return SystemAudioTap(excludingBundleIDs: options.excludedBundleIDs) }
                return nil
            }
        }

        /// Changes the microphone device or the excluded apps; the affected source restarts (a short gap).
        public func setOptions(_ newOptions: SourceOptions) {
            lock.lock()
            let old = options
            options = newOptions
            if old.inputDeviceUID != newOptions.inputDeviceUID, sources[.microphone] != nil {
                stopSource(.microphone)
                configure(.microphone)
            }
            let system = sources[.system]
            lock.unlock()
            if old.excludedBundleIDs != newOptions.excludedBundleIDs || old == newOptions {
                if #available(macOS 14.2, *), let tap = system as? SystemAudioTap {
                    tap.setExcludedBundleIDs(newOptions.excludedBundleIDs)
                }
            }
            notify()
        }

        /// The current settings.
        public var currentSettings: RecorderSettings {
            lock.lock()
            defer { lock.unlock() }
            return settings
        }

        /// Asks for the microphone permission when needed, then starts every enabled source.
        public func start() async {
            if currentSettings.sources.contains(.microphone) {
                _ = await MicrophoneSource.requestPermission()
            }
            lock.withLock {
                try? FileManager.default.removeItem(at: spillFolder)
                for kind in SourceKind.allCases { configure(kind) }
            }
            watchMemoryPressure()
            notify()
        }

        /// Stops every source and keeps the buffer (call `wipe` to delete it).
        public func stop() {
            lock.lock()
            for kind in SourceKind.allCases { stopSource(kind) }
            lock.unlock()
            pressureSource?.cancel()
            pressureSource = nil
            notify()
        }

        /// Pauses capture (the buffer is kept; the timeline shows a gap) or resumes it.
        public func setPaused(_ value: Bool) {
            lock.lock()
            guard paused != value else {
                lock.unlock()
                return
            }
            paused = value
            for kind in SourceKind.allCases where settings.sources.contains(kind) {
                if value {
                    stopSource(kind)
                    states[kind] = .paused
                } else if !suspended {
                    configure(kind)
                }
            }
            lock.unlock()
            notify()
        }

        /// Suspends capture for a system reason (sleep, a locked screen) without changing the user's pause choice.
        /// The buffer is kept; the timeline shows a gap.
        public func setSuspended(_ value: Bool) {
            lock.lock()
            guard suspended != value else {
                lock.unlock()
                return
            }
            suspended = value
            for kind in SourceKind.allCases where settings.sources.contains(kind) {
                if value {
                    stopSource(kind)
                    states[kind] = .paused
                } else {
                    configure(kind)
                }
            }
            lock.unlock()
            notify()
        }

        /// Whether the user paused recording.
        public var isPaused: Bool {
            lock.lock()
            defer { lock.unlock() }
            return paused
        }

        /// Applies new settings: starts or stops sources, changes the bit rate, and re-plans RAM and disk.
        public func apply(_ newSettings: RecorderSettings) {
            lock.lock()
            let old = settings
            settings = newSettings
            for kind in SourceKind.allCases {
                let wasOn = old.sources.contains(kind)
                let isOn = newSettings.sources.contains(kind)
                if wasOn && !isOn {
                    stopSource(kind)
                    sinks[kind]?.removeAll()
                    sinks[kind] = nil
                    states[kind] = .off
                } else if !wasOn && isOn {
                    configure(kind)
                } else if isOn, old.bitRate != newSettings.bitRate,
                    let encoder = try? AACEncoder(source: kind, bitRate: newSettings.bitRate)
                {
                    sinks[kind]?.replaceEncoder(encoder)
                }
            }
            let plan = newSettings.plan
            for sink in sinks.values { sink.apply(plan, spillFolder: spillFolder) }
            lock.unlock()
            notify()
        }

        /// What a save of `range` needs, per enabled source that has audio in it.
        public func exportPieces(for range: TimeRange) -> [ExportPieces] {
            lock.lock()
            let current = sinks.values.map { $0 }
            lock.unlock()
            return current.map { $0.exportPieces(overlapping: range) }
                .filter { !$0.ram.isEmpty || !$0.disk.isEmpty }
                .sorted { $0.source.rawValue < $1.source.rawValue }
        }

        /// The level track of a source, for the timeline.
        public func levelTrack(for kind: SourceKind) -> [(start: Date, duration: TimeInterval, levels: [Float])] {
            lock.lock()
            let sink = sinks[kind]
            lock.unlock()
            return sink?.levelTrack() ?? []
        }

        /// The current status.
        public func status() -> Status {
            lock.lock()
            let current = sinks
            var stateCopy = states
            let isPaused = paused
            let plan = settings.plan
            for kind in SourceKind.allCases where !settings.sources.contains(kind) { stateCopy[kind] = .off }
            lock.unlock()
            var status = Status(
                sources: stateCopy, isPaused: isPaused, bytesInRAM: 0, bytesOnDisk: 0, range: nil, levels: [:],
                lastSoundAt: [:], diskError: nil, plan: plan)
            for (kind, sink) in current {
                let snapshot = sink.snapshot()
                status.bytesInRAM += snapshot.bytes
                status.bytesOnDisk += snapshot.bytesOnDisk
                status.levels[kind] = snapshot.recentLevel
                status.lastSoundAt[kind] = snapshot.lastSoundAt
                status.diskError = status.diskError ?? snapshot.diskError
                if let range = snapshot.range {
                    status.range =
                        status.range.map {
                            TimeRange(start: min($0.start, range.start), end: max($0.end, range.end))
                        } ?? range
                }
            }
            return status
        }

        /// Stops capture and deletes all audio, RAM and disk. Call on quit.
        public func wipe() {
            stop()
            lock.lock()
            for sink in sinks.values { sink.removeAll() }
            sinks.removeAll()
            lock.unlock()
            try? FileManager.default.removeItem(at: spillFolder)
        }

        /// Frees RAM as if macOS reported memory pressure (also used by tests).
        public func relieveMemoryPressure(critical: Bool) {
            lock.lock()
            let current = sinks.values.map { $0 }
            lock.unlock()
            for sink in current { sink.relieveMemoryPressure(keepingFraction: critical ? 0.25 : 0.5) }
            Log.engine.notice(
                "Memory pressure (\(critical ? "critical" : "warning", privacy: .public)): buffer shortened")
            notify()
        }

        // MARK: - Private (call with the lock held unless noted)

        private func sink(for kind: SourceKind) -> CaptureSink? {
            if let existing = sinks[kind] { return existing }
            guard let encoder = try? AACEncoder(source: kind, bitRate: settings.bitRate) else { return nil }
            let sink = CaptureSink(encoder: encoder, maxDuration: settings.bufferDuration)
            sink.apply(settings.plan, spillFolder: spillFolder)
            sinks[kind] = sink
            return sink
        }

        private func configure(_ kind: SourceKind) {
            guard settings.sources.contains(kind) else {
                states[kind] = .off
                return
            }
            guard !paused && !suspended else {
                states[kind] = .paused
                return
            }
            guard sources[kind] == nil else { return }
            if kind == .microphone && !MicrophoneSource.isAuthorized {
                states[kind] = .needsPermission
                return
            }
            guard let sink = sink(for: kind), let source = makeSource(kind, options) else {
                states[kind] = .failed(
                    kind == .system
                        ? "Recording system audio needs macOS 14.2 or later." : "The encoder is unavailable.")
                return
            }
            do {
                try source.start(
                    onBuffer: { [observerBox] buffer, time in
                        sink.consume(buffer, at: time)
                        observerBox.current?(kind, buffer, time)
                    },
                    onEvent: { [weak self] event in self?.handle(event, from: kind) })
                sources[kind] = source
                states[kind] = .running
                Log.engine.info("\(kind.rawValue, privacy: .public) started")
            } catch {
                states[kind] = .failed("\(kind.label) could not start: \(error)")
                Log.engine.error(
                    "\(kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }

        private func stopSource(_ kind: SourceKind) {
            sources[kind]?.stop()
            sources[kind] = nil
            sinks[kind]?.flush()
        }

        /// Called from a source's thread, without the lock.
        private func handle(_ event: SourceEvent, from kind: SourceKind) {
            lock.lock()
            switch event {
            case .restarted(let message):
                Log.engine.info("\(message, privacy: .public)")
                sinks[kind]?.flush()
            case .failed(let message):
                Log.engine.error("\(message, privacy: .public)")
                sources[kind] = nil
                sinks[kind]?.flush()
                states[kind] = .failed(message)
            }
            lock.unlock()
            notify()
        }

        private func watchMemoryPressure() {
            guard pressureSource == nil else { return }
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
            source.setEventHandler { [weak self, weak source] in
                guard let event = source?.data else { return }
                self?.relieveMemoryPressure(critical: event.contains(.critical))
            }
            source.resume()
            pressureSource = source
        }

        /// Without the lock.
        private func notify() {
            guard let onChange else { return }
            DispatchQueue.main.async { onChange() }
        }
    }

    /// Holds the PCM observer behind its own lock, so capture threads read it without touching the engine's lock.
    final class ObserverBox: @unchecked Sendable {
        private let lock = NSLock()
        private var observer: RecorderEngine.PCMObserver?

        var current: RecorderEngine.PCMObserver? { lock.withLock { observer } }

        func set(_ observer: RecorderEngine.PCMObserver?) {
            lock.withLock { self.observer = observer }
        }
    }
#endif
