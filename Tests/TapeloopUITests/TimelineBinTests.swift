#if os(macOS)
    import Foundation
    import XCTest

    @testable import TapeloopUI

    /// How recorded levels (one per half second) become the tape's bars.
    final class TimelineBinTests: XCTestCase {
        private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

        /// A piece of audio `seconds` long with a reading every half second.
        private func piece(from offset: TimeInterval, seconds: TimeInterval, level: (Int) -> Float = { _ in 0.4 })
            -> (start: Date, duration: TimeInterval, levels: [Float])
        {
            (t0.addingTimeInterval(offset), seconds, (0..<Int(seconds * 2)).map(level))
        }

        func testAShortTapeFillsEveryBar() {
            // 20 seconds held: 40 readings for 120 bars.
            let bins = TimelineData.bin(
                [piece(from: 0, seconds: 20)], from: t0, to: t0.addingTimeInterval(20), count: 120)
            XCTAssertFalse(bins.contains(-1), "no empty bars inside recorded audio: \(bins)")
        }

        func testAShortTapeIsSmoothBetweenReadings() {
            // Readings alternate quiet and loud; bars between them take values in between.
            let bins = TimelineData.bin(
                [piece(from: 0, seconds: 10) { $0 % 2 == 0 ? 0.1 : 0.9 }], from: t0, to: t0.addingTimeInterval(10),
                count: 120)
            XCTAssertTrue(bins.contains { $0 > 0.2 && $0 < 0.8 }, "interpolated values between the readings")
            XCTAssertLessThanOrEqual(bins.max() ?? 0, 0.9)
        }

        func testGapsStayEmpty() {
            let bins = TimelineData.bin(
                [piece(from: 0, seconds: 10), piece(from: 20, seconds: 10)], from: t0, to: t0.addingTimeInterval(30),
                count: 120)
            XCTAssertTrue(bins[45...75].allSatisfy { $0 == -1 }, "nothing was recorded from 10 s to 20 s")
            XCTAssertFalse(bins[0..<38].contains(-1))
            XCTAssertFalse(bins[82..<120].contains(-1))
        }

        func testALongTapeKeepsPeaks() {
            // Two hours: many readings per bar; a single loud reading still shows.
            let loud = 3000
            let bins = TimelineData.bin(
                [piece(from: 0, seconds: 7200) { $0 == loud ? 0.95 : 0.1 }], from: t0, to: t0.addingTimeInterval(7200),
                count: 120)
            XCTAssertEqual(bins.max() ?? 0, 0.95, accuracy: 0.0001)
            XCTAssertEqual(bins.filter { $0 > 0.5 }.count, 1)
        }
    }
#endif
