import Foundation

/// Which input a chunk of audio came from.
public enum SourceKind: String, Codable, CaseIterable, Sendable {
    /// The microphone (the user's side of a conversation).
    case microphone
    /// The system audio (the other side of a call, videos, anything the Mac plays).
    case system
}

/// A few seconds of compressed audio from one source, as it sits in memory.
///
/// `data` holds the encoded packets back to back; `packetSizes` gives each packet's byte length, so the packets
/// can be written to a file without re-encoding.
public struct EncodedChunk: Sendable, Equatable {
    /// The source that produced the audio.
    public var source: SourceKind
    /// The wall-clock time of the first sample.
    public var start: Date
    /// The audio length in seconds.
    public var duration: TimeInterval
    /// The encoded packets, back to back.
    public var data: Data
    /// The byte length of each packet in `data`, in order.
    public var packetSizes: [Int]
    /// Decoded frames per packet (1024 for AAC-LC).
    public var framesPerPacket: Int

    /// Creates a chunk.
    public init(
        source: SourceKind, start: Date, duration: TimeInterval, data: Data, packetSizes: [Int],
        framesPerPacket: Int = 1024
    ) {
        self.source = source
        self.start = start
        self.duration = duration
        self.data = data
        self.packetSizes = packetSizes
        self.framesPerPacket = framesPerPacket
    }

    /// The wall-clock time just after the last sample.
    public var end: Date { start.addingTimeInterval(duration) }

    /// The span the chunk covers.
    public var range: TimeRange { TimeRange(start: start, end: end) }

    /// The memory this chunk costs: its payload plus the packet table.
    public var byteCost: Int { data.count + packetSizes.count * MemoryLayout<Int>.size }
}
