import Foundation

/// What the user can configure about recording and saving. Stored as JSON in the app's defaults.
///
/// New fields must have defaults in `init(from:)`, so settings written by an older version still load.
public struct RecorderSettings: Codable, Equatable, Sendable {
    /// The sources being recorded.
    public var sources: Set<SourceKind>
    /// The encoded bit rate of each source, in bits per second.
    public var bitRate: Int
    /// The buffer length the user asked for, in seconds.
    public var bufferDuration: TimeInterval
    /// Whether the part of the buffer beyond `ramLimitBytes` may go to disk.
    public var allowDisk: Bool
    /// The RAM ceiling for the buffer, in bytes.
    public var ramLimitBytes: Int
    /// The folder saved recordings go to, or `nil` for the default (`~/Music/Tapeloop`).
    public var saveFolderPath: String?
    /// With both sources on, whether a save writes one mixed file (`true`) or one file per source.
    public var mixSources: Bool

    /// The buffer lengths offered in Settings, in seconds.
    public static let presetDurations: [TimeInterval] = [15 * 60, 30 * 60, 3600, 2 * 3600, 5 * 3600]
    /// The bit rates offered in Settings, in bits per second.
    public static let presetBitRates = [32_000, 48_000, 64_000, 96_000]

    /// The defaults: both sources, 48 kbps, two hours, RAM only, 500 MB ceiling, one mixed file.
    public init(
        sources: Set<SourceKind> = [.microphone, .system], bitRate: Int = 48_000, bufferDuration: TimeInterval = 7200,
        allowDisk: Bool = false, ramLimitBytes: Int = MemoryBudget.defaultRAMLimitBytes, saveFolderPath: String? = nil,
        mixSources: Bool = true
    ) {
        self.sources = sources
        self.bitRate = bitRate
        self.bufferDuration = bufferDuration
        self.allowDisk = allowDisk
        self.ramLimitBytes = ramLimitBytes
        self.saveFolderPath = saveFolderPath
        self.mixSources = mixSources
    }

    public init(from decoder: Decoder) throws {
        let defaults = RecorderSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent(Set<SourceKind>.self, forKey: .sources) ?? defaults.sources
        bitRate = try c.decodeIfPresent(Int.self, forKey: .bitRate) ?? defaults.bitRate
        bufferDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .bufferDuration) ?? defaults.bufferDuration
        allowDisk = try c.decodeIfPresent(Bool.self, forKey: .allowDisk) ?? defaults.allowDisk
        ramLimitBytes = try c.decodeIfPresent(Int.self, forKey: .ramLimitBytes) ?? defaults.ramLimitBytes
        saveFolderPath = try c.decodeIfPresent(String.self, forKey: .saveFolderPath)
        mixSources = try c.decodeIfPresent(Bool.self, forKey: .mixSources) ?? defaults.mixSources
    }

    /// The RAM/disk arithmetic for these settings.
    public var budget: MemoryBudget {
        MemoryBudget(bitRates: Array(repeating: bitRate, count: max(1, sources.count)), ramLimitBytes: ramLimitBytes)
    }

    /// How the requested length will be held.
    public var plan: MemoryBudget.Plan {
        budget.plan(requested: bufferDuration, allowDisk: allowDisk)
    }

    /// The default save folder: `~/Music/Tapeloop`.
    public static var defaultSaveFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Tapeloop", isDirectory: true)
    }

    /// The folder saves go to.
    public var saveFolder: URL {
        saveFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultSaveFolder
    }
}
