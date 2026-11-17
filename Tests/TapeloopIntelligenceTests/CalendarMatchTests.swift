#if os(macOS)
    import Foundation
    import TapeloopCore
    import TapeloopIntelligence
    import XCTest

    final class CalendarMatchTests: XCTestCase {
        private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        private func range(_ startMinute: Double, _ endMinute: Double) -> TimeRange {
            TimeRange(start: t0.addingTimeInterval(startMinute * 60), end: t0.addingTimeInterval(endMinute * 60))
        }

        private func event(_ title: String, _ startMinute: Double, _ endMinute: Double, allDay: Bool = false)
            -> CalendarEvent
        {
            CalendarEvent(title: title, range: range(startMinute, endMinute), isAllDay: allDay)
        }

        func testPicksTheLargestOverlap() {
            let meeting = range(0, 60)
            let events = [event("Standup", -10, 15), event("Planning", 10, 70), event("Lunch", 55, 90)]
            XCTAssertEqual(CalendarProvider.bestMatch(for: meeting, among: events)?.title, "Planning")
        }

        func testIgnoresAllDayAndUntitledEvents() {
            let meeting = range(0, 30)
            let events = [event("Holiday", -600, 900, allDay: true), event("", 0, 30)]
            XCTAssertNil(CalendarProvider.bestMatch(for: meeting, among: events))
        }

        func testNeedsHalfTheShorterSpanOrFiveMinutes() {
            let meeting = range(0, 60)
            // 4 min of a 60 min event: less than 5 min and less than half of either span.
            XCTAssertNil(CalendarProvider.bestMatch(for: meeting, among: [event("Tail", 56, 116)]))
            // 6 min is enough: more than 5 min.
            XCTAssertEqual(CalendarProvider.bestMatch(for: meeting, among: [event("Tail", 54, 114)])?.title, "Tail")
            // A 2 min meeting inside a long event: the overlap is all of the shorter span.
            XCTAssertEqual(CalendarProvider.bestMatch(for: range(20, 22), among: [event("Call", 0, 60)])?.title, "Call")
            // A 4 min event fully inside a long meeting: half of the shorter span (2 min) is covered.
            XCTAssertEqual(
                CalendarProvider.bestMatch(for: meeting, among: [event("Quick sync", 10, 14)])?.title, "Quick sync")
            // A meeting that only touches an event's edge does not match.
            XCTAssertNil(CalendarProvider.bestMatch(for: meeting, among: [event("Before", -30, 0)]))
        }

        func testJustStartedMeetingMatchesItsEvent() {
            // Five seconds into a call that the calendar says runs for 30 minutes.
            let meeting = TimeRange(start: t0, end: t0.addingTimeInterval(5))
            XCTAssertEqual(CalendarProvider.bestMatch(for: meeting, among: [event("1:1", -1, 29)])?.title, "1:1")
        }

        func testTieGoesToTheEventStartingClosest() {
            let meeting = range(0, 10)
            let events = [event("Long", -50, 10), event("Exact", 0, 40)]
            XCTAssertEqual(CalendarProvider.bestMatch(for: meeting, among: events)?.title, "Exact")
        }

        func testEndedEventsInWindow() {
            let window = range(0, 5)
            let events = [
                event("Ended before", -60, 0), event("Ends in window", -30, 3), event("Ends at window end", -30, 5),
                event("Still going", -10, 20), event("All day", -600, 4, allDay: true),
            ]
            XCTAssertEqual(
                CalendarProvider.ended(in: window, among: events).map(\.title),
                ["Ends in window", "Ends at window end"])
        }
    }
#endif
