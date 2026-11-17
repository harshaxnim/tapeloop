#if os(macOS)
    @preconcurrency import AVFoundation
    import Foundation
    import TapeloopCore

    /// Mixes several sources into one AAC file, streaming: it decodes about one second at a time, so a five-hour
    /// save needs a few megabytes of memory, not gigabytes.
    enum Mixer {
        static let sampleRate = 48_000.0
        static let blockFrames = 48_000

        static func mix(
            _ sources: [ExportSource], range: TimeRange, bitRate: Int, to url: URL, progress: (Double) -> Void
        ) throws {
            guard
                let pcm = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
            else { throw Exporter.ExportError.write("PCM format") }
            let readers = try sources.map { try SourceReader(source: $0, rangeStart: range.start, pcm: pcm) }
            let total = Int((range.duration * sampleRate).rounded())
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ]
            // Scoped so the file is closed (on deinit) before the caller renames it.
            try {
                let file = try AVAudioFile(
                    forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard let block = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(blockFrames)) else {
                    throw Exporter.ExportError.write("buffer")
                }
                var position = 0
                while position < total {
                    if Task.isCancelled { throw Exporter.ExportError.cancelled }
                    let count = min(blockFrames, total - position)
                    let out = block.floatChannelData![0]
                    for index in 0..<count { out[index] = 0 }
                    for reader in readers {
                        let samples = reader.take(count, at: position)
                        for index in 0..<count { out[index] += samples[index] }
                    }
                    // Clamp to avoid wrap-around distortion when both sides are loud at once.
                    for index in 0..<count { out[index] = max(-1, min(1, out[index])) }
                    block.frameLength = AVAudioFrameCount(count)
                    try file.write(from: block)
                    position += count
                    progress(Double(position) / Double(max(1, total)))
                }
            }()
        }
    }

    /// Decodes one source's chunks in time order and hands out samples by timeline position (frames from the save's
    /// start). Gaps between chunks become silence; the decoder is reset after a gap.
    final class SourceReader {
        private let chunks: [EncodedChunk]
        private let rangeStart: Date
        private let decoder: ChunkDecoder
        private var next = 0
        /// Decoded samples not yet handed out, starting at timeline frame `pendingStart` (from `head` on).
        private var pending: [Float] = []
        private var head = 0
        private var pendingStart = 0
        private var started = false

        /// A gap longer than this many frames between chunks is filled with silence.
        private let gapTolerance = Int(0.25 * Mixer.sampleRate)

        init(source: ExportSource, rangeStart: Date, pcm: AVAudioFormat) throws {
            chunks = source.chunks
            self.rangeStart = rangeStart
            decoder = try ChunkDecoder(
                streamDescription: source.streamDescription, magicCookie: source.magicCookie, pcm: pcm)
        }

        /// Exactly `count` samples for timeline frames `[position, position + count)`.
        func take(_ count: Int, at position: Int) -> [Float] {
            fill(upTo: position + count)
            // Drop what lies before `position` (the first chunk may start a packet early).
            if pendingStart < position {
                let drop = min(position - pendingStart, pending.count - head)
                head += drop
                pendingStart += drop
            }
            var result = [Float](repeating: 0, count: count)
            let lead = max(0, pendingStart - position)  // silence before this source's audio begins
            let available = pending.count - head
            let copy = max(0, min(count - lead, available))
            if copy > 0 {
                for index in 0..<copy { result[lead + index] = pending[head + index] }
                head += copy
                pendingStart += copy
            }
            if head > 1_000_000 {
                pending.removeFirst(head)
                head = 0
            }
            return result
        }

        private var pendingEnd: Int { pendingStart + pending.count - head }

        private func fill(upTo end: Int) {
            while pendingEnd < end, next < chunks.count {
                let chunk = chunks[next]
                next += 1
                let offset = Int((chunk.start.timeIntervalSince(rangeStart) * Mixer.sampleRate).rounded())
                if !started {
                    pendingStart = offset
                    started = true
                } else if offset - pendingEnd > gapTolerance {
                    pending.append(contentsOf: [Float](repeating: 0, count: offset - pendingEnd))
                    decoder.reset()
                }
                pending.append(contentsOf: decoder.decode(chunk))
            }
            if next >= chunks.count, pendingEnd < end {
                pending.append(contentsOf: decoder.drain())
            }
        }
    }

    /// Decodes AAC packets to mono Float32 PCM, keeping decoder state across consecutive chunks.
    final class ChunkDecoder {
        private let aac: AVAudioFormat
        private let pcm: AVAudioFormat
        private let magicCookie: Data?
        private var converter: AVAudioConverter

        init(streamDescription: AudioStreamBasicDescription, magicCookie: Data?, pcm: AVAudioFormat) throws {
            var description = streamDescription
            guard let aac = AVAudioFormat(streamDescription: &description),
                let converter = AVAudioConverter(from: aac, to: pcm)
            else { throw Exporter.ExportError.write("AAC decoder") }
            converter.magicCookie = magicCookie
            self.aac = aac
            self.pcm = pcm
            self.magicCookie = magicCookie
            self.converter = converter
        }

        func reset() {
            converter.reset()
        }

        func decode(_ chunk: EncodedChunk) -> [Float] {
            guard !chunk.packetSizes.isEmpty else { return [] }
            let input = AVAudioCompressedBuffer(
                format: aac, packetCapacity: AVAudioPacketCount(chunk.packetSizes.count),
                maximumPacketSize: max(chunk.packetSizes.max() ?? 0, 1))
            chunk.data.withUnsafeBytes { raw in
                input.data.copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            var offset: Int64 = 0
            for (index, size) in chunk.packetSizes.enumerated() {
                input.packetDescriptions![index] = AudioStreamPacketDescription(
                    mStartOffset: offset, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
                offset += Int64(size)
            }
            input.packetCount = AVAudioPacketCount(chunk.packetSizes.count)
            input.byteLength = UInt32(chunk.data.count)
            return run(input: input, endOfStream: false, expectedFrames: chunk.packetSizes.count * 1024)
        }

        /// Returns the samples the decoder still holds.
        func drain() -> [Float] {
            run(input: nil, endOfStream: true, expectedFrames: 4096)
        }

        private func run(input: AVAudioCompressedBuffer?, endOfStream: Bool, expectedFrames: Int) -> [Float] {
            var samples: [Float] = []
            samples.reserveCapacity(expectedFrames)
            let once = OnceFlag()
            while true {
                guard let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 4096) else { break }
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, inputStatus in
                    if once.used || input == nil {
                        inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                        return nil
                    }
                    once.used = true
                    inputStatus.pointee = .haveData
                    return input
                }
                if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                    samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
                }
                if status != .haveData { break }
            }
            return samples
        }
    }

    /// A one-shot flag for converter input blocks.
    private final class OnceFlag: @unchecked Sendable {
        var used = false
    }
#endif
