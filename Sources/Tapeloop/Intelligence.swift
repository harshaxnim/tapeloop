#if os(macOS)
    import Foundation
    import TapeloopCore
    import TapeloopExport
    import TapeloopIntelligence
    import TapeloopParakeet
    import TapeloopUI
    import os

    /// Meeting detection, calendar titles and on-device transcription, wired to the controller.
    @MainActor
    final class Intelligence {
        private let log = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "intelligence")
        private weak var controller: AppController?
        private var detector: MeetingDetector?
        private let calendar = CalendarProvider()
        /// Recordings being transcribed (the Library shows a spinner for them).
        private(set) var transcribing: Set<URL> = []
        /// Called when `transcribing` changes or a transcript is written.
        var onTranscriptsChanged: () -> Void = {}

        init(controller: AppController) {
            self.controller = controller
        }

        // MARK: - Meetings

        /// Starts or stops detection to match the settings.
        func apply(_ settings: MeetingSettings) {
            if settings.detect, MeetingDetector.isSupported {
                guard detector == nil else { return }
                let detector = MeetingDetector()
                detector.start { [weak self] event in
                    Task { @MainActor in self?.handle(event) }
                }
                self.detector = detector
                log.info("Meeting detection on")
            } else if let detector {
                detector.stop()
                self.detector = nil
                log.info("Meeting detection off")
            }
        }

        func stop() {
            detector?.stop()
            detector = nil
        }

        private func handle(_ event: MeetingEvent) {
            guard let controller else { return }
            var span = event.span
            span.info.calendarTitle = calendarTitle(for: span.range())
            switch event {
            case .started:
                log.info("Meeting started: \(span.info.appName, privacy: .public)")
                controller.meetings.removeAll { $0.id == span.id }
                controller.meetings.append(span)
            case .ended:
                log.info("Meeting ended: \(span.info.appName, privacy: .public)")
                if let index = controller.meetings.firstIndex(where: { $0.id == span.id }) {
                    controller.meetings[index] = span
                } else {
                    controller.meetings.append(span)
                }
                meetingEnded(span)
            }
            // Keep only meetings that still overlap the buffer.
            if let start = controller.status.range?.start {
                controller.meetings.removeAll { ($0.end ?? .distantFuture) < start }
            }
        }

        private func calendarTitle(for range: TimeRange) -> String? {
            guard let settings = controller?.settings.meetings, settings.useCalendar, CalendarProvider.isAuthorized
            else {
                return nil
            }
            return calendar.eventTitle(overlapping: range, calendarIDs: settings.calendarIDs)
        }

        private func meetingEnded(_ span: MeetingSpan) {
            guard let controller, controller.status.range != nil else { return }
            let range = span.range()
            // Very short calls (under a minute) are not worth a prompt.
            guard range.duration >= 60 else { return }
            let settings = controller.settings.meetings
            if settings.autoSave {
                controller.save(range: range, meeting: span.info)
            } else if settings.offerToSave {
                let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
                Notifier.shared.post(
                    .meetingEnded(
                        id: span.id, app: span.info.appName, title: span.info.calendarTitle,
                        span: "\(time(range.start)) to \(time(range.end))", length: DurationText.long(range.duration)))
            }
        }

        // MARK: - Transcription

        /// The downloadable Parakeet model.
        let models = ModelStore()
        /// The Parakeet engine (loads the model on first use).
        private(set) lazy var parakeet = ParakeetEngine(modelPath: models.fileURL)
        /// Live transcription, while it runs.
        private(set) var live: LiveTranscriber?
        /// Whether the user started a model download (installing it then turns Parakeet transcription on).
        private var downloadRequested = false

        /// Starts or stops live transcription to match the settings and the model. Call after either changes.
        func applyTranscription() {
            guard let controller else { return }
            let settings = controller.settings.transcription
            let wanted =
                settings.enabled && settings.engine == .parakeet && settings.mode == .live && models.isInstalled
            if wanted, live == nil {
                let live = LiveTranscriber(engine: parakeet)
                self.live = live
                let engine = parakeet
                let log = self.log
                Task.detached(priority: .utility) {
                    do { try engine.load() } catch {
                        log.error("Parakeet load failed: \(String(describing: error), privacy: .public)")
                    }
                }
                controller.engine.setPCMObserver { source, buffer, time in
                    live.consume(source, buffer: buffer, at: time)
                }
                log.info("Live transcription on")
            } else if !wanted, let live {
                controller.engine.setPCMObserver(nil)
                live.stop()
                self.live = nil
                parakeet.unload()
                log.info("Live transcription off")
            }
        }

        /// Drops live lines that left the audio buffer.
        func trimLive(before date: Date) {
            live?.trim(before: date)
        }

        /// Starts the model download the user asked for.
        func downloadModel() {
            downloadRequested = true
            models.download()
        }

        /// Installs a model file the user picked.
        func importModel(at url: URL) {
            downloadRequested = true
            models.importFile(at: url)
        }

        /// Called when the model store's state changes.
        func modelStateChanged(_ state: ModelStore.State) {
            if state == .installed, downloadRequested {
                downloadRequested = false
                controller?.update {
                    $0.transcription.enabled = true
                    $0.transcription.engine = .parakeet
                }
            }
            if state == .notInstalled { parakeet.unload() }
            applyTranscription()
        }

        /// Why transcription cannot run now, if it cannot (for the user).
        func transcriptionBlocker() -> String? {
            guard let settings = controller?.settings.transcription else { return nil }
            switch settings.engine {
            case .parakeet:
                return models.isInstalled ? nil : ParakeetError.modelMissing.description
            case .apple:
                return SpeechPermission.status == .authorized ? nil : IntelligenceError.speechNotAllowed.description
            }
        }

        /// Transcribes a saved recording and writes the transcript into its sidecar. `separate` gives one file per
        /// source (for You/System labels) when the saved file is a mix; it is deleted afterwards.
        func transcribe(_ url: URL, separate: [(SourceKind, URL)] = [], cleanup: URL? = nil) {
            guard let controller, !transcribing.contains(url) else { return }
            let settings = controller.settings.transcription
            let parts: [(source: SourceKind?, url: URL, offset: TimeInterval)] =
                settings.labelSpeakers && !separate.isEmpty
                ? separate.map { (Optional($0.0), $0.1, 0) } : [(nil, url, 0)]
            let parakeet = settings.engine == .parakeet
            let transcriber: any Transcriber =
                parakeet
                ? ParakeetTranscriber(engine: self.parakeet, keepLoaded: live != nil) : AppleSpeechTranscriber()
            let locale =
                parakeet ? Locale(identifier: "en") : AppleSpeechTranscriber.locale(forIdentifier: settings.localeID)
            transcribing.insert(url)
            onTranscriptsChanged()
            let labelSpeakers = settings.labelSpeakers
            let log = self.log
            log.info(
                "Transcribing \(url.lastPathComponent, privacy: .public) with \(settings.engine.rawValue, privacy: .public)"
            )
            Task {
                let result: Result<Transcript, Error> = await Task.detached(priority: .utility) {
                    do {
                        return .success(
                            try await TranscriptionService(transcriber: transcriber).transcribe(
                                parts: parts, locale: locale, labelSpeakers: labelSpeakers))
                    } catch {
                        return .failure(error)
                    }
                }.value
                if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
                self.transcribing.remove(url)
                switch result {
                case .success(let transcript): self.write(transcript, to: url)
                case .failure(let error):
                    log.error("Transcription failed: \(String(describing: error), privacy: .public)")
                    Notifier.shared.post(.transcriptFailed(reason: "\(error)"))
                }
                self.onTranscriptsChanged()
            }
        }

        /// Stores a transcript in a recording's sidecar and says so.
        private func write(_ transcript: Transcript, to url: URL) {
            let store = LibraryStore(folder: url.deletingLastPathComponent())
            var metadata =
                store.metadata(for: url) ?? RecordingMetadata(start: Date(), duration: 0, sources: [], mixed: false)
            metadata.transcript = transcript
            do {
                try store.save(metadata, for: url)
                let words = transcript.text.split(whereSeparator: \.isWhitespace).count
                let title =
                    metadata.title ?? metadata.meeting?.calendarTitle ?? url.deletingPathExtension().lastPathComponent
                Notifier.shared.post(
                    .transcriptReady(title: title, detail: "\(words.formatted()) words, on this Mac only", file: url))
            } catch {
                log.error("Transcript not written: \(String(describing: error), privacy: .public)")
            }
        }

        /// After a save: take the transcript from live lines when they cover the span; otherwise transcribe after the
        /// save when the user chose that. For a mixed save with two sources and speaker labels on, temporary
        /// per-source files are written first (passthrough, fast) so lines can be labelled.
        func recordingSaved(_ result: ExportResult, pieces: [ExportSource]) {
            guard let controller else { return }
            let settings = controller.settings.transcription
            guard settings.enabled, settings.automatic else { return }
            if let blocker = transcriptionBlocker() {
                log.info("Not transcribing: \(blocker, privacy: .public)")
                Notifier.shared.post(.transcriptFailed(reason: blocker))
                return
            }
            if settings.mode == .live, let live, live.covers(result.range) {
                fromLive(live, result: result, labelSpeakers: settings.labelSpeakers)
                return
            }
            if result.files.count == 1, result.sources.count > 1, settings.labelSpeakers {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "tapeloop-transcribe-\(UUID().uuidString)")
                let url = result.files[0]
                Task {
                    let separate: [(SourceKind, URL)]? = await Task.detached(priority: .utility) {
                        let request = ExportRequest(
                            range: result.range, sources: pieces, folder: temp, title: nil, mix: false)
                        guard let written = try? Exporter.save(request, progress: { _ in }) else { return nil }
                        return zip(result.sources, written.files).map { ($0, $1) }
                    }.value
                    self.transcribe(url, separate: separate ?? [], cleanup: temp)
                }
            } else if result.files.count > 1 {
                // One file per source: each file is transcribed on its own, labelled with its source.
                for (index, url) in result.files.enumerated() {
                    let source = index < result.sources.count ? result.sources[index] : nil
                    transcribe(url, separate: source.map { [($0, url)] } ?? [])
                }
            } else {
                transcribe(result.files[0])
            }
        }

        /// Writes the live lines of a saved span (after transcribing the audio still pending) to its file(s).
        private func fromLive(_ live: LiveTranscriber, result: ExportResult, labelSpeakers: Bool) {
            let files = result.files
            for url in files { transcribing.insert(url) }
            onTranscriptsChanged()
            Task {
                let segments = await Task.detached(priority: .userInitiated) { () -> [TranscriptSegment] in
                    live.flush()
                    return live.segments(in: result.range, labelSpeakers: labelSpeakers)
                }.value
                for (index, url) in files.enumerated() {
                    // With one file per source, each file keeps only its own source's lines.
                    let own =
                        files.count > 1 && index < result.sources.count
                        ? segments.filter { $0.speaker == nil || $0.speaker == result.sources[index] } : segments
                    self.transcribing.remove(url)
                    self.write(Transcript(locale: "en", segments: own), to: url)
                }
                self.log.info("Live transcript written: \(segments.count) lines")
                self.onTranscriptsChanged()
            }
        }
    }
#endif
