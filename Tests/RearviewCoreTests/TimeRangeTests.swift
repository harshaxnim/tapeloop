import Foundation
import RearviewCore
import XCTest

final class TimeRangeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testInitOrdersBounds() {
        let range = TimeRange(start: t0.addingTimeInterval(10), end: t0)
        XCTAssertEqual(range.start, t0)
        XCTAssertEqual(range.duration, 10)
    }

    func testLastMinutes() {
        let range = TimeRange.last(300, endingAt: t0)
        XCTAssertEqual(range.duration, 300)
        XCTAssertEqual(range.end, t0)
    }

    func testIntersection() {
        let a = TimeRange(start: t0, end: t0.addingTimeInterval(60))
        let b = TimeRange(start: t0.addingTimeInterval(30), end: t0.addingTimeInterval(90))
        XCTAssertEqual(a.intersection(b)?.duration, 30)
        let c = TimeRange(start: t0.addingTimeInterval(100), end: t0.addingTimeInterval(200))
        XCTAssertNil(a.intersection(c))
    }

    func testClampedToBufferStart() {
        let buffer = TimeRange(start: t0, end: t0.addingTimeInterval(600))
        let asked = TimeRange.last(3600, endingAt: t0.addingTimeInterval(600))
        XCTAssertEqual(asked.clamped(to: buffer), buffer)
    }

    func testIdentity() {
        XCTAssertEqual(RearviewInfo.bundleIdentifier, "io.github.harshaxnim.rearview")
    }
}
