import Foundation

/// The rolling buffer of one source: the newest audio in RAM and, if the user allowed it, the older part on disk.
///
/// Chunks enter the RAM ring. Chunks that age out of the RAM part go to the disk store when spilling is on, or are
/// discarded. Chunks older than the whole buffer length are deleted everywhere. Not thread-safe: the owner
/// serialises access (`CaptureSink` uses a lock).
public struct SourceBuffer: Sendable {
    /// The source this buffer holds.
    public let source: SourceKind
    /// The newest audio, in RAM.
    public private(set) var ram: ChunkRing
    /// The older audio on disk, when spilling is on.
    public private(set) var disk: DiskSpillStore?
    /// The whole buffer length in seconds (RAM part plus disk part).
    public private(set) var totalDuration: TimeInterval
    /// The last error from the disk part (for example, a full disk). The buffer then keeps only the RAM part.
    public private(set) var diskError: String?

    /// Creates a RAM-only buffer that keeps `duration` seconds.
    public init(source: SourceKind, duration: TimeInterval) {
        self.source = source
        self.ram = ChunkRing(maxDuration: duration)
        self.totalDuration = duration
    }

    /// Applies a plan from `MemoryBudget`. `spillFolder` is needed only for `.spill`; the disk part is created on
    /// first use of a spill plan and deleted when the plan no longer spills.
    public mutating func apply(_ plan: MemoryBudget.Plan, spillFolder: URL?) {
        switch plan {
        case .ramOnly(let duration):
            ram.maxDuration = duration
            totalDuration = duration
            dropDisk()
        case .shortened(let duration, _):
            ram.maxDuration = duration
            totalDuration = duration
            dropDisk()
        case .spill(let ramDuration, let diskDuration):
            ram.maxDuration = ramDuration
            totalDuration = ramDuration + diskDuration
            if disk == nil, let spillFolder {
                do {
                    disk = try DiskSpillStore(folder: spillFolder.appendingPathComponent(source.rawValue))
                    diskError = nil
                } catch {
                    diskError = "\(error)"
                }
            }
        }
        if let newest = ram.chunks.last?.end { settle(now: newest) }
    }

    /// Adds a chunk, moves what ages out of RAM to disk (or discards it) and trims the disk part.
    public mutating func append(_ chunk: EncodedChunk) {
        spill(ram.append(chunk))
        disk?.trim(before: chunk.end.addingTimeInterval(-totalDuration))
    }

    /// Frees RAM when macOS reports memory pressure: keeps `fraction` of the RAM part. With spilling on, the
    /// oldest audio moves to disk; otherwise it is lost.
    public mutating func relieveMemoryPressure(keepingFraction fraction: Double) {
        spill(ram.shrink(keepingFraction: fraction))
    }

    /// The bytes held in RAM.
    public var bytesInRAM: Int { ram.bytes }
    /// The bytes held on disk.
    public var bytesOnDisk: Int { disk?.bytes ?? 0 }

    /// The span from the oldest sample (disk included) to the newest, or `nil` when empty.
    public var range: TimeRange? {
        guard let end = ram.chunks.last?.end ?? disk?.entries.last?.range.end else { return nil }
        guard let start = disk?.entries.first?.start ?? ram.chunks.first?.start else { return nil }
        return TimeRange(start: start, end: end)
    }

    /// The chunks overlapping `range`, oldest first, read back from disk where needed.
    public func chunks(overlapping range: TimeRange) throws -> [EncodedChunk] {
        let fromDisk = try disk?.chunks(overlapping: range) ?? []
        return fromDisk + ram.chunks(overlapping: range)
    }

    /// What a save of `range` needs, taken quickly (call it under the owner's lock): the in-RAM chunks and the
    /// disk entries to read back later with `DiskSpillStore.load`, outside the lock.
    public func pieces(overlapping range: TimeRange) -> (disk: [DiskSpillStore.Entry], ram: [EncodedChunk]) {
        (disk?.entries(overlapping: range) ?? [], ram.chunks(overlapping: range))
    }

    /// Every chunk's span and peak levels, oldest first, without reading audio from disk. For the timeline.
    public var levelTrack: [(start: Date, duration: TimeInterval, levels: [Float])] {
        (disk?.entries.map { ($0.start, $0.duration, $0.levels) } ?? [])
            + ram.chunks.map { ($0.start, $0.duration, $0.levels) }
    }

    /// Deletes everything, RAM and disk.
    public mutating func removeAll() {
        ram.removeAll()
        disk?.removeAll()
    }

    private mutating func settle(now: Date) {
        spill(ram.trim(now: now))
        disk?.trim(before: now.addingTimeInterval(-totalDuration))
    }

    private mutating func spill(_ dropped: [EncodedChunk]) {
        guard let disk, !dropped.isEmpty else { return }
        do {
            for chunk in dropped { try disk.append(chunk) }
        } catch {
            // A full or failing disk: stop spilling, keep the RAM part, report it.
            diskError = "\(error)"
            dropDisk()
        }
    }

    private mutating func dropDisk() {
        disk?.removeAll()
        if let folder = disk?.folder { try? FileManager.default.removeItem(at: folder) }
        disk = nil
    }
}
