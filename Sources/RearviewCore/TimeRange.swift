import Foundation

/// A closed span of wall-clock time, `start <= end`.
public struct TimeRange: Codable, Hashable, Sendable {
    /// The first instant in the span.
    public var start: Date
    /// The last instant in the span.
    public var end: Date

    /// Creates a span; swaps the bounds if they are given in the wrong order.
    public init(start: Date, end: Date) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    /// The span that ends at `end` and lasts `duration` seconds.
    public static func last(_ duration: TimeInterval, endingAt end: Date) -> TimeRange {
        TimeRange(start: end.addingTimeInterval(-max(0, duration)), end: end)
    }

    /// The length in seconds.
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// The overlap of two spans, or `nil` when they do not touch.
    public func intersection(_ other: TimeRange) -> TimeRange? {
        let lower = max(start, other.start)
        let upper = min(end, other.end)
        return lower <= upper ? TimeRange(start: lower, end: upper) : nil
    }

    /// This span clamped to `bounds`, or `nil` when they do not overlap.
    public func clamped(to bounds: TimeRange) -> TimeRange? { intersection(bounds) }

    /// Whether `date` lies inside the span (bounds included).
    public func contains(_ date: Date) -> Bool { date >= start && date <= end }
}
