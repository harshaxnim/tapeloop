#if os(macOS)
    import Foundation
    import TapeloopCore
    import XCTest

    @testable import TapeloopIntelligence

    /// A process list the test sets by hand.
    final class FakeProcessProvider: AudioProcessProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [AudioProcessInfo] = []

        func set(_ bundleIDs: [String], pid: pid_t = 4242) {
            lock.withLock {
                processes = bundleIDs.enumerated().map {
                    AudioProcessInfo(pid: pid + pid_t($0.offset), bundleID: $0.element)
                }
            }
        }

        func set(processes: [AudioProcessInfo]) { lock.withLock { self.processes = processes } }

        func processesUsingInput() -> [AudioProcessInfo] { lock.withLock { processes } }
    }

    final class MeetingDetectorTests: XCTestCase {
        private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        private var provider = FakeProcessProvider()
        private var detector: MeetingDetector!
        private var events: [MeetingEvent] = []

        override func setUp() {
            provider = FakeProcessProvider()
            detector = MeetingDetector(pollInterval: 1, provider: provider)
            events = []
        }

        /// Ticks once a second over `seconds` (inclusive bounds), with `bundleIDs` using input.
        private func run(_ seconds: ClosedRange<Int>, _ bundleIDs: [String]) {
            provider.set(bundleIDs)
            for second in seconds { events += detector.tick(now: at(second)) }
        }

        private func at(_ second: Int) -> Date { t0.addingTimeInterval(TimeInterval(second)) }

        func testStartsAfterFiveSecondsOfInput() {
            run(0...4, ["us.zoom.xos"])
            XCTAssertTrue(events.isEmpty)
            XCTAssertTrue(detector.current.isEmpty)
            run(5...5, ["us.zoom.xos"])
            XCTAssertEqual(events.count, 1)
            guard case .started(let span) = events.first else { return XCTFail("expected a start") }
            XCTAssertEqual(span.start, t0, "the span starts when input began, not when it was confirmed")
            XCTAssertNil(span.end)
            XCTAssertEqual(span.info, MeetingInfo(appName: "Zoom", bundleID: "us.zoom.xos"))
            XCTAssertEqual(detector.current, [span])
        }

        func testShortBlipIsNotAMeeting() {
            run(0...3, ["us.zoom.xos"])
            run(4...30, [])
            run(31...34, ["us.zoom.xos"])
            run(35...60, [])
            XCTAssertTrue(events.isEmpty)
            XCTAssertTrue(detector.current.isEmpty)
        }

        func testEndsTenSecondsAfterInputStopsWithTheStopTime() {
            run(0...30, ["us.zoom.xos"])
            run(31...40, [])
            XCTAssertEqual(events.count, 1, "still within the 10 s grace period")
            run(41...41, [])
            XCTAssertEqual(events.count, 2)
            guard case .started(let started) = events[0], case .ended(let ended) = events[1] else {
                return XCTFail("expected start then end: \(events)")
            }
            XCTAssertEqual(ended.id, started.id)
            XCTAssertEqual(ended.start, t0)
            XCTAssertEqual(ended.end, at(31), "the end is when input stopped, not when the debounce ran out")
            XCTAssertTrue(detector.current.isEmpty)
        }

        func testMuteShorterThanTenSecondsDoesNotSplit() {
            run(0...20, ["us.zoom.xos"])
            run(21...29, [])
            run(30...60, ["us.zoom.xos"])
            run(61...80, [])
            XCTAssertEqual(events.count, 2)
            guard case .ended(let span) = events.last else { return XCTFail("expected an end") }
            XCTAssertEqual(span.start, t0)
            XCTAssertEqual(span.end, at(61))
        }

        func testHelperProcessesMapToTheirApp() {
            let cases: [(String, String?)] = [
                ("com.google.Chrome.helper", "com.google.Chrome"),
                ("com.google.Chrome.helper.Renderer", "com.google.Chrome"),
                ("company.thebrowser.browser.helper", "company.thebrowser.Browser"),
                ("com.apple.WebKit.GPU", "com.apple.Safari"),
                ("com.apple.WebKit.WebContent", "com.apple.Safari"),
                ("com.microsoft.edgemac.helper", "com.microsoft.edgemac"),
                ("com.brave.Browser.helper", "com.brave.Browser"),
                ("org.mozilla.plugincontainer", "org.mozilla.firefox"),
                ("com.microsoft.teams2", "com.microsoft.teams2"),
                ("com.microsoft.teams2.helper", "com.microsoft.teams2"),
                ("com.microsoft.teams", "com.microsoft.teams2"),
                ("com.tinyspeck.slackmacgap.helper", "com.tinyspeck.slackmacgap"),
                ("Cisco-Systems.Spark", "com.cisco.webexmeetingsapp"),
                ("US.ZOOM.XOS", "us.zoom.xos"),
                ("com.google.Chromeish", nil),
                ("com.example.recorder", nil),
                ("", nil),
            ]
            for (bundleID, expected) in cases {
                XCTAssertEqual(MeetingApp.app(forBundleID: bundleID)?.id, expected, bundleID)
            }

            run(0...5, ["com.google.Chrome.helper", "com.google.Chrome"])
            XCTAssertEqual(events.count, 1, "an app's processes count as one meeting")
            XCTAssertEqual(events.first?.span.info, MeetingInfo(appName: "Chrome call", bundleID: "com.google.Chrome"))
        }

        func testOwnProcessIsIgnored() {
            provider.set(processes: [AudioProcessInfo(pid: getpid(), bundleID: "us.zoom.xos")])
            for second in 0...30 { events += detector.tick(now: at(second)) }
            XCTAssertTrue(events.isEmpty)
        }

        func testUnknownAppsAreIgnored() {
            run(0...30, ["com.apple.VoiceMemos", "com.example.dictation"])
            XCTAssertTrue(events.isEmpty)
        }

        func testOverlappingAppsAreTrackedSeparately() {
            run(0...9, ["us.zoom.xos"])
            run(10...30, ["us.zoom.xos", "com.google.Chrome.helper"])
            XCTAssertEqual(detector.current.map(\.info.appName), ["Zoom", "Chrome call"])
            run(31...50, ["com.google.Chrome.helper"])
            run(51...70, [])
            let summary = events.map { event -> String in
                switch event {
                case .started(let span): "start \(span.info.appName) \(span.start.timeIntervalSince(t0))"
                case .ended(let span):
                    "end \(span.info.appName) \(span.end!.timeIntervalSince(t0))"
                }
            }
            XCTAssertEqual(
                summary, ["start Zoom 0.0", "start Chrome call 10.0", "end Zoom 31.0", "end Chrome call 51.0"])
        }

        func testSleepGapsDoNotStretchMeetings() {
            // Input seen once, then the Mac sleeps: the run restarts on wake instead of starting a meeting at once.
            run(0...0, ["us.zoom.xos"])
            run(600...600, ["us.zoom.xos"])
            XCTAssertTrue(events.isEmpty)
            run(601...605, ["us.zoom.xos"])
            XCTAssertEqual(events.first?.span.start, at(600))

            // A meeting going on at sleep that is over at wake ends at the last poll that saw input.
            run(606...620, ["us.zoom.xos"])
            run(2000...2000, [])
            guard case .ended(let span) = events.last else { return XCTFail("expected an end") }
            XCTAssertEqual(span.end, at(620))
        }

        func testStopForgetsOngoingMeetingsWithoutEndEvents() {
            run(0...10, ["us.zoom.xos"])
            XCTAssertEqual(detector.current.count, 1)
            detector.stop()
            XCTAssertTrue(detector.current.isEmpty)
            XCTAssertEqual(events.count, 1)
        }

        func testStartDeliversEventsThroughTheHandler() {
            // Every poll reads the clock once and moves it on by a second, so the 5 s pass in a few real polls.
            let clock = TestClock(t0, step: 1)
            let detector = MeetingDetector(pollInterval: 0.4, provider: provider, clock: { clock.now })
            provider.set(["us.zoom.xos"])
            let started = expectation(description: "started")
            detector.start { event in
                if case .started = event { started.fulfill() }
            }
            wait(for: [started], timeout: 10)
            detector.stop()
        }

        func testKnownAppsAreWellFormed() {
            let ids = MeetingApp.known.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count)
            for app in MeetingApp.known {
                for bundleID in app.bundleIDs {
                    XCTAssertEqual(MeetingApp.app(forBundleID: bundleID)?.id, app.id, bundleID)
                }
            }
        }
    }

    /// A clock that moves on by `step` seconds every time it is read.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        private let step: TimeInterval

        init(_ date: Date, step: TimeInterval) {
            self.date = date
            self.step = step
        }

        var now: Date {
            lock.withLock {
                defer { date += step }
                return date
            }
        }
    }
#endif
