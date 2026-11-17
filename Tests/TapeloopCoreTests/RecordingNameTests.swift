import Foundation
import TapeloopCore
import XCTest

final class RecordingNameTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testName() {
        let start = Date(timeIntervalSince1970: 1_794_924_300)  // 2026-11-17 14:05 UTC
        XCTAssertEqual(
            RecordingName.make(start: start, duration: 900, title: "Standup: team/a", timeZone: utc),
            "Tapeloop 2026-11-17 14.05 (15 min) Standup- team-a.m4a")
        XCTAssertEqual(
            RecordingName.make(start: start, duration: 45, timeZone: utc), "Tapeloop 2026-11-17 14.05 (45 s).m4a")
    }

    func testLengthLabels() {
        XCTAssertEqual(RecordingName.lengthLabel(3900), "1 h 05 min")
        XCTAssertEqual(RecordingName.lengthLabel(59.6), "1 min")
    }
}
