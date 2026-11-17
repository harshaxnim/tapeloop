import Foundation
import TapeloopCore
import XCTest

final class SourceBufferTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tapeloop-spill-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A 5 s chunk of 10 packets whose bytes encode the packet index, so slices can be checked.
    private func chunk(at offset: TimeInterval, packets: Int = 10, packetBytes: Int = 100) -> EncodedChunk {
        var data = Data()
        for index in 0..<packets { data.append(Data(repeating: UInt8(index), count: packetBytes)) }
        return EncodedChunk(
            source: .microphone, start: t0.addingTimeInterval(offset), duration: 5, data: data,
            packetSizes: Array(repeating: packetBytes, count: packets),
            levels: Array(repeating: 0.5, count: 10))
    }

    // MARK: slicing

    func testSliceKeepsOverlappingPacketsOnly() throws {
        let whole = chunk(at: 0)
        // Packets are 0.5 s each; ask for 1.2 s to 3.1 s → packets 2...6 (1.0 s to 3.5 s).
        let slice = try XCTUnwrap(whole.sliced(to: TimeRange(start: t0 + 1.2, end: t0 + 3.1)))
        XCTAssertEqual(slice.packetSizes.count, 5)
        XCTAssertEqual(slice.start, t0 + 1.0)
        XCTAssertEqual(slice.duration, 2.5, accuracy: 1e-9)
        XCTAssertEqual(slice.data.first, 2)
        XCTAssertEqual(slice.data.last, 6)
        XCTAssertEqual(slice.data.count, 500)
        XCTAssertEqual(slice.levels.count, 5)
    }

    func testSliceOutsideIsNilAndInsideIsIdentity() {
        let whole = chunk(at: 0)
        XCTAssertNil(whole.sliced(to: TimeRange(start: t0 + 6, end: t0 + 9)))
        XCTAssertEqual(whole.sliced(to: TimeRange(start: t0 - 1, end: t0 + 9)), whole)
    }

    func testSliceOfSliceStaysConsistent() throws {
        let first = try XCTUnwrap(chunk(at: 0).sliced(to: TimeRange(start: t0 + 1, end: t0 + 4)))
        let second = try XCTUnwrap(first.sliced(to: TimeRange(start: t0 + 2, end: t0 + 3)))
        XCTAssertEqual(second.packetSizes.count, 2)
        XCTAssertEqual(second.data.first, 4)
        XCTAssertEqual(second.data.last, 5)
    }

    // MARK: RAM only

    func testRAMOnlyKeepsTheRequestedLength() {
        var buffer = SourceBuffer(source: .microphone, duration: 20)
        for i in 0..<10 { buffer.append(chunk(at: Double(i) * 5)) }
        XCTAssertEqual(buffer.range?.duration, 20)
        XCTAssertNil(buffer.disk)
        XCTAssertEqual(buffer.bytesOnDisk, 0)
    }

    // MARK: spill

    func testSpillMovesOldAudioToDiskAndReadsItBack() throws {
        var buffer = SourceBuffer(source: .microphone, duration: 20)
        buffer.apply(.spill(ramDuration: 10, diskDuration: 20), spillFolder: folder)
        for i in 0..<10 { buffer.append(chunk(at: Double(i) * 5)) }
        // Newest ends at 50 s. RAM keeps 40-50 s, disk keeps 20-40 s, older is deleted.
        XCTAssertEqual(buffer.ram.chunks.count, 2)
        XCTAssertEqual(buffer.disk?.entries.count, 4)
        XCTAssertEqual(buffer.range, TimeRange(start: t0 + 20, end: t0 + 50))
        XCTAssertGreaterThan(buffer.bytesOnDisk, 0)
        let files = try FileManager.default.contentsOfDirectory(
            at: folder.appendingPathComponent("microphone"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 4)

        let back = try buffer.chunks(overlapping: TimeRange(start: t0 + 22, end: t0 + 43))
        XCTAssertEqual(back.count, 5)
        XCTAssertEqual(back.first, chunk(at: 20))
        XCTAssertEqual(back.last, chunk(at: 40))
    }

    func testPiecesLoadOutsideTheLock() throws {
        var buffer = SourceBuffer(source: .microphone, duration: 20)
        buffer.apply(.spill(ramDuration: 10, diskDuration: 10), spillFolder: folder)
        for i in 0..<4 { buffer.append(chunk(at: Double(i) * 5)) }
        let pieces = buffer.pieces(overlapping: TimeRange(start: t0, end: t0 + 20))
        XCTAssertEqual(pieces.disk.count, 2)
        XCTAssertEqual(pieces.ram.count, 2)
        XCTAssertEqual(try DiskSpillStore.load(pieces.disk[0]), chunk(at: 0))
    }

    func testTurningSpillOffDeletesTheDiskPart() {
        var buffer = SourceBuffer(source: .microphone, duration: 20)
        buffer.apply(.spill(ramDuration: 10, diskDuration: 10), spillFolder: folder)
        for i in 0..<4 { buffer.append(chunk(at: Double(i) * 5)) }
        let diskFolder = buffer.disk!.folder
        buffer.apply(.ramOnly(duration: 10), spillFolder: nil)
        XCTAssertNil(buffer.disk)
        XCTAssertFalse(FileManager.default.fileExists(atPath: diskFolder.path))
        XCTAssertEqual(buffer.range?.duration, 10)
    }

    func testDiskStoreWipesLeftoversOnCreate() throws {
        let sub = folder.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: sub.appendingPathComponent("stale.chunk"))
        _ = try DiskSpillStore(folder: sub)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sub.path), [])
    }

    func testDamagedFileIsReported() throws {
        let store = try DiskSpillStore(folder: folder)
        try store.append(chunk(at: 0))
        try Data([9]).write(to: store.entries[0].file)
        XCTAssertThrowsError(try DiskSpillStore.load(store.entries[0]))
    }

    // MARK: memory pressure

    func testMemoryPressureFreesRAM() {
        var buffer = SourceBuffer(source: .microphone, duration: 3600)
        for i in 0..<10 { buffer.append(chunk(at: Double(i) * 5)) }
        let before = buffer.bytesInRAM
        buffer.relieveMemoryPressure(keepingFraction: 0.5)
        XCTAssertLessThanOrEqual(buffer.bytesInRAM, before / 2)
        XCTAssertEqual(buffer.ram.chunks.last?.end, t0 + 50, "the newest audio is kept")
    }
}

