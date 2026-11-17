#if os(macOS)
    import XCTest

    @testable import TapeloopUI

    final class SettingsTextTests: XCTestCase {
        func testQualityHelpMatchesTheSelection() {
            let low = RecordingTab.qualityHelp(bitRate: 32_000, sources: 2)
            XCTAssertTrue(low.hasPrefix("32 kbps"), low)
            XCTAssertTrue(low.contains("thin"), low)
            XCTAssertTrue(low.contains("15 MB of memory per hour per source"), low)
            XCTAssertTrue(low.contains("30 MB per hour with both sources"), low)

            let normal = RecordingTab.qualityHelp(bitRate: 48_000, sources: 1)
            XCTAssertTrue(normal.contains("recommended"), normal)
            XCTAssertTrue(normal.contains("22 MB of memory per hour per source."), normal)
            XCTAssertFalse(normal.contains("both sources"), normal)

            XCTAssertTrue(RecordingTab.qualityHelp(bitRate: 64_000, sources: 2).contains("music in the background"))
            XCTAssertTrue(RecordingTab.qualityHelp(bitRate: 96_000, sources: 2).contains("for music"))
            for rate in [32_000, 48_000, 64_000, 96_000] {
                XCTAssertFalse(RecordingTab.qualityHelp(bitRate: rate, sources: 2).isEmpty)
            }
        }
    }
#endif
