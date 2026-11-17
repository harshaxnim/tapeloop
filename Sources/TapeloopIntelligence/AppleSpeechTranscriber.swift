#if os(macOS)
    @preconcurrency import AVFoundation
    import Foundation
    @preconcurrency import Speech
    import TapeloopCore

    /// The Speech Recognition permission.
    public enum SpeechPermission {
        /// The permission's state.
        public enum Status: Sendable {
            /// Not asked yet.
            case notDetermined
            /// The user said no.
            case denied
            /// A profile or parental controls forbid it.
            case restricted
            /// Allowed.
            case authorized
        }

        /// The current state. Never shows a prompt.
        public static var status: Status {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: .authorized
            case .denied: .denied
            case .restricted: .restricted
            case .notDetermined: .notDetermined
            @unknown default: .denied
            }
        }

        /// Asks for the permission (shows the system prompt the first time; needs
        /// `NSSpeechRecognitionUsageDescription`). Returns whether it is allowed.
        public static func request() async -> Bool {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    /// Transcribes with Apple's `SFSpeechRecognizer`, strictly on device: if the language has no on-device model it
    /// throws ``IntelligenceError/onDeviceUnavailable(language:)``; it never falls back to Apple's servers.
    ///
    /// Long files are read with `AVAudioFile`, mixed down to mono, and recognized in pieces of at most
    /// ``pieceLength`` seconds, one request after another; the words' times are shifted by each piece's offset and
    /// the words are grouped into lines (a new line after a 0.8 s pause, after a sentence, or past about 12 s).
    /// Silent pieces are skipped. A word cut by a piece boundary may be misheard.
    public struct AppleSpeechTranscriber: Transcriber {
        /// The longest audio sent in one recognition request, in seconds.
        public static let pieceLength: TimeInterval = 55

        /// Creates a transcriber.
        public init() {}

        /// Whether `locale` can be transcribed on this Mac without a network.
        public static func supportsOnDevice(_ locale: Locale) -> Bool {
            SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
        }

        /// The languages that can be transcribed on this Mac, sorted by their name in the user's language. For the
        /// language picker in Settings. Creates a recognizer per supported language, so call it off the main thread.
        public static func onDeviceLocales() -> [Locale] {
            SFSpeechRecognizer.supportedLocales()
                .filter(supportsOnDevice)
                .map { (locale: $0, name: IntelligenceError.languageName($0)) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map(\.locale)
        }

        /// The locale for `TranscriptionSettings.localeID`: that identifier, or the system's speech language when it
        /// is `nil`.
        public static func locale(forIdentifier identifier: String?) -> Locale {
            if let identifier { return Locale(identifier: identifier) }
            return SFSpeechRecognizer()?.locale ?? Locale.current
        }

        /// Throws unless the Speech Recognition permission is given. Never shows a prompt.
        public static func checkPermission() throws {
            switch SpeechPermission.status {
            case .authorized: return
            case .notDetermined: throw IntelligenceError.speechNotRequested
            case .denied, .restricted: throw IntelligenceError.speechNotAllowed
            }
        }

        /// Throws unless `locale` can be transcribed on this Mac. Needs no permission.
        public static func checkLocale(_ locale: Locale) throws {
            guard supportsOnDevice(locale) else {
                throw IntelligenceError.onDeviceUnavailable(language: IntelligenceError.languageName(locale))
            }
        }

        /// Transcribes the file on device. See ``Transcriber/transcribe(fileURL:locale:)``.
        public func transcribe(fileURL: URL, locale: Locale) async throws -> [TranscriptSegment] {
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: fileURL)
            } catch {
                throw IntelligenceError.unreadableAudio(fileName: fileURL.lastPathComponent)
            }
            try Self.checkPermission()
            let language = IntelligenceError.languageName(locale)
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
                throw IntelligenceError.onDeviceUnavailable(language: language)
            }
            guard recognizer.isAvailable else { throw IntelligenceError.recognizerUnavailable(language: language) }
            recognizer.queue = OperationQueue()

            let format = file.processingFormat
            let rate = format.sampleRate
            guard rate > 0,
                let mono = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            else { throw IntelligenceError.unreadableAudio(fileName: fileURL.lastPathComponent) }
            let converter = AVAudioConverter(from: format, to: mono)
            converter?.downmix = true
            let pieceFrames = AVAudioFrameCount(Self.pieceLength * rate)

            Log.transcription.info(
                "Transcribing \(fileURL.lastPathComponent, privacy: .public) (\(Double(file.length) / rate, format: .fixed(precision: 1)) s, \(locale.identifier, privacy: .public))"
            )
            var words: [TimedWord] = []
            var position: AVAudioFramePosition = 0
            while position < file.length {
                try Task.checkCancellation()
                let count = min(pieceFrames, AVAudioFrameCount(file.length - position))
                guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
                    let piece = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: count),
                    let converter
                else { throw IntelligenceError.unreadableAudio(fileName: fileURL.lastPathComponent) }
                do {
                    try file.read(into: input, frameCount: count)
                } catch {
                    // A compressed file's length is an estimate: a failed read after some audio is its end.
                    if position > 0 { break }
                    throw IntelligenceError.unreadableAudio(fileName: fileURL.lastPathComponent)
                }
                guard input.frameLength > 0 else { break }
                do {
                    try converter.convert(to: piece, from: input)
                } catch {
                    throw IntelligenceError.unreadableAudio(fileName: fileURL.lastPathComponent)
                }
                let offset = Double(position) / rate
                position += AVAudioFramePosition(input.frameLength)
                guard !Self.isSilent(piece) else { continue }
                let found = try await Self.recognize(piece, with: recognizer)
                words += found.map { TimedWord(text: $0.text, start: $0.start + offset, duration: $0.duration) }
            }
            let segments = SegmentBuilder.segments(from: words)
            Log.transcription.info("Transcribed \(segments.count) lines")
            return segments
        }

        /// Whether the buffer is digital silence (or close to it), which needs no recognition.
        private static func isSilent(_ buffer: AVAudioPCMBuffer) -> Bool {
            guard let samples = buffer.floatChannelData?[0] else { return true }
            for index in 0..<Int(buffer.frameLength) where abs(samples[index]) > 0.0005 { return false }
            return true
        }

        /// Recognizes one piece. Words' times are relative to the piece.
        private static func recognize(_ buffer: AVAudioPCMBuffer, with recognizer: SFSpeechRecognizer) async throws
            -> [TimedWord]
        {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            request.addsPunctuation = true
            request.append(buffer)
            request.endAudio()

            let state = RecognitionState()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    state.set(continuation)
                    let task = recognizer.recognitionTask(with: request) { result, error in
                        if let result, result.isFinal {
                            state.finish(
                                .success(
                                    result.bestTranscription.segments.map {
                                        TimedWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                                    }))
                        } else if let error {
                            state.finish(Self.outcome(of: error))
                        }
                    }
                    state.set(task)
                }
            } onCancel: {
                state.cancel()
            }
        }

        /// What a recognition error means: "no speech" is an empty piece, not a failure.
        private static func outcome(of error: Error) -> Result<[TimedWord], Error> {
            let error = error as NSError
            // kAFAssistantErrorDomain 1110: no speech detected; 203: nothing recognized.
            if error.domain == "kAFAssistantErrorDomain", [203, 1110].contains(error.code) { return .success([]) }
            if error.domain == "kAFAssistantErrorDomain", [216, 301].contains(error.code) {
                return .failure(CancellationError())
            }
            Log.transcription.error(
                "Recognition failed: \(error.domain, privacy: .public) \(error.code) \(error.localizedDescription, privacy: .public)"
            )
            return .failure(IntelligenceError.recognitionFailed(reason: error.localizedDescription))
        }
    }

    /// Bridges one recognition task to a continuation: resumes it exactly once (even when the task finishes or is
    /// cancelled before the continuation is set) and cancels the task on demand.
    private final class RecognitionState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[TimedWord], Error>?
        private var task: SFSpeechRecognitionTask?
        private var outcome: Result<[TimedWord], Error>?
        private var cancelled = false

        func set(_ continuation: CheckedContinuation<[TimedWord], Error>) {
            let early = lock.withLock {
                if outcome == nil { self.continuation = continuation }
                return outcome
            }
            if let early { continuation.resume(with: early) }
        }

        func set(_ task: SFSpeechRecognitionTask) {
            let cancelNow = lock.withLock {
                self.task = task
                return cancelled
            }
            if cancelNow { task.cancel() }
        }

        func finish(_ result: Result<[TimedWord], Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<[TimedWord], Error>? in
                guard outcome == nil else { return nil }
                outcome = result
                task = nil
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
        }

        func cancel() {
            let task = lock.withLock {
                cancelled = true
                return self.task
            }
            task?.cancel()
            finish(.failure(CancellationError()))
        }
    }
#endif
