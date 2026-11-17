import Foundation

/// The arithmetic of the in-memory buffer: how many bytes a length costs and how long a budget lasts.
public struct MemoryBudget: Sendable, Equatable {
    /// The default RAM ceiling before the (opt-in) disk spill: 500 MB.
    public static let defaultRAMLimitBytes = 500 * 1_000_000

    /// The encoded bit rate of each enabled source, in bits per second.
    public var bitRates: [Int]
    /// The RAM ceiling in bytes.
    public var ramLimitBytes: Int
    /// Fractional overhead for packet tables and container bookkeeping (0.03 = 3 %).
    public var overhead: Double

    /// Creates a budget.
    public init(bitRates: [Int], ramLimitBytes: Int = MemoryBudget.defaultRAMLimitBytes, overhead: Double = 0.03) {
        self.bitRates = bitRates
        self.ramLimitBytes = ramLimitBytes
        self.overhead = overhead
    }

    /// Bytes per second for all sources together, overhead included.
    public var bytesPerSecond: Double {
        Double(bitRates.reduce(0, +)) / 8 * (1 + overhead)
    }

    /// The bytes needed to hold `duration` seconds.
    public func bytes(for duration: TimeInterval) -> Int {
        Int((bytesPerSecond * max(0, duration)).rounded(.up))
    }

    /// The longest buffer that fits in the RAM ceiling, in seconds.
    public var maxDurationInRAM: TimeInterval {
        bytesPerSecond > 0 ? Double(ramLimitBytes) / bytesPerSecond : .infinity
    }

    /// How a requested length would be held.
    public enum Plan: Equatable, Sendable {
        /// It all fits in RAM.
        case ramOnly(duration: TimeInterval)
        /// The newest part stays in RAM; the older part goes to disk (the user allowed it).
        case spill(ramDuration: TimeInterval, diskDuration: TimeInterval)
        /// The user did not allow disk, so the length is cut to what fits.
        case shortened(to: TimeInterval, requested: TimeInterval)
    }

    /// Plans a requested buffer length.
    public func plan(requested: TimeInterval, allowDisk: Bool) -> Plan {
        let fit = maxDurationInRAM
        if requested <= fit { return .ramOnly(duration: requested) }
        if allowDisk { return .spill(ramDuration: fit, diskDuration: requested - fit) }
        return .shortened(to: fit, requested: requested)
    }
}
