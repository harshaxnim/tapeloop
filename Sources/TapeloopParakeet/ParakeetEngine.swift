#if os(macOS)
    @preconcurrency import AVFoundation
    import Foundation
    import TapeloopCore
    import TapeloopIntelligence
    import TranscribeCpp
    import os

    /// Errors from Parakeet transcription, with messages for the user.
    public enum ParakeetError: Error, CustomStringConvertible, LocalizedError, Equatable {
        /// The model file is not installed.
        case modelMissing
        /// The model file could not be loaded.
        case loadFailed(String)
        /// Recognition failed.
        case failed(String)
        /// The audio file could not be read.
        case unreadableAudio(String)

        public var description: String {
            switch self {
            case .modelMissing:
                "The Parakeet speech model is not downloaded. Download it in Settings › Transcripts."
            case .loadFailed(let reason): "The Parakeet speech model could not be loaded: \(reason)"
            case .failed(let reason): "Transcription failed: \(reason)"
            case .unreadableAudio(let name): "The audio of \(name) could not be read."
            }
        }

        public var errorDescription: String? { description }
    }

    /// Runs the Parakeet model: loads it on first use, transcribes 16 kHz mono audio with its streaming decoder, and
    /// can be unloaded to give the memory back. All work is serialized; call it off the main thread.
    public final class ParakeetEngine: @unchecked Sendable {
        /// The sample rate the model expects.
        public static let sampleRate: Double = 16_000
        private let path: URL
        private let lock = NSLock()
        private var model: Model?
        private var session: Session?
        private let log = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "parakeet")

        /// Creates an engine for the model file at `path` (nothing is loaded yet).
        public init(modelPath: URL) {
            path = modelPath
        }

        /// Whether the model is loaded (and holding memory).
        public var isLoaded: Bool { lock.withLock { model != nil } }

        /// Loads the model now (it is otherwise loaded by the first transcription).
        public func load() throws {
            try lock.withLock { _ = try loadedSession() }
        }

        /// Releases the model and its memory.
        public func unload() {
            lock.withLock {
                session = nil
                model = nil
            }
            log.info("Parakeet model unloaded")
        }

        /// Call with the lock held.
        private func loadedSession() throws -> Session {
            if let session { return session }
            guard FileManager.default.fileExists(atPath: path.path) else { throw ParakeetError.modelMissing }
            let started = Date()
            do {
                let model = try Model(path: path.path)
                let session = try model.session()
                self.model = model
                self.session = session
                log.info(
                    "Parakeet model loaded in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s (\(model.backend, privacy: .public))"
                )
                return session
            } catch {
                throw ParakeetError.loadFailed("\(error)")
            }
        }

        /// Transcribes `pcm` (16 kHz mono, -1 to 1). Line times are seconds from the start of `pcm`. `isCancelled`
        /// is checked between pieces; when it returns true, `CancellationError` is thrown.
        public func transcribe(_ pcm: [Float], isCancelled: () -> Bool = { false }) throws -> [TranscriptSegment] {
            guard !pcm.isEmpty else { return [] }
            return try lock.withLock {
                let session = try loadedSession()
                let options = RunOptions(timestamps: .word)
                let transcript: TranscribeCpp.Transcript
                do {
                    // The streaming decoder handles audio of any length; feed it one second at a time.
                    let stream = try session.stream(options)
                    let step = Int(Self.sampleRate)
                    var index = 0
                    while index < pcm.count {
                        if isCancelled() {
                            stream.reset()
                            throw CancellationError()
                        }
                        let end = min(pcm.count, index + step)
                        _ = try stream.feed(Array(pcm[index..<end]))
                        index = end
                    }
                    try stream.finalize()
                    transcript = stream.snapshot
                } catch let error as CancellationError {
                    throw error
                } catch {
                    throw ParakeetError.failed("\(error)")
                }
                return Self.lines(from: transcript, duration: Double(pcm.count) / Self.sampleRate)
            }
        }

        /// Turns the model's output into transcript lines. The streaming decoder reports timed tokens (word pieces;
        /// a leading space starts a word) rather than words, so words are rebuilt from them; lines are then split at
        /// pauses and sentence ends, like the other engine. Falls back to segments, then to the plain text.
        static func lines(from transcript: TranscribeCpp.Transcript, duration: TimeInterval) -> [TranscriptSegment] {
            var words = transcript.words.map {
                TimedWord(
                    text: $0.text, start: Double($0.t0Ms) / 1000, duration: Double(max(0, $0.t1Ms - $0.t0Ms)) / 1000)
            }
            if words.isEmpty {
                words = Self.words(fromTokens: transcript.tokens.map { ($0.text, $0.t0Ms, $0.t1Ms) })
            }
            if !words.isEmpty { return SegmentBuilder.segments(from: words) }
            let segments = transcript.segments.compactMap { segment -> TranscriptSegment? in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(
                    start: Double(segment.t0Ms) / 1000, end: Double(segment.t1Ms) / 1000, text: text)
            }
            if !segments.isEmpty { return segments }
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TranscriptSegment(start: 0, end: duration, text: text)]
        }

        /// Joins word pieces into words: a piece starting with a space (or the first piece) starts a new word.
        static func words(fromTokens tokens: [(text: String, t0Ms: Int64, t1Ms: Int64)]) -> [TimedWord] {
            var words: [TimedWord] = []
            for token in tokens where !token.text.isEmpty {
                let start = Double(token.t0Ms) / 1000
                let end = Double(max(token.t0Ms, token.t1Ms)) / 1000
                if token.text.first?.isWhitespace == true || words.isEmpty {
                    words.append(
                        TimedWord(
                            text: token.text.trimmingCharacters(in: .whitespaces), start: start, duration: end - start))
                } else {
                    words[words.count - 1].text += token.text
                    words[words.count - 1].duration = max(
                        words[words.count - 1].duration, end - words[words.count - 1].start)
                }
            }
            return words.filter { !$0.text.isEmpty }
        }

        // MARK: - Audio

        /// Reads an audio file as 16 kHz mono float samples.
        public static func readPCM(_ url: URL) throws -> [Float] {
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: url)
            } catch {
                throw ParakeetError.unreadableAudio(url.lastPathComponent)
            }
            let converter = PCMConverter(to: sampleRate)
            var samples: [Float] = []
            samples.reserveCapacity(Int(Double(file.length) / file.processingFormat.sampleRate * sampleRate) + 1024)
            let chunk: AVAudioFrameCount = 1 << 16
            while true {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
                    break
                }
                do {
                    try file.read(into: buffer, frameCount: chunk)
                } catch {
                    if samples.isEmpty { throw ParakeetError.unreadableAudio(url.lastPathComponent) }
                    break
                }
                if buffer.frameLength == 0 { break }
                samples += converter.convert(buffer)
            }
            return samples
        }
    }

    /// Converts PCM buffers of any format to mono float samples at one rate, keeping its state across buffers so a
    /// stream converts without clicks. Not thread-safe; use one per stream.
    public final class PCMConverter {
        private let rate: Double
        private var converter: AVAudioConverter?
        private var inputFormat: AVAudioFormat?
        private let output: AVAudioFormat

        /// Creates a converter to mono float at `rate` Hz.
        public init(to rate: Double) {
            self.rate = rate
            output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        }

        /// Converts one buffer; returns the samples it produced.
        public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
            if inputFormat != buffer.format {
                inputFormat = buffer.format
                converter = AVAudioConverter(from: buffer.format, to: output)
                converter?.downmix = true
            }
            guard let converter, buffer.frameLength > 0 else { return [] }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * rate / buffer.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = out.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        }
    }

    /// The after-save ``Transcriber`` for Parakeet: reads the file, transcribes it, and releases the model afterwards
    /// unless `keepLoaded` is set (live mode keeps it).
    public struct ParakeetTranscriber: Transcriber {
        private let engine: ParakeetEngine
        private let keepLoaded: Bool

        /// Creates the transcriber.
        public init(engine: ParakeetEngine, keepLoaded: Bool = false) {
            self.engine = engine
            self.keepLoaded = keepLoaded
        }

        /// `locale` is ignored: the model is English.
        public func transcribe(fileURL: URL, locale: Locale) async throws -> [TranscriptSegment] {
            let pcm = try ParakeetEngine.readPCM(fileURL)
            defer { if !keepLoaded { engine.unload() } }
            return try engine.transcribe(pcm, isCancelled: { Task.isCancelled })
        }
    }
#endif
