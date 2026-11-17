#if os(macOS)
@preconcurrency import AVFoundation
import Foundation
import TapeloopCore

/// A one-shot flag for converter input blocks.
private final class OnceFlag: @unchecked Sendable {
    var used = false
}

/// Encodes live PCM into AAC-LC packets and groups them into `EncodedChunk`s of about `chunkSeconds`.
///
/// Raw PCM never stays here longer than one call. Not thread-safe: call it from one thread or under a lock
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
    /// The highest absolute sample value seen so far (0 to 1).
    public private(set) var peak: Float = 0

    private let converter: AVAudioConverter
    private var resampler: AVAudioConverter?
    private var pendingData = Data()
    private var pendingSizes: [Int] = []
    private var chunkStart: Date?

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
    }

    /// The AAC magic cookie a file writer needs.
    public var magicCookie: Data? { converter.magicCookie }

    /// The stream description of the compressed format.
    public var streamDescription: AudioStreamBasicDescription { aacFormat.streamDescription.pointee }

    /// Encodes one PCM buffer captured at `time`. Returns the chunks completed by it (often none).
    public func append(_ input: AVAudioPCMBuffer, at time: Date) -> [EncodedChunk] {
        guard let pcm = conform(input), pcm.frameLength > 0 else { return [] }
        trackPeak(pcm)
        if chunkStart == nil { chunkStart = time }
        var completed: [EncodedChunk] = []
        let once = OnceFlag()
        while true {
            let output = AVAudioCompressedBuffer(
                format: aacFormat, packetCapacity: 16,
                maximumPacketSize: max(converter.maximumOutputPacketSize, 2048))
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
                Log.encoder.error("AAC encode failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                break
            }
            collect(output)
            if let chunk = takeChunkIfFull() { completed.append(chunk) }
            if status != .haveData { break }
        }
        return completed
    }

    /// Returns the partial chunk held so far, if any.
    public func flush() -> EncodedChunk? {
        makeChunk()
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
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return nil }
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
            Log.encoder.error("PCM conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return output
    }

    private func trackPeak(_ pcm: AVAudioPCMBuffer) {
        guard let channel = pcm.floatChannelData?[0] else { return }
        for index in 0..<Int(pcm.frameLength) {
            peak = max(peak, abs(channel[index]))
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

    private var pendingDuration: Double {
        Double(pendingSizes.count * 1024) / pcmFormat.sampleRate
    }

    private func takeChunkIfFull() -> EncodedChunk? {
        pendingDuration >= chunkSeconds ? makeChunk() : nil
    }

    private func makeChunk() -> EncodedChunk? {
        guard !pendingSizes.isEmpty, let start = chunkStart else { return nil }
        let chunk = EncodedChunk(
            source: source, start: start, duration: pendingDuration, data: pendingData, packetSizes: pendingSizes)
        pendingData = Data()
        pendingSizes = []
        chunkStart = chunk.end
        return chunk
    }
}
#endif
