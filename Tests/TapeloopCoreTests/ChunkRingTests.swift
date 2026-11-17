import Foundation
import TapeloopCore
import XCTest

final class ChunkRingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func chunk(at offset: TimeInterval, length: TimeInterval = 5, bytes: Int = 1000) -> EncodedChunk {
        EncodedChunk(
            source: .microphone, start: t0.addingTimeInterval(offset), duration: length,
            data: Data(count: bytes), packetSizes: [bytes])
    }

    func testEmpty() {
        let ring = ChunkRing(maxDuration: 60)
        XCTAssertNil(ring.range)
        XCTAssertEqual(ring.bytes, 0)
    }

    func testDropsByAge() {
        var ring = ChunkRing(maxDuration: 20)
        for i in 0..<10 { ring.append(chunk(at: Double(i) * 5)) }
        // Newest ends at 50 s; keep chunks ending after 30 s: 30-35 ... 45-50.
        XCTAssertEqual(ring.chunks.count, 4)
        XCTAssertEqual(ring.range?.duration, 20)
        XCTAssertEqual(ring.bytes, 4 * ring.chunks[0].byteCost)
    }

    func testClockSetBackKeepsTheRingInOrder() {
        var ring = ChunkRing(maxDuration: 20)
        ring.append(chunk(at: 0))
        ring.append(chunk(at: 5))
        // The clock goes back an hour: the next chunks follow on from the newest one instead.
        ring.append(chunk(at: -3600))
        ring.append(chunk(at: -3595))
        XCTAssertEqual(ring.chunks.map { $0.start.timeIntervalSince(t0) }, [0, 5, 10, 15])
        XCTAssertEqual(ring.range?.duration, 20)
        XCTAssertTrue(ring.gaps().isEmpty)
        // Trimming still works: the oldest falls out as new audio arrives.
        ring.append(chunk(at: -3590))
        XCTAssertEqual(ring.range?.duration, 20)
    }

    func testSmallJitterIsNotTreatedAsTheClockGoingBack() {
        var ring = ChunkRing(maxDuration: 60)
        ring.append(chunk(at: 0))
        ring.append(chunk(at: 4.8))
        XCTAssertEqual(ring.chunks[1].start.timeIntervalSince(t0), 4.8, accuracy: 0.001)
    }

    func testDropsByBytes() {
        var ring = ChunkRing(maxDuration: 3600, maxBytes: 3 * chunk(at: 0).byteCost)
        var dropped: [EncodedChunk] = []
        for i in 0..<5 { dropped += ring.append(chunk(at: Double(i) * 5)) }
        XCTAssertEqual(ring.chunks.count, 3)
        XCTAssertEqual(dropped.count, 2)
        XCTAssertEqual(dropped.first?.start, t0)
    }

    func testOverlapAndGaps() {
        var ring = ChunkRing(maxDuration: 3600)
        ring.append(chunk(at: 0))
        ring.append(chunk(at: 5))
        ring.append(chunk(at: 100))  // a sleep gap from 10 s to 100 s
        let picked = ring.chunks(
            overlapping: TimeRange(start: t0.addingTimeInterval(7), end: t0.addingTimeInterval(101)))
        XCTAssertEqual(picked.count, 2)
        XCTAssertEqual(ring.gaps(), [TimeRange(start: t0.addingTimeInterval(10), end: t0.addingTimeInterval(100))])
        XCTAssertEqual(ring.heldDuration, 15)
    }

    func testRemoveAll() {
        var ring = ChunkRing(maxDuration: 60)
        ring.append(chunk(at: 0))
        ring.removeAll()
        XCTAssertEqual(ring.bytes, 0)
        XCTAssertTrue(ring.chunks.isEmpty)
    }
}
