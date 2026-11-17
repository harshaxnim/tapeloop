#if os(macOS)
    import Foundation
    import TapeloopCore

    /// Makes a recording's ``Transcript`` from one or more audio files.
    ///
    /// The app passes either one mixed file (`source` `nil`), or one temporary file per source so lines can be
    /// labelled "You" (microphone) and "System". Parts are transcribed one after another.
    public struct TranscriptionService: Sendable {
        /// The engine.
        public let transcriber: any Transcriber

        /// Creates a service. The default engine is on-device Apple speech recognition.
        public init(transcriber: any Transcriber = AppleSpeechTranscriber()) {
            self.transcriber = transcriber
        }

        /// Transcribes every part, shifts each part's lines by its `offset` (seconds from the recording's start),
        /// sets `speaker` to the part's source when `labelSpeakers` is on, and merges the lines in time order.
        public func transcribe(
            parts: [(source: SourceKind?, url: URL, offset: TimeInterval)], locale: Locale, labelSpeakers: Bool
        ) async throws -> Transcript {
            var results: [(source: SourceKind?, segments: [TranscriptSegment], offset: TimeInterval)] = []
            for part in parts {
                try Task.checkCancellation()
                let segments = try await transcriber.transcribe(fileURL: part.url, locale: locale)
                results.append((part.source, segments, part.offset))
            }
            return Transcript(
                locale: locale.identifier, segments: Self.merge(results, labelSpeakers: labelSpeakers))
        }

        /// The pure part of ``transcribe(parts:locale:labelSpeakers:)``: shifts, labels and merges. Lines are sorted
        /// by start; lines that start together keep the order of the parts (then their own order).
        public static func merge(
            _ results: [(source: SourceKind?, segments: [TranscriptSegment], offset: TimeInterval)],
            labelSpeakers: Bool
        ) -> [TranscriptSegment] {
            var lines: [(segment: TranscriptSegment, order: Int)] = []
            for result in results {
                for segment in result.segments {
                    var shifted = segment
                    shifted.start += result.offset
                    shifted.end += result.offset
                    shifted.speaker = labelSpeakers ? result.source : nil
                    lines.append((shifted, lines.count))
                }
            }
            return lines.sorted {
                ($0.segment.start, $0.order) < ($1.segment.start, $1.order)
            }
            .map(\.segment)
        }
    }
#endif
