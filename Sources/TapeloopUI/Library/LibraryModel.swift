#if os(macOS)
    import AppKit
    import Foundation
    import Observation
    import TapeloopCore
    import UniformTypeIdentifiers

    /// One day's recordings in the Library's list.
    public struct LibraryGroup: Identifiable, Equatable, Sendable {
        /// The heading: "Today", "Yesterday", "Friday, 13 November".
        public var title: String
        /// The recordings, newest first.
        public var items: [LibraryRecording]
        /// The heading identifies the group.
        public var id: String { title }
    }

    /// A transcript file format.
    public enum TranscriptExportFormat: String, CaseIterable, Sendable {
        /// Plain text with a time before each line (`.txt`).
        case plainText
        /// SubRip subtitles (`.srt`).
        case subtitles

        /// The file name extension.
        public var fileExtension: String {
            switch self {
            case .plainText: "txt"
            case .subtitles: "srt"
            }
        }

        /// The menu item's title.
        public var menuTitle: String {
            switch self {
            case .plainText: "Plain Text (.txt)…"
            case .subtitles: "Subtitles (.srt)…"
            }
        }

        var contentType: UTType {
            switch self {
            case .plainText: .plainText
            case .subtitles: UTType(filenameExtension: "srt") ?? .plainText
            }
        }
    }

    /// The Library window's state: the recordings in the save folder, the search, the selection and its playback.
    ///
    /// The app creates one with a `LibraryStore`; snapshots and previews create one from a list of recordings (see
    /// `init(recordings:…)` and `sample()`), which never touches the disk.
    @MainActor
    @Observable
    public final class LibraryModel {
        /// Every recording, newest first.
        public internal(set) var recordings: [LibraryRecording] = []
        /// The search text.
        public var query = ""
        /// The selected recording's file.
        public private(set) var selectedURL: URL?
        /// Plays the selected recording.
        public let player = AudioPlayer()
        /// The selected recording's waveform (levels 0 to 1); `nil` while it loads.
        public private(set) var peaks: [Float]?
        /// A message for the user after an operation failed; the view shows it and clears it.
        public var errorMessage: String?
        /// The text under "No recordings yet". The app may replace it with one naming the actual shortcut.
        public var emptyStateMessage =
            "Tapeloop keeps the last stretch of your microphone and system audio in memory. When something worth "
            + "keeping happens, click the cassette in the menu bar and save it. Saved recordings appear here."

        /// The recordings being transcribed. The app adds a file when it starts and removes it when done; removing one
        /// reloads the list so the new transcript shows.
        public var transcribing: Set<URL> {
            get { transcribingStorage }
            set {
                let finished = transcribingStorage.subtracting(newValue)
                transcribingStorage = newValue
                if !finished.isEmpty { reload() }
            }
        }
        private var transcribingStorage: Set<URL> = []

        @ObservationIgnored private var store: LibraryStore?
        @ObservationIgnored private let onOpenSettings: @MainActor () -> Void
        @ObservationIgnored private let onTranscribe: (@MainActor (URL) -> Void)?
        @ObservationIgnored private let now: () -> Date
        @ObservationIgnored private let calendar: Calendar
        @ObservationIgnored private let isSample: Bool
        @ObservationIgnored private var peaksTask: Task<Void, Never>?
        @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
        @ObservationIgnored private var pendingReload: Task<Void, Never>?

        /// Creates the model for the recordings in `store`'s folder and loads them.
        /// - Parameters:
        ///   - onOpenSettings: Opens the Settings window (the empty state's button).
        ///   - onTranscribe: Starts transcribing a file. When `nil`, the Library offers no Transcribe button and
        ///     points to Settings instead.
        public init(
            store: LibraryStore, onOpenSettings: @escaping @MainActor () -> Void,
            onTranscribe: (@MainActor (URL) -> Void)? = nil
        ) {
            self.store = store
            self.onOpenSettings = onOpenSettings
            self.onTranscribe = onTranscribe
            self.now = { Date() }
            self.calendar = .current
            self.isSample = false
            reload()
        }

        /// Creates a model that shows `recordings` without reading or changing any file: renaming and deleting only
        /// change the list, and nothing plays. For snapshots and previews.
        public init(
            recordings: [LibraryRecording], now: Date = Date(), calendar: Calendar = .current,
            onOpenSettings: @escaping @MainActor () -> Void = {}, onTranscribe: (@MainActor (URL) -> Void)? = nil
        ) {
            self.store = nil
            self.onOpenSettings = onOpenSettings
            self.onTranscribe = onTranscribe
            self.now = { now }
            self.calendar = calendar
            self.isSample = true
            self.recordings = recordings.sorted { $0.start > $1.start }
            select(self.recordings.first?.url)
        }

        // MARK: - Listing

        /// The recordings that match the search, newest first.
        public var filtered: [LibraryRecording] {
            recordings.filter { LibraryStore.matches($0, query: query) }
        }

        /// The matching recordings grouped by day.
        public var filteredGroups: [LibraryGroup] {
            LibraryStore.groupedByDay(filtered, now: now(), calendar: calendar).map {
                LibraryGroup(title: $0.title, items: $0.items)
            }
        }

        /// The selected recording.
        public var selected: LibraryRecording? {
            guard let selectedURL else { return nil }
            return recordings.first { $0.url == selectedURL }
        }

        /// Whether the Library can start a transcription.
        public var canTranscribe: Bool { onTranscribe != nil }

        /// The calendar used for day headings and dates.
        public var displayCalendar: Calendar { calendar }

        /// Reads the folder again. Keeps the selection when the file is still there, else selects the newest.
        public func reload() {
            guard let store else { return }
            do {
                recordings = try store.recordings()
            } catch {
                LibraryLog.library.error("Cannot list the save folder: \(error.localizedDescription, privacy: .public)")
                recordings = []
                errorMessage = "The save folder cannot be read. \(error.localizedDescription)"
            }
            if let selectedURL, recordings.contains(where: { $0.url == selectedURL }) { return }
            select(recordings.first?.url)
        }

        /// Uses another save folder (after the user changed it in Settings) and reloads.
        public func setStore(_ store: LibraryStore) {
            let watching = watcher != nil
            stopWatching()
            self.store = store
            select(nil)
            reload()
            if watching { startWatching() }
        }

        /// Reloads by itself when files are added to, removed from or renamed in the save folder (for example in
        /// Finder). Call it when the window opens and `stopWatching()` when it closes.
        public func startWatching() {
            guard watcher == nil, let store else { return }
            let descriptor = open(store.folder.path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        }

        /// Stops watching the save folder.
        public func stopWatching() {
            watcher?.cancel()
            watcher = nil
            pendingReload?.cancel()
            pendingReload = nil
        }

        private func scheduleReload() {
            pendingReload?.cancel()
            pendingReload = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.reload()
            }
        }

        // MARK: - Selection

        /// Selects a recording (or nothing). Playback of the previous one stops.
        public func select(_ url: URL?) {
            guard url != selectedURL || (url != nil && player.url != url) else { return }
            selectedURL = url
            let item = selected
            if isSample {
                player.preview(url: url, currentTime: 0, duration: item?.duration ?? 0)
            } else {
                player.load(url, expectedDuration: item?.duration)
            }
            loadPeaks()
        }

        /// Shows a recording, for example after a notification was clicked: reloads if it is not listed yet, clears a
        /// search that hides it, selects it and optionally plays it.
        public func show(_ url: URL, play: Bool = false) {
            if !recordings.contains(where: { $0.url == url }) { reload() }
            guard recordings.contains(where: { $0.url == url }) else { return }
            if !filtered.contains(where: { $0.url == url }) { query = "" }
            select(url)
            if play { player.play() }
        }

        /// Selects the next recording in the list (down arrow).
        public func selectNext() { step(by: 1) }

        /// Selects the previous recording in the list (up arrow).
        public func selectPrevious() { step(by: -1) }

        private func step(by delta: Int) {
            let list = filtered
            guard !list.isEmpty else { return }
            guard let index = list.firstIndex(where: { $0.url == selectedURL }) else {
                return select(delta > 0 ? list.first?.url : list.last?.url)
            }
            select(list[min(list.count - 1, max(0, index + delta))].url)
        }

        private func loadPeaks() {
            peaksTask?.cancel()
            peaks = nil
            guard let url = selectedURL else { return }
            if isSample {
                peaks = Self.samplePeaks(seed: url.lastPathComponent)
                return
            }
            peaksTask = Task { [weak self] in
                let peaks = await WaveformCache.shared.peaks(for: url)
                guard !Task.isCancelled, let self, self.selectedURL == url else { return }
                self.peaks = peaks ?? []
            }
        }

        // MARK: - Playback

        /// Moves the selected recording's playhead to `time` seconds.
        public func seek(to time: TimeInterval) {
            player.seek(to: time)
        }

        /// Moves the playhead to a fraction (0 to 1) of the length.
        public func seek(toFraction fraction: Double) {
            player.seek(to: fraction * player.duration)
        }

        /// Moves the playhead to `time` seconds and plays.
        public func play(from time: TimeInterval) {
            player.seek(to: time)
            player.play()
        }

        // MARK: - Changing recordings

        /// Renames the selected recording.
        public func rename(to title: String) {
            guard let selectedURL else { return }
            rename(selectedURL, to: title)
        }

        /// Gives a recording a new title (and its file a matching name). An empty title goes back to the meeting
        /// title or the file name.
        public func rename(_ url: URL, to title: String) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = recordings.firstIndex(where: { $0.url == url }), trimmed != recordings[index].title,
                !transcribing.contains(url)
            else { return }
            guard let store else {
                if recordings[index].metadata != nil {
                    recordings[index].metadata?.title = trimmed.isEmpty ? nil : trimmed
                } else if !trimmed.isEmpty {
                    let renamed = url.deletingLastPathComponent().appendingPathComponent(trimmed + ".m4a")
                    recordings[index].url = renamed
                    if selectedURL == url { selectedURL = renamed }
                }
                return
            }
            if trimmed.isEmpty && recordings[index].metadata == nil { return }
            do {
                let newURL = try store.rename(url, to: trimmed)
                recordings[index].url = newURL
                recordings[index].metadata = store.metadata(for: newURL)
                if selectedURL == url {
                    selectedURL = newURL
                    player.fileMoved(to: newURL)
                }
                Task { await WaveformCache.shared.move(from: url, to: newURL) }
            } catch {
                LibraryLog.library.error("Rename failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = "The recording could not be renamed. \(error.localizedDescription)"
            }
        }

        /// Moves the selected recording to the Trash (ask the user first) and selects the next one in the list.
        public func deleteSelected() {
            guard let url = selectedURL else { return }
            let list = filtered
            var next: URL?
            if let index = list.firstIndex(where: { $0.url == url }) {
                next = index + 1 < list.count ? list[index + 1].url : (index > 0 ? list[index - 1].url : nil)
            }
            player.load(nil)
            if let store {
                do {
                    try store.delete(url)
                } catch {
                    LibraryLog.library.error("Delete failed: \(error.localizedDescription, privacy: .public)")
                    errorMessage = "The recording could not be moved to the Trash. \(error.localizedDescription)"
                    selectedURL = nil
                    select(url)
                    return
                }
                Task { await WaveformCache.shared.remove(url) }
            }
            recordings.removeAll { $0.url == url }
            selectedURL = nil
            select(next ?? recordings.first?.url)
        }

        // MARK: - Sharing and files

        /// Opens the share menu for the selected file below `view` (the Share button).
        public func share(from view: NSView) {
            guard let url = selectedURL else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }

        /// Shows the selected file in Finder.
        public func revealSelected() {
            guard let url = selectedURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        /// Opens a menu of transcript formats below `view` (the Export Transcript button).
        public func showExportMenu(from view: NSView) {
            let menu = NSMenu()
            for format in TranscriptExportFormat.allCases {
                let action = MenuAction { [weak self] in self?.exportTranscript(format: format) }
                let item = NSMenuItem(title: format.menuTitle, action: #selector(MenuAction.run), keyEquivalent: "")
                item.target = action
                item.representedObject = action
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }

        /// Asks where to save the selected recording's transcript in `format`, then writes it.
        public func exportTranscript(format: TranscriptExportFormat) {
            guard let item = selected, let transcript = item.metadata?.transcript else { return }
            let text =
                switch format {
                case .plainText: TranscriptFormatter.plainText(transcript, title: item.title)
                case .subtitles: TranscriptFormatter.srt(transcript)
                }
            let panel = NSSavePanel()
            panel.title = "Export Transcript"
            panel.nameFieldStringValue = RecordingName.sanitize(item.title) + "." + format.fileExtension
            panel.allowedContentTypes = [format.contentType]
            panel.canCreateDirectories = true
            panel.directoryURL = item.url.deletingLastPathComponent()
            let write: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    self?.errorMessage = "The transcript could not be saved. \(error.localizedDescription)"
                }
            }
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { response in MainActor.assumeIsolated { write(response) } }
            } else {
                write(panel.runModal())
            }
        }

        /// Starts transcribing the selected recording (the app does the work and updates `transcribing`).
        public func transcribeSelected() {
            guard let url = selectedURL, !transcribing.contains(url) else { return }
            onTranscribe?(url)
        }

        /// Opens Settings.
        public func openSettings() {
            onOpenSettings()
        }

        // MARK: - Sample data

        /// Synthetic, repeatable waveform levels for sample data.
        static func samplePeaks(seed: String, count: Int = 600) -> [Float] {
            var state = seed.unicodeScalars.reduce(UInt64(1_469_598_103)) {
                ($0 ^ UInt64($1.value)) &* 1_099_511_628_211
            }
            func random() -> Float {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Float(state >> 40) / Float(1 << 24)
            }
            var level: Float = 0.4
            return (0..<count).map { i in
                level = 0.75 * level + 0.25 * (0.25 + 0.55 * random())
                let pause: Float = (i / 37) % 5 == 3 ? 0.35 : 1
                return min(1, max(0.04, (level + 0.3 * (random() - 0.5)) * pause))
            }
        }
    }

    /// Runs a closure from an `NSMenuItem`.
    @MainActor
    private final class MenuAction: NSObject {
        let handler: @MainActor () -> Void

        init(_ handler: @escaping @MainActor () -> Void) {
            self.handler = handler
        }

        @objc func run() { handler() }
    }
#endif
