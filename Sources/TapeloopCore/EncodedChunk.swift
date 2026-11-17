import Foundation

/// Which input a chunk of audio came from.
public enum SourceKind: String, Codable, CaseIterable, Sendable {
    /// The microphone (the user's side of a conversation).
    case microphone
    /// The system audio (the other side of a call, videos, anything the Mac plays).
    case system

    /// A label for the UI.
    public var label: String {
        switch self {
        case .microphone: "Microphone"
        case .system: "System audio"
        }
    }
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
    /// The peak level (0 to 1) of each `levelInterval` seconds of audio, for the timeline's waveform.
    public var levels: [Float]

    /// The span each entry of `levels` covers, in seconds.
    public static let levelInterval: TimeInterval = 0.5

    /// Creates a chunk.
    public init(
        source: SourceKind, start: Date, duration: TimeInterval, data: Data, packetSizes: [Int],
        framesPerPacket: Int = 1024, levels: [Float] = []
    ) {
        self.source = source
        self.start = start
        self.duration = duration
        self.data = data
        self.packetSizes = packetSizes
        self.framesPerPacket = framesPerPacket
        self.levels = levels
    }

    /// The wall-clock time just after the last sample.
    public var end: Date { start.addingTimeInterval(duration) }

    /// The span the chunk covers.
    public var range: TimeRange { TimeRange(start: start, end: end) }

    /// The memory this chunk costs: its payload plus the packet and level tables.
    public var byteCost: Int {
        data.count + packetSizes.count * MemoryLayout<Int>.size + levels.count * MemoryLayout<Float>.size
    }

    /// The seconds one packet lasts.
    public var packetDuration: TimeInterval {
        packetSizes.isEmpty ? 0 : duration / Double(packetSizes.count)
    }

    /// The packets that overlap `range`, as a new chunk, or `nil` when none do.
    ///
    /// The cut is at packet boundaries (about 21 ms for AAC at 48 kHz), so the result may start up to one packet
    /// before `range.start` and end up to one packet after `range.end`.
    public func sliced(to range: TimeRange) -> EncodedChunk? {
        guard range.end > start, range.start < end, !packetSizes.isEmpty else { return nil }
        let step = packetDuration
        let first = max(0, Int((range.start.timeIntervalSince(start) / step).rounded(.down)))
        let last = min(packetSizes.count, Int((range.end.timeIntervalSince(start) / step).rounded(.up)))
        guard first < last else { return nil }
        if first == 0 && last == packetSizes.count { return self }
        let offset = packetSizes[..<first].reduce(0, +)
        let length = packetSizes[first..<last].reduce(0, +)
        let levelFirst = min(levels.count, Int(Double(first) * step / Self.levelInterval))
        let levelLast = min(levels.count, Int((Double(last) * step / Self.levelInterval).rounded(.up)))
        return EncodedChunk(
            source: source, start: start.addingTimeInterval(Double(first) * step),
            duration: Double(last - first) * step, data: data.subdata(in: offset..<(offset + length)),
            packetSizes: Array(packetSizes[first..<last]), framesPerPacket: framesPerPacket,
            levels: Array(levels[levelFirst..<max(levelFirst, levelLast)]))
    }
}
