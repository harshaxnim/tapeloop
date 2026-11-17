import Foundation
import TapeloopCore
import XCTest

final class MemoryBudgetTests: XCTestCase {
    func testFiveHoursOfTwoStreamsAt48k() {
        let budget = MemoryBudget(bitRates: [48_000, 48_000], overhead: 0)
        XCTAssertEqual(budget.bytes(for: 5 * 3600), 216_000_000)
        XCTAssertEqual(budget.plan(requested: 5 * 3600, allowDisk: false), .ramOnly(duration: 5 * 3600))
    }

    func testOverLimitShortensOrSpills() {
        let budget = MemoryBudget(bitRates: [128_000, 128_000], overhead: 0)
        let fit = budget.maxDurationInRAM
        XCTAssertEqual(fit, 500_000_000 / 32_000, accuracy: 0.001)
        XCTAssertEqual(budget.plan(requested: 10 * 3600, allowDisk: false), .shortened(to: fit, requested: 10 * 3600))
        XCTAssertEqual(
            budget.plan(requested: 10 * 3600, allowDisk: true), .spill(ramDuration: fit, diskDuration: 36_000 - fit))
    }

    func testNoSources() {
        let budget = MemoryBudget(bitRates: [])
        XCTAssertEqual(budget.bytes(for: 3600), 0)
        XCTAssertEqual(budget.maxDurationInRAM, .infinity)
    }
}
