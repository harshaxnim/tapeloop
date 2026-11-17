#if os(macOS)
    @preconcurrency import AVFoundation
    import Foundation
    import TapeloopCore

    /// Takes PCM from a capture thread, encodes it at once and keeps the encoded chunks in a `ChunkRing`.
    ///
    /// Thread-safe: capture callbacks may arrive on any thread.
    public final class CaptureSink: @unchecked Sendable {
        private let lock = NSLock()
        private let encoder: AACEncoder
        private var ring: ChunkRing
        private var buffersSeen = 0

        /// Creates a sink that keeps up to `maxDuration` seconds.
        public init(encoder: AACEncoder, maxDuration: TimeInterval) {
            self.encoder = encoder
            self.ring = ChunkRing(maxDuration: maxDuration)
        }

        /// Encodes one buffer. Call from the capture callback.
        public func consume(_ buffer: AVAudioPCMBuffer, at time: Date = Date()) {
            lock.lock()
            defer { lock.unlock() }
            buffersSeen += 1
            for chunk in encoder.append(buffer, at: time) { ring.append(chunk) }
        }

        /// Moves the partial chunk into the ring (call when capture stops).
        public func flush() {
            lock.lock()
            defer { lock.unlock() }
            if let chunk = encoder.flush() { ring.append(chunk) }
        }

        /// A consistent copy of the state.
        public func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(
                chunks: ring.chunks, bytes: ring.bytes, buffersSeen: buffersSeen, peak: encoder.peak,
                streamDescription: encoder.streamDescription, magicCookie: encoder.magicCookie)
        }

        /// What the sink holds at one moment.
        public struct Snapshot: @unchecked Sendable {
            /// The encoded chunks, oldest first.
            public var chunks: [EncodedChunk]
            /// Their total byte cost in RAM.
            public var bytes: Int
            /// How many PCM buffers arrived.
            public var buffersSeen: Int
            /// The highest sample level seen (0 to 1).
            public var peak: Float
            /// The AAC stream description, for writing files.
            public var streamDescription: AudioStreamBasicDescription
            /// The AAC magic cookie, for writing files.
            public var magicCookie: Data?

            /// Seconds of audio held.
            public var duration: TimeInterval { chunks.reduce(0) { $0 + $1.duration } }
        }
    }
#endif
