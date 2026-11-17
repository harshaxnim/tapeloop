import Foundation

/// An in-memory ring of encoded chunks for one source: the rolling buffer.
///
/// Appending past the length or byte limit drops the oldest chunks. Not thread-safe; the owner serialises access
/// (an actor or a lock).
public struct ChunkRing: Sendable {
    /// The longest span of audio kept, in seconds.
    public var maxDuration: TimeInterval
    /// The most bytes kept; `nil` means no byte limit.
    public var maxBytes: Int?
    /// How far a chunk may start before the previous one ends before it counts as the clock going backwards
    /// (encoder timing jitter is far smaller).
    public static let backwardsTolerance: TimeInterval = 0.5

    /// The chunks, oldest first.
    public private(set) var chunks: [EncodedChunk] = []
    /// The total byte cost of all chunks.
    public private(set) var bytes: Int = 0

    /// Creates an empty ring.
    public init(maxDuration: TimeInterval, maxBytes: Int? = nil) {
        self.maxDuration = maxDuration
        self.maxBytes = maxBytes
    }

    /// The span from the oldest sample to the newest, or `nil` when empty.
    public var range: TimeRange? {
        guard let first = chunks.first, let last = chunks.last else { return nil }
        return TimeRange(start: first.start, end: last.end)
    }

    /// The seconds of audio held (gaps excluded).
    public var heldDuration: TimeInterval { chunks.reduce(0) { $0 + $1.duration } }

    /// Adds a chunk and drops what no longer fits. Returns the dropped chunks, oldest first.
    ///
    /// A chunk that starts before the newest one ends (the Mac's clock was set back) is placed right after it: the
    /// audio did come later, and the ring must stay in order for trimming, the timeline and saving.
    @discardableResult
    public mutating func append(_ chunk: EncodedChunk) -> [EncodedChunk] {
        var chunk = chunk
        if let last = chunks.last, chunk.start < last.end.addingTimeInterval(-Self.backwardsTolerance) {
            chunk.start = last.end
        }
        chunks.append(chunk)
        bytes += chunk.byteCost
        return trim(now: chunk.end)
    }

    /// Drops chunks older than `maxDuration` before `now`, then the oldest until under `maxBytes`.
    @discardableResult
    public mutating func trim(now: Date) -> [EncodedChunk] {
        let cutoff = now.addingTimeInterval(-maxDuration)
        var dropCount = 0
        var dropBytes = 0
        for chunk in chunks {
            let overBytes = maxBytes.map { bytes - dropBytes > $0 } ?? false
            guard chunk.end <= cutoff || overBytes else { break }
            dropCount += 1
            dropBytes += chunk.byteCost
        }
        guard dropCount > 0 else { return [] }
        let dropped = Array(chunks.prefix(dropCount))
        chunks.removeFirst(dropCount)
        bytes -= dropBytes
        return dropped
    }

    /// The chunks that overlap `range`, oldest first.
    public func chunks(overlapping range: TimeRange) -> [EncodedChunk] {
        chunks.filter { $0.end > range.start && $0.start < range.end }
    }

    /// The gaps (for example sleep) longer than `tolerance` seconds between consecutive chunks.
    public func gaps(tolerance: TimeInterval = 0.5) -> [TimeRange] {
        zip(chunks, chunks.dropFirst()).compactMap { previous, next in
            next.start.timeIntervalSince(previous.end) > tolerance
                ? TimeRange(start: previous.end, end: next.start) : nil
        }
    }

    /// Drops the oldest chunks until at most `fraction` (0 to 1) of the current bytes remain. Used when macOS
    /// reports memory pressure. Returns the dropped chunks, oldest first.
    @discardableResult
    public mutating func shrink(keepingFraction fraction: Double) -> [EncodedChunk] {
        let target = Int(Double(bytes) * min(1, max(0, fraction)))
        var dropCount = 0
        var dropBytes = 0
        for chunk in chunks where bytes - dropBytes > target {
            dropCount += 1
            dropBytes += chunk.byteCost
        }
        guard dropCount > 0 else { return [] }
        let dropped = Array(chunks.prefix(dropCount))
        chunks.removeFirst(dropCount)
        bytes -= dropBytes
        return dropped
    }

    /// Empties the ring.
    public mutating func removeAll() {
        chunks.removeAll()
        bytes = 0
    }
}
