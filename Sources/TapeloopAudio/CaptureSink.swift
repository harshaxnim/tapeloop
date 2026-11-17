#if os(macOS)
    @preconcurrency import AVFoundation
    import Foundation
    import TapeloopCore

    /// Takes PCM from a capture thread, encodes it at once and keeps the encoded chunks in a `SourceBuffer`.
    ///
    /// Thread-safe: capture callbacks may arrive on any thread. The lock is held only for in-memory work, never
    /// for disk reads, so a save can never stall capture.
    public final class CaptureSink: @unchecked Sendable {
        private let lock = NSLock()
        private var encoder: AACEncoder
        private var buffer: SourceBuffer
        private var buffersSeen = 0
        private var lastSoundAt: Date?

        /// The level (0 to 1) above which audio counts as sound rather than silence.
        public static let soundThreshold: Float = 0.001

        /// Creates a sink that keeps up to `maxDuration` seconds in RAM.
        public init(encoder: AACEncoder, maxDuration: TimeInterval) {
            self.encoder = encoder
            self.buffer = SourceBuffer(source: encoder.source, duration: maxDuration)
        }

        /// The source this sink records.
        public var source: SourceKind { encoder.source }

        /// Encodes one buffer heard at `time`. Call from the capture callback.
        public func consume(_ pcm: AVAudioPCMBuffer, at time: Date = Date()) {
            lock.lock()
            defer { lock.unlock() }
            buffersSeen += 1
            for chunk in encoder.append(pcm, at: time) { buffer.append(chunk) }
            if encoder.recentLevel > Self.soundThreshold { lastSoundAt = time }
        }

        /// Moves the partial chunk into the buffer and ends the segment (call when capture stops or pauses).
        public func flush() {
            lock.lock()
            defer { lock.unlock() }
            if let chunk = encoder.flush() { buffer.append(chunk) }
        }

        /// Applies a new RAM/disk plan.
        public func apply(_ plan: MemoryBudget.Plan, spillFolder: URL?) {
            lock.lock()
            defer { lock.unlock() }
            buffer.apply(plan, spillFolder: spillFolder)
        }

        /// Replaces the encoder (for a new bit rate). The partial chunk of the old one is kept.
        public func replaceEncoder(_ newEncoder: AACEncoder) {
            lock.lock()
            defer { lock.unlock() }
            if let chunk = encoder.flush() { buffer.append(chunk) }
            encoder = newEncoder
        }

        /// Frees RAM under memory pressure, keeping `fraction` of it.
        public func relieveMemoryPressure(keepingFraction fraction: Double) {
            lock.lock()
            defer { lock.unlock() }
            buffer.relieveMemoryPressure(keepingFraction: fraction)
        }

        /// Deletes all audio, RAM and disk.
        public func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            _ = encoder.flush()
            buffer.removeAll()
        }

        /// What a save of `range` needs: the in-RAM chunks plus the disk entries to read later, and the format.
        public func exportPieces(overlapping range: TimeRange) -> ExportPieces {
            lock.lock()
            defer { lock.unlock() }
            let pieces = buffer.pieces(overlapping: range)
            return ExportPieces(
                source: encoder.source, disk: pieces.disk, ram: pieces.ram,
                streamDescription: encoder.streamDescription,
                magicCookie: encoder.magicCookie)
        }

        /// A consistent copy of the state, for status and the timeline.
        public func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(
                chunks: buffer.ram.chunks, bytes: buffer.bytesInRAM, bytesOnDisk: buffer.bytesOnDisk,
                range: buffer.range, buffersSeen: buffersSeen, peak: encoder.peak, recentLevel: encoder.recentLevel,
                lastSoundAt: lastSoundAt, diskError: buffer.diskError, streamDescription: encoder.streamDescription,
                magicCookie: encoder.magicCookie)
        }

        /// The level track (span and peaks of every chunk, disk included) for the timeline.
        public func levelTrack() -> [(start: Date, duration: TimeInterval, levels: [Float])] {
            lock.lock()
            defer { lock.unlock() }
            return buffer.levelTrack
        }

        /// What the sink holds at one moment.
        public struct Snapshot: @unchecked Sendable {
            /// The encoded chunks in RAM, oldest first.
            public var chunks: [EncodedChunk]
            /// Their total byte cost in RAM.
            public var bytes: Int
            /// The bytes on disk (opt-in spill).
            public var bytesOnDisk: Int
            /// The span held, disk included.
            public var range: TimeRange?
            /// How many PCM buffers arrived.
            public var buffersSeen: Int
            /// The highest sample level seen (0 to 1).
            public var peak: Float
            /// The most recent half-second's peak (0 to 1).
            public var recentLevel: Float
            /// When audio above the silence threshold was last heard.
            public var lastSoundAt: Date?
            /// A disk problem, if the spill failed.
            public var diskError: String?
            /// The AAC stream description, for writing files.
            public var streamDescription: AudioStreamBasicDescription
            /// The AAC magic cookie, for writing files.
            public var magicCookie: Data?

            /// Seconds of audio held in RAM.
            public var duration: TimeInterval { chunks.reduce(0) { $0 + $1.duration } }
        }
    }

    /// Everything needed to save one source's part of a range, taken under the sink's lock in a moment.
    public struct ExportPieces: @unchecked Sendable {
        /// The source.
        public var source: SourceKind
        /// Spilled chunks still on disk; read them with `DiskSpillStore.load`.
        public var disk: [DiskSpillStore.Entry]
        /// Chunks in RAM.
        public var ram: [EncodedChunk]
        /// The AAC stream description.
        public var streamDescription: AudioStreamBasicDescription
        /// The AAC magic cookie.
        public var magicCookie: Data?

        /// Creates pieces (also used by tests).
        public init(
            source: SourceKind, disk: [DiskSpillStore.Entry] = [], ram: [EncodedChunk],
            streamDescription: AudioStreamBasicDescription, magicCookie: Data?
        ) {
            self.source = source
            self.disk = disk
            self.ram = ram
            self.streamDescription = streamDescription
            self.magicCookie = magicCookie
        }

        /// Reads the disk part back (skipping chunks that aged out meanwhile) and returns all chunks, oldest first.
        public func loadChunks() -> [EncodedChunk] {
            disk.compactMap { try? DiskSpillStore.load($0) } + ram
        }
    }
#endif
