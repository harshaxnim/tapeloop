#if os(macOS)
    import AppKit
    import Foundation
    import TapeloopAudio
    import TapeloopCore
    import TapeloopExport
    import TapeloopUI
    import os

    /// The app's brain: owns the recorder engine and the settings, feeds the popover, saves recordings, keeps
    /// bookmarks and meetings, and reacts to sleep, screen lock, app launches and quit. Main actor only.
    @MainActor
    final class AppController {
        let log = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "app")
        let engine: RecorderEngine
        let popover: PopoverModel
        private(set) var settings: AppSettings
        private(set) var status: RecorderEngine.Status
        /// Bookmarks inside the buffer (older ones age out with it).
        private(set) var bookmarks: [Bookmark] = []
        /// Meetings seen while recording (from the meeting detector).
        var meetings: [MeetingSpan] = [] {
            didSet { refresh() }
        }
        private var saveTask: Task<Void, Never>?
        private var savingLabel = ""
        private var savingProgress = 0.0
        private var suspendReasons: Set<String> = []
        private var pausedAt: Date?
        private var observers: [NSObjectProtocol] = []
        private var timer: Timer?

        /// Called after anything the menu bar icon or menu shows may have changed.
        var onChange: (() -> Void)?
        /// Meetings, calendar titles and transcription.
        private(set) lazy var intelligence = Intelligence(controller: self)
        /// Window openers, set by the app delegate.
        var openLibrary: (URL?) -> Void = { _ in }
        var openSettings: (String?) -> Void = { _ in }
        /// Called after a file was saved (the Library reloads; transcription may start).
        var didSave: (ExportResult, RecordingMetadata) -> Void = { _, _ in }
        /// Whether the popover is open (it refreshes every second while open).
        var popoverIsOpen = false {
            didSet {
                guard popoverIsOpen != oldValue else { return }
                // The timeline moves once a second only while it is visible; otherwise nothing wakes the app.
                timer?.invalidate()
                timer = nil
                guard popoverIsOpen else { return }
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                timer.tolerance = 0.2
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        }

        private static let settingsKey = "appSettings"

        init() {
            let loaded = Self.loadSettings()
            settings = loaded
            let spill = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(TapeloopInfo.bundleIdentifier, isDirectory: true)
                .appendingPathComponent("spill", isDirectory: true)
            engine = RecorderEngine(
                settings: loaded.recorder, spillFolder: spill,
                options: .init(inputDeviceUID: loaded.inputDeviceUID, excludedBundleIDs: loaded.excludedBundleIDs))
            status = engine.status()
            popover = PopoverModel(
                state: PopoverState(
                    status: .paused, title: "Starting…", timeline: TimelineData(start: Date(), end: Date())))
            engine.onChange = { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
            wirePopoverActions()
            // Set up before the first-run guide, where the model can already be downloaded.
            intelligence.models.onChange = { [weak self] state in
                Task { @MainActor in self?.intelligence.modelStateChanged(state) }
            }
        }

        // MARK: - Lifecycle

        /// Starts recording and starts watching the system.
        func start() {
            Task { await engine.start() }
            let workspace = NSWorkspace.shared.notificationCenter
            observe(workspace, NSWorkspace.willSleepNotification) { $0.suspend(true, reason: "sleep") }
            observe(workspace, NSWorkspace.didWakeNotification) { $0.suspend(false, reason: "sleep") }
            observe(workspace, NSWorkspace.didLaunchApplicationNotification) { controller in
                // A newly launched app that is excluded: rebuild the tap so its sound is left out too.
                if !controller.settings.excludedBundleIDs.isEmpty {
                    controller.engine.setOptions(controller.sourceOptions)
                }
            }
            let distributed = DistributedNotificationCenter.default()
            observe(distributed, Notification.Name("com.apple.screenIsLocked")) { controller in
                if controller.settings.pauseWhenLocked { controller.suspend(true, reason: "lock") }
            }
            observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.suspend(false, reason: "lock") }
            intelligence.apply(settings.meetings)
            intelligence.applyTranscription()
            HotKeys.shared.onAction = { [weak self] action in self?.perform(action) }
            HotKeys.shared.register(settings.shortcuts)
        }

        private func observe(
            _ center: NotificationCenter, _ name: Notification.Name,
            _ handler: @escaping @MainActor (AppController) -> Void
        ) {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if let self { handler(self) }
                    }
                })
        }

        /// Deletes the buffer (RAM and the opt-in disk part). Call on quit.
        func shutdown() {
            saveTask?.cancel()
            intelligence.stop()
            engine.wipe()
        }

        private func suspend(_ on: Bool, reason: String) {
            if on { suspendReasons.insert(reason) } else { suspendReasons.remove(reason) }
            log.info("Suspend \(reason, privacy: .public): \(on)")
            engine.setSuspended(!suspendReasons.isEmpty)
        }

        // MARK: - Settings

        var sourceOptions: RecorderEngine.SourceOptions {
            .init(inputDeviceUID: settings.inputDeviceUID, excludedBundleIDs: settings.excludedBundleIDs)
        }

        /// Changes settings, saves them, and applies what changed.
        func update(_ change: (inout AppSettings) -> Void) {
            let old = settings
            change(&settings)
            guard settings != old else { return }
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Self.settingsKey)
            }
            if settings.recorder != old.recorder { engine.apply(settings.recorder) }
            if settings.inputDeviceUID != old.inputDeviceUID || settings.excludedBundleIDs != old.excludedBundleIDs {
                engine.setOptions(sourceOptions)
            }
            if settings.shortcuts != old.shortcuts { HotKeys.shared.register(settings.shortcuts) }
            if settings.meetings != old.meetings { intelligence.apply(settings.meetings) }
            if settings.transcription != old.transcription { intelligence.applyTranscription() }
            if !settings.pauseWhenLocked && suspendReasons.contains("lock") { suspend(false, reason: "lock") }
            refresh()
        }

        private static func loadSettings() -> AppSettings {
            let defaults = UserDefaults.standard
            if let data = defaults.data(forKey: settingsKey),
                let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
            {
                return settings
            }
            // Earlier builds stored only the recorder settings.
            var settings = AppSettings()
            if let data = defaults.data(forKey: "recorderSettings"),
                let recorder = try? JSONDecoder().decode(RecorderSettings.self, from: data)
            {
                settings.recorder = recorder
            }
            return settings
        }

        // MARK: - Status

        func refresh() {
            status = engine.status()
            if (status.levels[.system] ?? 0) > 0.0005, !UserDefaults.standard.bool(forKey: "systemAudioHeard") {
                UserDefaults.standard.set(true, forKey: "systemAudioHeard")
            }
            if status.isPaused, pausedAt == nil { pausedAt = Date() } else if !status.isPaused { pausedAt = nil }
            if let start = status.range?.start {
                bookmarks.removeAll { $0.date < start }
                intelligence.trimLive(before: start)
            }
            popover.state = makePopoverState(now: Date())
            onChange?()
        }

        /// The status as the menu bar icon shows it.
        var iconStatus: RecorderStatus {
            if status.needsAttention { return .needsAttention }
            return status.isRecording ? .recording : .paused
        }

        /// The held span in seconds.
        var held: TimeInterval {
            guard let range = status.range else { return 0 }
            return max(0, Date().timeIntervalSince(range.start))
        }

        /// The ongoing meeting, if any.
        var ongoingMeeting: MeetingSpan? { meetings.last { $0.isOngoing } }

        /// One line for the menu's header: "Recording to memory · 2 h kept · 41 MB".
        var menuHeader: String {
            let state = popover.state
            return [state.title, state.stat].compactMap { $0 }.joined(separator: " · ")
        }

        private func makePopoverState(now: Date) -> PopoverState {
            let held = self.held
            let spanMax = settings.recorder.bufferDuration
            let span = TimelineData.niceSpan(for: held, maximum: spanMax)
            let start = now.addingTimeInterval(-span)
            let kinds = SourceKind.allCases.filter { settings.recorder.sources.contains($0) }
            let tracks = kinds.map { engine.levelTrack(for: $0) }
            let lanes = zip(kinds, tracks).map { kind, track in
                TimelineData.Lane(
                    label: kind == .microphone ? "You" : "System",
                    levels: TimelineData.bin(track, from: start, to: now, count: 120))
            }
            let meetingSpans: [TimelineData.Span] =
                settings.meetings.showOnTimeline
                ? meetings.map { meeting in
                    let label =
                        meeting.isOngoing
                        ? "\(meeting.info.appName) · now" : "\(meeting.info.appName) · \(Self.time(meeting.start))"
                    return .init(start: meeting.start, end: meeting.end ?? now, label: label)
                } : []
            var timeline = TimelineData(
                start: start, end: now, heldStart: status.range?.start, lanes: lanes, meetings: meetingSpans,
                bookmarks: bookmarks.map { .init(date: $0.date, label: $0.label) },
                gaps: TimelineData.gaps(in: tracks).filter { $0.end > start })
            if held <= 0 { timeline.heldStart = nil }

            let mb = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .decimal) }
            let kept = held > 0 ? "\(DurationText.long(held)) kept" : nil
            var state: PopoverState
            if let problem = problemBanner() {
                state = PopoverState(
                    status: .needsAttention, title: problem.title, stat: kept, banner: problem.banner,
                    timeline: timeline,
                    isPaused: status.isPaused)
            } else if status.isPaused || !status.isRecording {
                let since = pausedAt.map { "Paused at \(Self.time($0)). " } ?? ""
                state = PopoverState(
                    status: .paused, title: "Paused",
                    stat: [kept, held > 0 ? mb(status.bytesInRAM) : nil].compactMap { $0 }.joined(separator: " · "),
                    subtitle: suspendReasons.isEmpty || status.isPaused
                        ? "\(since)Nothing is being recorded."
                        : "Recording pauses while the Mac sleeps or the screen is locked.",
                    timeline: timeline, isPaused: status.isPaused)
            } else if status.bytesOnDisk > 0 {
                let ramPart = held * Double(status.bytesInRAM) / Double(max(1, status.bytesInRAM + status.bytesOnDisk))
                state = PopoverState(
                    status: .recording, title: "Recording to memory and disk", stat: kept,
                    subtitle:
                        "Newest \(DurationText.long(ramPart)) in memory (\(mb(status.bytesInRAM))) · older \(DurationText.long(held - ramPart)) on disk (\(mb(status.bytesOnDisk))), erased on quit.",
                    timeline: timeline)
            } else {
                let subtitle =
                    held < 600
                    ? "Started at \(Self.time(status.range?.start ?? now)). Keeps up to \(DurationText.long(settings.recorder.bufferDuration)); older audio is dropped as new audio arrives."
                    : "Nothing is written to disk until you save."
                state = PopoverState(
                    status: .recording, title: "Recording to memory",
                    stat: [kept, mb(status.bytesInRAM)].compactMap { $0 }.joined(separator: " · "), subtitle: subtitle,
                    timeline: timeline)
            }
            if state.banner == nil, let meeting = ongoingMeeting {
                let minutes = DurationText.long(now.timeIntervalSince(meeting.start))
                state.banner = .meeting(
                    id: meeting.id, title: "\(meeting.info.appName) meeting",
                    detail: "started \(Self.time(meeting.start)), \(minutes) so far",
                    calendarTitle: meeting.info.calendarTitle.map { "\($0) (from your calendar)" })
                state.subtitle = nil
            }
            if saveTask != nil { state.saving = .init(label: savingLabel, progress: savingProgress) }
            return state
        }

        private func problemBanner() -> (title: String, banner: PopoverState.Banner)? {
            let mic = status.sources[.microphone] ?? .off
            let system = status.sources[.system] ?? .off
            if mic == .needsPermission {
                return (
                    "Your microphone is not being recorded",
                    .problem(
                        message: "Tapeloop needs the Microphone permission to record your side of conversations."
                            + (system == .running ? " System audio is still recorded." : ""),
                        fixLabel: "Open System Settings",
                        alternativeLabel: settings.recorder.sources.contains(.system) ? "Record system audio only" : nil
                    )
                )
            }
            if case .failed(let reason) = system {
                return (
                    "System audio is not being recorded",
                    .problem(
                        message: reason
                            + " Tapeloop needs the System Audio Recording permission to hear the other side of calls.",
                        fixLabel: "Open System Settings",
                        alternativeLabel: settings.recorder.sources.contains(.microphone)
                            ? "Record microphone only" : nil)
                )
            }
            if case .failed(let reason) = mic {
                return (
                    "Your microphone is not being recorded",
                    .problem(message: reason, fixLabel: "Open Settings", alternativeLabel: nil)
                )
            }
            return nil
        }

        static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

        // MARK: - Actions

        private func wirePopoverActions() {
            var actions = PopoverActions()
            actions.save = { [weak self] seconds in self?.saveLast(seconds: seconds) }
            actions.cancelSave = { [weak self] in self?.saveTask?.cancel() }
            actions.togglePause = { [weak self] in self?.togglePause() }
            actions.bookmark = { [weak self] in self?.addBookmark() }
            actions.labelBookmark = { [weak self] date, label in self?.labelBookmark(at: date, label) }
            actions.saveMeeting = { [weak self] id in self?.saveMeeting(id: id) }
            actions.fixProblem = { [weak self] in self?.openPrivacySettings() }
            actions.problemAlternative = { [weak self] in self?.dropFailingSource() }
            actions.openLibrary = { [weak self] in self?.openLibrary(nil) }
            actions.openSettings = { [weak self] in self?.openSettings(nil) }
            popover.actions = actions
        }

        func perform(_ action: HotKeys.Action) {
            switch action {
            case .save: saveLast(seconds: Double(settings.shortcutSaveMinutes) * 60)
            case .bookmark:
                if let date = addBookmark() {
                    Notifier.shared.post(.bookmarked(time: Self.time(date)))
                }
            case .pause: togglePause()
            case .openPopover: NotificationCenter.default.post(name: .tapeloopOpenPopover, object: nil)
            }
        }

        func togglePause() {
            engine.setPaused(!engine.isPaused)
            refresh()
        }

        @discardableResult
        func addBookmark(label: String? = nil) -> Date? {
            guard status.isRecording else { return nil }
            let date = Date()
            bookmarks.append(Bookmark(date: date, label: label))
            refresh()
            return date
        }

        func labelBookmark(at date: Date, _ label: String) {
            guard let index = bookmarks.lastIndex(where: { abs($0.date.timeIntervalSince(date)) < 0.5 }) else { return }
            bookmarks[index].label = label
            refresh()
        }

        func openPrivacySettings() {
            let mic = status.sources[.microphone] == .needsPermission
            let anchor = mic ? "Privacy_Microphone" : "Privacy_ScreenCapture"
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
                NSWorkspace.shared.open(url)
            }
        }

        /// The popover's alternative: stop asking for the source that cannot record.
        func dropFailingSource() {
            let mic = status.sources[.microphone] ?? .off
            update { settings in
                if mic == .needsPermission || { if case .failed = mic { return true } else { return false } }() {
                    settings.recorder.sources.remove(.microphone)
                } else {
                    settings.recorder.sources.remove(.system)
                }
            }
        }

        // MARK: - Saving

        var isSaving: Bool { saveTask != nil }

        func saveLast(seconds: TimeInterval) {
            let now = Date()
            save(range: TimeRange(start: now.addingTimeInterval(-min(seconds, max(1, held))), end: now))
        }

        func saveMeeting(id: UUID) {
            guard let meeting = meetings.first(where: { $0.id == id }) else { return }
            save(range: meeting.range(now: Date()), meeting: meeting.info)
        }

        /// Saves `range` in the background with progress; posts a notification when done.
        func save(
            range: TimeRange, meeting explicitMeeting: MeetingInfo? = nil, then: (@MainActor (Bool) -> Void)? = nil
        ) {
            guard saveTask == nil else { return }
            let pieces = engine.exportPieces(for: range)
            guard !pieces.isEmpty else {
                Notifier.shared.post(.nothingToSave)
                then?(false)
                return
            }
            let meeting = explicitMeeting ?? bestMeeting(for: range)
            let marks = bookmarks.filter { range.contains($0.date) }
            let request = ExportRequest(
                range: range, sources: [], folder: settings.recorder.saveFolder,
                title: meeting.map { $0.calendarTitle ?? "\($0.appName) meeting" }, mix: settings.recorder.mixSources)
            savingLabel = "Saving \(DurationText.long(range.duration))…"
            savingProgress = 0
            log.info("Saving \(range.duration, privacy: .public) s")
            let progress: @Sendable (Double) -> Void = { [weak self] value in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.saveTask != nil, value - self.savingProgress >= 0.01 || value >= 1 else {
                            return
                        }
                        self.savingProgress = value
                        if self.popoverIsOpen {
                            self.popover.state.saving = .init(label: self.savingLabel, progress: value)
                        }
                    }
                }
            }
            saveTask = Task { [weak self] in
                let (outcome, sources) = await Self.export(request, pieces: pieces, progress: progress)
                guard let self else { return }
                self.saveTask = nil
                let ok = self.finishSave(outcome, sources: sources, meeting: meeting, bookmarks: marks)
                then?(ok)
            }
            refresh()
        }

        /// The meeting overlapping `range` the most, if it covers at least half of the shorter of the two.
        private func bestMeeting(for range: TimeRange) -> MeetingInfo? {
            let now = Date()
            return meetings.compactMap { meeting -> (MeetingInfo, TimeInterval)? in
                let span = meeting.range(now: now)
                guard let overlap = span.intersection(range)?.duration,
                    overlap >= 0.5 * min(span.duration, range.duration)
                else { return nil }
                return (meeting.info, overlap)
            }
            .max { $0.1 < $1.1 }?.0
        }

        /// Reads spilled audio back and writes the files, off the main thread and outside the engine's locks.
        nonisolated private static func export(
            _ request: ExportRequest, pieces: [ExportPieces], progress: @escaping @Sendable (Double) -> Void
        ) async -> (Result<ExportResult, Error>, [ExportSource]) {
            let task = Task.detached(priority: .userInitiated) {
                var full = request
                full.sources = pieces.map {
                    ExportSource(
                        source: $0.source, chunks: $0.loadChunks(), streamDescription: $0.streamDescription,
                        magicCookie: $0.magicCookie)
                }
                return (Result { try Exporter.save(full, progress: progress) }, full.sources)
            }
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }

        private func finishSave(
            _ outcome: Result<ExportResult, Error>, sources: [ExportSource], meeting: MeetingInfo?,
            bookmarks marks: [Bookmark]
        ) -> Bool {
            defer { refresh() }
            switch outcome {
            case .success(let result):
                let names = result.files.map(\.lastPathComponent).joined(separator: ", ")
                log.info("Saved \(names, privacy: .public)")
                let metadata = RecordingMetadata(
                    start: result.range.start, duration: result.range.duration, sources: result.sources,
                    mixed: result.files.count == 1 && result.sources.count > 1, meeting: meeting,
                    bookmarks: marks.map {
                        RecordingBookmark(offset: $0.date.timeIntervalSince(result.range.start), label: $0.label)
                    })
                let store = LibraryStore(folder: settings.recorder.saveFolder)
                for (index, file) in result.files.enumerated() {
                    var fileMetadata = metadata
                    if result.files.count > 1, index < result.sources.count {
                        fileMetadata.sources = [result.sources[index]]
                    }
                    do {
                        try store.save(fileMetadata, for: file)
                    } catch {
                        log.error(
                            "Metadata not written for \(file.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                        )
                    }
                }
                didSave(result, metadata)
                intelligence.recordingSaved(result, pieces: sources)
                Notifier.shared.post(
                    .saved(length: DurationText.long(result.range.duration), names: names, file: result.files[0]))
                return true
            case .failure(let error):
                if case Exporter.ExportError.cancelled = error {
                    log.info("Save cancelled")
                    return false
                }
                log.error("Save failed: \(String(describing: error), privacy: .public)")
                Notifier.shared.post(.saveFailed(reason: "\(error)"))
                return false
            }
        }
    }

    extension Notification.Name {
        /// Ask the app delegate to open the popover (from the global shortcut).
        static let tapeloopOpenPopover = Notification.Name("io.github.harshaxnim.tapeloop.openPopover")
    }
#endif