final class RecorderSettingsTests: XCTestCase {
    func testDefaults() {
        let settings = RecorderSettings()
        XCTAssertEqual(settings.sources, [.microphone, .system])
        XCTAssertEqual(settings.plan, .ramOnly(duration: 7200))
        XCTAssertTrue(settings.saveFolder.path.hasSuffix("Music/Tapeloop"))
    }

    func testOldJSONLoadsWithDefaults() throws {
        let json = #"{"bitRate": 64000}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(RecorderSettings.self, from: json)
        XCTAssertEqual(settings.bitRate, 64_000)
        XCTAssertEqual(settings.bufferDuration, 7200)
        XCTAssertTrue(settings.mixSources)
    }

    func testRoundTrip() throws {
        var settings = RecorderSettings()
        settings.allowDisk = true
        settings.sources = [.system]
        settings.saveFolderPath = "/tmp/x"
        let back = try JSONDecoder().decode(RecorderSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back, settings)
    }

    func testLongBufferAtHighRateNeedsDisk() {
        var settings = RecorderSettings(bitRate: 96_000, bufferDuration: 10 * 3600)
        if case .shortened = settings.plan {} else { XCTFail("expected shortened, got \(settings.plan)") }
        settings.allowDisk = true
        if case .spill = settings.plan {} else { XCTFail("expected spill, got \(settings.plan)") }
    }
}

extension Date {
    fileprivate static func + (lhs: Date, rhs: TimeInterval) -> Date { lhs.addingTimeInterval(rhs) }
}
