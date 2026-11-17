#if os(macOS)
    import Foundation
    import TapeloopCore

    /// Turns an audio file into timed lines of text.
    ///
    /// This is the seam for transcription engines: ``AppleSpeechTranscriber`` (on-device `SFSpeechRecognizer`) is
    /// one engine; Parakeet (in the TapeloopParakeet module) is the other, and another engine, such as a local Whisper model, can be added later by conforming
    /// to this protocol and passing it to ``TranscriptionService/init(transcriber:)``. Nothing else needs to change.
    /// Implementations must work on the Mac only; nothing may leave it.
    public protocol Transcriber: Sendable {
        /// Transcribes the file. Segment times are seconds from the file's start, in time order; `speaker` is `nil`
        /// (``TranscriptionService`` labels speakers). Throws ``IntelligenceError`` for expected failures and
        /// `CancellationError` when the task is cancelled.
        func transcribe(fileURL: URL, locale: Locale) async throws -> [TranscriptSegment]
    }

    /// A word (or a few words) with its time, as recognizers report them.
    public struct TimedWord: Equatable, Sendable {
        /// The text, possibly with punctuation attached ("Hello,").
        public var text: String
        /// Seconds from the file's start.
        public var start: TimeInterval
        /// Seconds.
        public var duration: TimeInterval

        /// Creates a word.
        public init(text: String, start: TimeInterval, duration: TimeInterval) {
            self.text = text
            self.start = start
            self.duration = duration
        }

        /// When the word ends.
        public var end: TimeInterval { start + duration }
    }

    /// Groups recognized words into transcript lines.
    public enum SegmentBuilder {
        /// A pause at least this long starts a new line.
        static let pause: TimeInterval = 0.8
        /// A line is not allowed to grow beyond about this many seconds.
        static let maxLength: TimeInterval = 12

        /// Groups `words` (in time order) into lines: a new line starts after a pause of ``pause`` seconds, after
        /// a word ending a sentence (`.`, `?`, `!`, `…`), or when the line would grow beyond ``maxLength`` seconds.
        /// Text is trimmed and empty lines are dropped.
        public static func segments(from words: [TimedWord]) -> [TranscriptSegment] {
            var result: [TranscriptSegment] = []
            var current: [TimedWord] = []

            func flush() {
                defer { current = [] }
                guard let first = current.first, let last = current.last else { return }
                let text = current.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                guard !text.isEmpty else { return }
                result.append(TranscriptSegment(start: first.start, end: max(first.start, last.end), text: text))
            }

            for word in words {
                if let first = current.first, let last = current.last {
                    let paused = word.start - last.end >= pause
                    let sentenceEnded = endsSentence(last.text)
                    let tooLong = word.end - first.start > maxLength
                    if paused || sentenceEnded || tooLong { flush() }
                }
                current.append(word)
            }
            flush()
            return result
        }

        private static func endsSentence(_ text: String) -> Bool {
            var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = trimmed.last, "\"'”’)]".contains(last) { trimmed.removeLast() }
            guard let last = trimmed.last else { return false }
            return ".?!…。？！".contains(last)
        }
    }
#endif
