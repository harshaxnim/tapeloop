#if os(macOS)
    import Accelerate
    @preconcurrency import AVFoundation
    import Foundation
    import TapeloopCore

    /// A one-shot flag for converter input blocks.
    final class OnceFlag: @unchecked Sendable {
        var used = false
    }

    /// Encodes live PCM into AAC-LC packets and groups them into `EncodedChunk`s of about `chunkSeconds`.
    ///
    /// Raw PCM never stays here longer than one call. Chunk times come from the capture timestamps: the encoder
    /// counts samples from an anchor and re-anchors (closing the current chunk) when a buffer arrives more than
    /// `gapTolerance` seconds away from where the count expects it, which is how sleep, pauses and device
    /// restarts become exact gaps on the timeline. Not thread-safe: call it from one thread or under a lock
    /// (`CaptureSink` does this).
    public final class AACEncoder {
        /// The PCM format the encoder takes in (other formats are converted first).
        public let pcmFormat: AVAudioFormat
        /// The compressed format it produces.
        public let aacFormat: AVAudioFormat
        /// The source label put on every chunk.
        public let source: SourceKind
        /// The target chunk length in seconds.
        public let chunkSeconds: Double
        /// The encoded bit rate in bits per second.
        public let bitRate: Int
        /// The highest absolute sample value seen so far (0 to 1).
        public private(set) var peak: Float = 0
        /// The peak of the most recent level interval (0 to 1), for a live meter.
        public private(set) var recentLevel: Float = 0

        /// How far (seconds) a buffer may arrive from its expected time before it starts a new segment.
        public static let gapTolerance: TimeInterval = 0.25

        private let converter: AVAudioConverter
        private var compressed: AVAudioCompressedBuffer?
        private var conformed: AVAudioPCMBuffer?
        private var resampler: AVAudioConverter?
        private var pendingData = Data()
        private var pendingSizes: [Int] = []
        private var pendingLevels: [Float] = []
        private var levelPeak: Float = 0
        private var levelFrames = 0
        /// The wall-clock time of the first sample after the last (re)anchor.
        private var anchor: Date?
        /// Input frames (at `pcmFormat`'s rate) received since the anchor.
        private var framesSinceAnchor = 0
        /// Packets already placed in chunks since the anchor.
        private var packetsSinceAnchor = 0

        /// Creates an encoder for one source.
        public init(
            source: SourceKind, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1, bitRate: Int = 48_000,
            chunkSeconds: Double = 5
        ) throws {
            guard
                let pcm = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
            else { throw AudioError.encoderUnavailable("PCM format") }
            var description = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0,
                mReserved: 0)
            guard let aac = AVAudioFormat(streamDescription: &description) else {
                throw AudioError.encoderUnavailable("AAC format")
            }
            guard let converter = AVAudioConverter(from: pcm, to: aac) else {
                throw AudioError.encoderUnavailable("converter")
            }
            converter.bitRate = bitRate
            self.pcmFormat = pcm
            self.aacFormat = aac
            self.converter = converter
            self.source = source
            self.chunkSeconds = chunkSeconds
            self.bitRate = bitRate
        }

        /// The AAC magic cookie a file writer needs.
        public var magicCookie: Data? { converter.magicCookie }

        /// The stream description of the compressed format.
        public var streamDescription: AudioStreamBasicDescription { aacFormat.streamDescription.pointee }

        /// Encodes one PCM buffer whose first sample was heard at `time`. Returns the chunks it completed.
        public func append(_ input: AVAudioPCMBuffer, at time: Date) -> [EncodedChunk] {
            guard let pcm = conform(input), pcm.frameLength > 0 else { return [] }
            var completed: [EncodedChunk] = []
            if let anchor {
                let expected = anchor.addingTimeInterval(Double(framesSinceAnchor) / pcmFormat.sampleRate)
                if abs(time.timeIntervalSince(expected)) > Self.gapTolerance {
                    if let chunk = makeChunk() { completed.append(chunk) }
                    reanchor(at: time)
                }
            } else {
                reanchor(at: time)
            }
            framesSinceAnchor += Int(pcm.frameLength)
            trackLevels(pcm)

            let once = OnceFlag()
            // One output buffer, reused for every call (allocating one per callback churns memory).
            if compressed == nil {
                compressed = AVAudioCompressedBuffer(
                    format: aacFormat, packetCapacity: 16,
                    maximumPacketSize: max(converter.maximumOutputPacketSize, 2048))
            }
            guard let output = compressed else { return completed }
            while true {
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, inputStatus in
                    if once.used {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    once.used = true
                    inputStatus.pointee = .haveData
                    return pcm
                }
                if status == .error {
                    Log.encoder.error(
                        "AAC encode failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                    break
                }
                collect(output)
                if pendingDuration >= chunkSeconds, let chunk = makeChunk() { completed.append(chunk) }
                if status != .haveData { break }
            }
            return completed
        }

        /// Returns the partial chunk held so far, if any, and forgets the anchor (the next buffer starts a new
        /// segment). Call it when capture stops or pauses.
        public func flush() -> EncodedChunk? {
            let chunk = makeChunk()
            anchor = nil
            return chunk
        }

        private func reanchor(at time: Date) {
            anchor = time
            framesSinceAnchor = 0
            packetsSinceAnchor = 0
        }

        private func conform(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            if buffer.format == pcmFormat { return buffer }
            if resampler == nil || resampler?.inputFormat != buffer.format {
                resampler = AVAudioConverter(from: buffer.format, to: pcmFormat)
                resampler?.downmix = true
            }
            guard let resampler else { return nil }
            let ratio = pcmFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            // Reuse the conversion buffer while it is large enough; it is only read before the next call.
            if (conformed?.frameCapacity ?? 0) < capacity {
                conformed = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: max(capacity, 8192))
            }
            guard let output = conformed else { return nil }
            output.frameLength = 0
            let once = OnceFlag()
            var error: NSError?
            let status = resampler.convert(to: output, error: &error) { _, inputStatus in
                if once.used {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                once.used = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error {
                Log.encoder.error(
                    "PCM conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                return nil
            }
            return output
        }

        /// Tracks the overall peak and one peak per `EncodedChunk.levelInterval` seconds.
        private func trackLevels(_ pcm: AVAudioPCMBuffer) {
            guard let channel = pcm.floatChannelData?[0] else { return }
            let interval = Int(EncodedChunk.levelInterval * pcmFormat.sampleRate)
            var index = 0
            let count = Int(pcm.frameLength)
            while index < count {
                // The peak of the rest of this level window (vectorized), then close the window if it is full.
                let take = min(interval - levelFrames, count - index)
                var windowPeak: Float = 0
                vDSP_maxmgv(channel + index, 1, &windowPeak, vDSP_Length(take))
                if windowPeak.isFinite { levelPeak = max(levelPeak, min(windowPeak, 1)) }
                levelFrames += take
                index += take
                if levelFrames == interval {
                    pendingLevels.append(levelPeak)
                    recentLevel = levelPeak
                    peak = max(peak, levelPeak)
                    levelPeak = 0
                    levelFrames = 0
                }
            }
        }

        private func collect(_ output: AVAudioCompressedBuffer) {
            guard output.packetCount > 0, let descriptions = output.packetDescriptions else { return }
            let base = output.data.assumingMemoryBound(to: UInt8.self)
            for index in 0..<Int(output.packetCount) {
                let description = descriptions[index]
                let size = Int(description.mDataByteSize)
                pendingData.append(base.advanced(by: Int(description.mStartOffset)), count: size)
                pendingSizes.append(size)
            }
        }

        private var packetSeconds: Double { 1024 / pcmFormat.sampleRate }

        private var pendingDuration: Double { Double(pendingSizes.count) * packetSeconds }

        private func makeChunk() -> EncodedChunk? {
            guard !pendingSizes.isEmpty, let anchor else { return nil }
            if levelFrames > 0 {
                pendingLevels.append(levelPeak)
                peak = max(peak, levelPeak)
                levelPeak = 0
                levelFrames = 0
            }
            let start = anchor.addingTimeInterval(Double(packetsSinceAnchor) * packetSeconds)
            // The chunk gets an exact-size copy: `pendingData` grows by doubling, so handing it over as it is would
            // keep up to twice the memory per chunk for the whole time the chunk is held. The working buffer is
            // then reused for the next chunk.
            var data = Data(count: pendingData.count)
            data.withUnsafeMutableBytes { _ = pendingData.copyBytes(to: $0) }
            let chunk = EncodedChunk(
                source: source, start: start, duration: pendingDuration, data: data,
                packetSizes: Array(pendingSizes), levels: pendingLevels)
            packetsSinceAnchor += pendingSizes.count
            pendingData.removeAll(keepingCapacity: true)
            pendingSizes = []
            pendingLevels = []
            return chunk
        }
    }
#endif
