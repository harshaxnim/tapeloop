#if os(macOS)
    @preconcurrency import AVFoundation
    import Foundation
    import TapeloopCore
    import os

    /// Transcribes while recording. Each source's audio is converted to 16 kHz mono and cut into utterances at pauses;
    /// a serial worker runs each utterance through Parakeet's streaming decoder (one model, shared by both sources)
    /// and keeps the lines, with their wall-clock times, in memory beside the audio buffer. A save then takes its
    /// transcript from here at once.
    public final class LiveTranscriber: @unchecked Sendable {
        /// A recognized line with its source and wall-clock times.
        public struct Line: Equatable, Sendable {
            public var source: SourceKind
            public var start: Date
            public var end: Date
            public var text: String
        }

        /// Pieces end at a pause of at least this long, once they hold at least `minimumPiece` seconds…
        static let pause: TimeInterval = 0.6
        static let minimumPiece: TimeInterval = 2
        /// …and never grow beyond this.
        static let maximumPiece: TimeInterval = 25
        /// A 100 ms window quieter than this RMS counts as silence (about -50 dBFS).
        static let silence: Float = 0.003
        /// A time jump larger than this between buffers (sleep, pause) ends the piece.
        static let gap: TimeInterval = 0.5

        private let engine: ParakeetEngine
        private let lock = NSLock()
        private var pending: [SourceKind: Pending] = [:]
        private var lines: [Line] = []
        private var jobs = 0
        private let worker = DispatchQueue(
            label: "io.github.harshaxnim.tapeloop.live-transcription", qos: .utility, autoreleaseFrequency: .workItem)
        private let drained = NSCondition()
        private let log = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "live-transcription")
        /// When live transcription started; earlier audio has no live lines.
        public let startedAt = Date()
        private var stopped = false

        /// Creates the transcriber; feed it with ``consume(_:buffer:at:)``.
        public init(engine: ParakeetEngine) {
            self.engine = engine
        }

        /// The audio of one source not yet sent to the model.
        struct Pending {
            let converter = PCMConverter(to: ParakeetEngine.sampleRate)
            var samples: [Float] = []
            var start: Date?
            var voiced = false
            var trailingSilence: TimeInterval = 0
            var window: [Float] = []

            var duration: TimeInterval { Double(samples.count) / ParakeetEngine.sampleRate }
            var end: Date? { start.map { $0.addingTimeInterval(duration) } }
        }

        // MARK: - Input

        /// Takes a captured buffer (called on a capture thread; converts at once, because the buffer is only valid
        /// during the call).
        public func consume(_ source: SourceKind, buffer: AVAudioPCMBuffer, at time: Date) {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            var state = pending[source] ?? Pending()
            let samples = state.converter.convert(buffer)
            guard !samples.isEmpty else {
                pending[source] = state
                return
            }
            if let end = state.end, abs(time.timeIntervalSince(end)) > Self.gap {
                cut(&state, source: source)
            }
            if state.start == nil { state.start = time }
            state.samples += samples
            Self.measure(samples, into: &state)
            let longEnough = state.duration >= Self.minimumPiece && state.trailingSilence >= Self.pause
            if longEnough || state.duration >= Self.maximumPiece {
                cut(&state, source: source)
            }
            pending[source] = state
        }

        /// Updates the voiced flag and trailing silence in 100 ms windows.
        static func measure(_ samples: [Float], into state: inout Pending) {
            let windowSize = Int(ParakeetEngine.sampleRate / 10)
            state.window += samples
            while state.window.count >= windowSize {
                var sum: Float = 0
                for index in 0..<windowSize { sum += state.window[index] * state.window[index] }
                state.window.removeFirst(windowSize)
                let rms = (sum / Float(windowSize)).squareRoot()
                if rms < silence {
                    state.trailingSilence += 0.1
                } else {
                    state.voiced = true
                    state.trailingSilence = 0
                }
            }
        }

        /// Sends the pending audio to the worker (if it had any voice) and starts a new piece. Call with the lock held.
        private func cut(_ state: inout Pending, source: SourceKind) {
            defer {
                state.samples = []
                state.start = nil
                state.voiced = false
                state.trailingSilence = 0
                state.window = []
            }
            guard state.voiced, let start = state.start, !state.samples.isEmpty else { return }
            let samples = state.samples
            jobs += 1
            worker.async { [weak self] in self?.run(samples, source: source, start: start) }
        }

        private func run(_ samples: [Float], source: SourceKind, start: Date) {
            defer {
                lock.withLock { jobs -= 1 }
                drained.lock()
                drained.broadcast()
                drained.unlock()
            }
            guard !lock.withLock({ stopped }) else { return }
            do {
                let found = try engine.transcribe(samples)
                let new = found.map {
                    Line(
                        source: source, start: start.addingTimeInterval($0.start),
                        end: start.addingTimeInterval($0.end),
                        text: $0.text)
                }
                lock.withLock { lines += new }
            } catch {
                log.error("Live transcription failed: \(String(describing: error), privacy: .public)")
            }
        }

        // MARK: - Output

        /// Sends all pending audio to the model and waits (up to `timeout`) until every piece is transcribed.
        public func flush(timeout: TimeInterval = 120) {
            lock.withLock {
                for source in Array(pending.keys) {
                    guard var state = pending[source] else { continue }
                    cut(&state, source: source)
                    pending[source] = state
                }
            }
            let deadline = Date().addingTimeInterval(timeout)
            drained.lock()
            while lock.withLock({ jobs }) > 0, Date() < deadline {
                _ = drained.wait(until: min(deadline, Date().addingTimeInterval(0.5)))
            }
            drained.unlock()
        }

        /// The lines overlapping `range`, as transcript segments relative to its start (sorted). `speaker` is set
        /// when `labelSpeakers`.
        public func segments(in range: TimeRange, labelSpeakers: Bool) -> [TranscriptSegment] {
            lock.withLock { lines }
                .filter { $0.end > range.start && $0.start < range.end }
                .sorted { $0.start < $1.start }
                .map {
                    TranscriptSegment(
                        start: max(0, $0.start.timeIntervalSince(range.start)),
                        end: max(0, min(range.duration, $0.end.timeIntervalSince(range.start))),
                        speaker: labelSpeakers ? $0.source : nil, text: $0.text)
                }
        }

        /// Whether live lines cover `range` (live transcription was running for all of it).
        public func covers(_ range: TimeRange) -> Bool { range.start >= startedAt.addingTimeInterval(-1) }

        /// Drops lines older than `date` (they left the audio buffer).
        public func trim(before date: Date) {
            lock.withLock { lines.removeAll { $0.end < date } }
        }

        /// The number of lines held (for diagnostics).
        public var lineCount: Int { lock.withLock { lines.count } }

        /// Stops accepting audio and forgets everything.
        public func stop() {
            lock.withLock {
                stopped = true
                pending = [:]
                lines = []
            }
        }
    }
#endif
