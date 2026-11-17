import Foundation

/// The opt-in disk part of the buffer: chunks that no longer fit in RAM, one small file each.
///
/// It exists only while the app runs. The folder is emptied when the store is created and when `removeAll` runs
/// (the app calls it on quit), so nothing recorded survives a restart. Only metadata stays in memory; the packets
/// and their size table are read back from disk when a save needs them. Not thread-safe: the owner serialises access.
public final class DiskSpillStore: @unchecked Sendable {
    /// Where a spilled chunk lives and what it covers.
    public struct Entry: Sendable, Equatable {
        /// The source of the audio.
        public var source: SourceKind
        /// The first sample's time.
        public var start: Date
        /// The length in seconds.
        public var duration: TimeInterval
        /// The peak levels, kept in memory for the timeline.
        public var levels: [Float]
        /// The file holding the size table and the packets.
        public var file: URL
        /// The file's size in bytes.
        public var bytes: Int

        /// The span covered.
        public var range: TimeRange { TimeRange(start: start, end: start.addingTimeInterval(duration)) }
    }

    /// Errors from the disk store.
    public enum SpillError: Error, CustomStringConvertible {
        /// A file could not be written (for example, the disk is full).
        case writeFailed(String)
        /// A file could not be read back or is damaged.
        case readFailed(String)

        public var description: String {
            switch self {
            case .writeFailed(let detail): "Could not write audio to disk: \(detail)"
            case .readFailed(let detail): "Could not read audio back from disk: \(detail)"
            }
        }
    }

    /// The folder that holds the chunk files.
    public let folder: URL
    /// The spilled chunks, oldest first.
    public private(set) var entries: [Entry] = []
    /// The total bytes on disk.
    public private(set) var bytes = 0

    /// Creates the store and empties `folder` (left-overs from a previous run are deleted).
    public init(folder: URL) throws {
        self.folder = folder
        try? FileManager.default.removeItem(at: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw SpillError.writeFailed("\(folder.path): \(error.localizedDescription)")
        }
    }

    /// Writes `chunk` to a file and records it.
    public func append(_ chunk: EncodedChunk) throws {
        let file = folder.appendingPathComponent("\(UUID().uuidString).chunk")
        var blob = Data()
        blob.append(UInt32(chunk.packetSizes.count).littleEndianData)
        blob.append(UInt32(chunk.framesPerPacket).littleEndianData)
        for size in chunk.packetSizes { blob.append(UInt32(size).littleEndianData) }
        blob.append(chunk.data)
        do {
            try blob.write(to: file)
        } catch {
            throw SpillError.writeFailed(error.localizedDescription)
        }
        entries.append(
            Entry(
                source: chunk.source, start: chunk.start, duration: chunk.duration, levels: chunk.levels, file: file,
                bytes: blob.count))
        bytes += blob.count
    }

    /// Deletes the chunks that end before `cutoff`. Returns how many were deleted.
    @discardableResult
    public func trim(before cutoff: Date) -> Int {
        let old = entries.prefix { $0.range.end <= cutoff }
        for entry in old {
            try? FileManager.default.removeItem(at: entry.file)
            bytes -= entry.bytes
        }
        entries.removeFirst(old.count)
        return old.count
    }

    /// The entries that overlap `range`, oldest first (metadata only; nothing is read).
    public func entries(overlapping range: TimeRange) -> [Entry] {
        entries.filter { $0.range.end > range.start && $0.range.start < range.end }
    }

    /// Reads back the chunks that overlap `range`, oldest first.
    public func chunks(overlapping range: TimeRange) throws -> [EncodedChunk] {
        try entries(overlapping: range).map(Self.load)
    }

    /// Deletes every file and the folder's content.
    public func removeAll() {
        for entry in entries { try? FileManager.default.removeItem(at: entry.file) }
        entries.removeAll()
        bytes = 0
    }

    /// Reads one spilled chunk back. Safe to call without the owner's lock: it touches only the file. Throws
    /// `readFailed` when the file is gone (it may have aged out meanwhile) or damaged.
    public static func load(_ entry: Entry) throws -> EncodedChunk {
        let blob: Data
        do {
            blob = try Data(contentsOf: entry.file)
        } catch {
            throw SpillError.readFailed(error.localizedDescription)
        }
        guard blob.count >= 8 else { throw SpillError.readFailed("\(entry.file.lastPathComponent) is too short") }
        let count = Int(blob.uint32(at: 0))
        let framesPerPacket = Int(blob.uint32(at: 4))
        let header = 8 + count * 4
        guard blob.count >= header else { throw SpillError.readFailed("\(entry.file.lastPathComponent) is damaged") }
        let sizes = (0..<count).map { Int(blob.uint32(at: 8 + $0 * 4)) }
        guard header + sizes.reduce(0, +) == blob.count else {
            throw SpillError.readFailed("\(entry.file.lastPathComponent) is damaged")
        }
        return EncodedChunk(
            source: entry.source, start: entry.start, duration: entry.duration,
            data: blob.subdata(in: header..<blob.count),
            packetSizes: sizes, framesPerPacket: framesPerPacket, levels: entry.levels)
    }
}

extension UInt32 {
    fileprivate var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}

extension Data {
    fileprivate func uint32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) {
            copyBytes(to: $0, from: (startIndex + offset)..<(startIndex + offset + 4))
        }
        return UInt32(littleEndian: value)
    }
}
