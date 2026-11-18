#if os(macOS)
    import AppKit
    import TapeloopCore
    import XCTest

    @testable import TapeloopUI

    /// User-level tests of the popover: real pointer and keyboard events on the real views.
    @MainActor
    final class TimelineDragTests: XCTestCase {
        private func state(_ name: String) -> PopoverState {
            if name == "partial" {
                // A tape only partly filled: 4 minutes held on a 15-minute axis (the left 70 % has no audio).
                var state = Samples.popoverStates().first { $0.name == "just-started" }!.state
                state.timeline = Samples.timeline(hours: 0.25, held: 240, gaps: [])
                return state
            }
            return Samples.popoverStates().first { $0.name == name }!.state
        }

        private func harness(_ name: String, selection: TimeInterval = 36 * 60, quick: Int? = nil) -> PopoverHarness {
            PopoverHarness(state: state(name), selection: selection, quick: quick)
        }

        // MARK: Dragging the handle

        func testHarnessFindsTheTimelineAndControls() {
            let h = harness("recording")
            defer { h.close() }
            XCTAssertGreaterThan(h.timeline.width, 300, "\(h.timeline)")
            for name in ["knob", "save", "more"] {
                XCTAssertTrue(h.has(name), "missing \(name): \(h.model.controlFrames.keys.sorted())")
            }
        }

        func testDraggingFarLeftSticksToTheLeft() {
            let h = harness("recording")
            defer { h.close() }
            h.drag(
                from: CGPoint(x: h.handleX, y: h.timeline.midY),
                to: CGPoint(x: h.timeline.minX - 80, y: h.timeline.midY))
            XCTAssertTrue(h.model.pinnedToOldest)
            XCTAssertEqual(h.model.clampedSelection, h.model.state.timeline.held, accuracy: 0.5)
            XCTAssertEqual(h.handleX, h.timeline.minX, accuracy: 1.5, "a full buffer's oldest audio is the left edge")
            XCTAssertNil(h.model.quickMinutes)
        }

        func testDraggingExactlyToTheLeftEdgeSticks() {
            let h = harness("recording")
            defer { h.close() }
            h.drag(
                from: CGPoint(x: h.handleX, y: h.timeline.midY), to: CGPoint(x: h.timeline.minX + 2, y: h.timeline.midY)
            )
            XCTAssertTrue(h.model.pinnedToOldest)
        }

        func testPinnedSelectionFollowsTheOldestAudioAsTimePasses() {
            // A buffer that is not full yet: 4 minutes held on a 15-minute axis.
            let h = harness("partial", selection: 120, quick: nil)
            defer { h.close() }
            let held = h.model.state.timeline.held
            h.drag(
                from: CGPoint(x: h.handleX, y: h.timeline.midY),
                to: CGPoint(x: h.timeline.minX - 30, y: h.timeline.midY))
            XCTAssertTrue(h.model.pinnedToOldest)
            XCTAssertEqual(h.model.clampedSelection, held, accuracy: 0.5)
            h.advance(90)
            XCTAssertEqual(h.model.clampedSelection, held + 90, accuracy: 0.5, "the selection grows with the tape")
            let oldestX = h.timeline.minX + h.timeline.width * CGFloat(1 - (held + 90) / h.model.state.timeline.span)
            XCTAssertEqual(h.handleX, oldestX, accuracy: 1.5, "the handle stays on the oldest audio")
        }

        func testUnpinnedSelectionKeepsItsLengthAsTimePasses() {
            let h = harness("recording")
            defer { h.close() }
            h.drag(from: CGPoint(x: h.handleX, y: h.timeline.midY), to: h.timelinePoint(0.75))
            XCTAssertFalse(h.model.pinnedToOldest)
            let chosen = h.model.clampedSelection
            h.advance(60)
            XCTAssertEqual(h.model.clampedSelection, chosen, accuracy: 0.5)
        }

        func testDraggingIntoEmptyTapeBeforeTheOldestAudioPins() {
            let h = harness("partial", selection: 60, quick: nil)
            defer { h.close() }
            // 4 of 15 minutes held: the left 70 % of the axis has no audio.
            h.drag(from: CGPoint(x: h.handleX, y: h.timeline.midY), to: h.timelinePoint(0.3))
            XCTAssertTrue(h.model.pinnedToOldest)
            XCTAssertEqual(h.model.clampedSelection, h.model.state.timeline.held, accuracy: 0.5)
        }

        func testDraggingFarRightGivesTheMinimum() {
            let h = harness("recording")
            defer { h.close() }
            h.drag(
                from: CGPoint(x: h.handleX, y: h.timeline.midY),
                to: CGPoint(x: h.timeline.maxX + 100, y: h.timeline.midY))
            XCTAssertFalse(h.model.pinnedToOldest)
            XCTAssertEqual(h.model.clampedSelection, PopoverModel.minimumSelection)
        }

        func testDraggingToTheMiddleSelectsThatTime() {
            let h = harness("recording")
            defer { h.close() }
            h.drag(from: CGPoint(x: h.handleX, y: h.timeline.midY), to: h.timelinePoint(0.5))
            let expected = 0.5 * h.model.state.timeline.span
            XCTAssertEqual(h.model.clampedSelection, expected, accuracy: h.model.state.timeline.span / 200)
            XCTAssertFalse(h.model.pinnedToOldest)
        }

        func testDragBackFromTheLeftUnpins() {
            let h = harness("recording")
            defer { h.close() }
            h.drag(
                from: CGPoint(x: h.handleX, y: h.timeline.midY),
                to: CGPoint(x: h.timeline.minX - 50, y: h.timeline.midY))
            XCTAssertTrue(h.model.pinnedToOldest)
            h.drag(from: CGPoint(x: h.handleX, y: h.timeline.midY), to: h.timelinePoint(0.8))
            XCTAssertFalse(h.model.pinnedToOldest)
            XCTAssertEqual(h.model.clampedSelection, 0.2 * h.model.state.timeline.span, accuracy: 60)
        }

        func testDraggingVerticallyOffTheTimelineStillTracks() {
            let h = harness("recording")
            defer { h.close() }
            h.drag(
                from: CGPoint(x: h.handleX, y: h.timeline.midY),
                to: CGPoint(x: h.timeline.minX - 20, y: h.timeline.minY - 200))
            XCTAssertTrue(h.model.pinnedToOldest)
        }

        func testClickOnTheTimelineMovesTheHandle() {
            let h = harness("recording")
            defer { h.close() }
            h.click(h.timelinePoint(0.9))
            XCTAssertEqual(h.model.clampedSelection, 0.1 * h.model.state.timeline.span, accuracy: 60)
            XCTAssertNil(h.model.quickMinutes)
        }

        func testSaveLabelFollowsTheHandle() {
            let h = harness("recording")
            defer { h.close() }
            h.drag(
                from: CGPoint(x: h.handleX, y: h.timeline.midY),
                to: CGPoint(x: h.timeline.minX - 10, y: h.timeline.midY))
            XCTAssertTrue(h.click(control: "save"))
            XCTAssertEqual(h.calls.last, "save \(Int(h.model.state.timeline.held.rounded()))")
        }

        // MARK: Quick spans (in the "more" menu; the menu calls these model methods)

        func testQuickSpansSelect() {
            let h = harness("recording")
            defer { h.close() }
            for minutes in [5, 15, 30, 60] {
                XCTAssertTrue(h.model.quickSpanAvailable(minutes))
                h.model.choose(minutes: minutes)
                h.pump()
                XCTAssertEqual(h.model.quickMinutes, minutes)
                XCTAssertEqual(h.model.clampedSelection, Double(minutes) * 60)
                XCTAssertFalse(h.model.pinnedToOldest)
            }
        }

        func testQuickSpanAfterPinningUnpins() {
            let h = harness("recording")
            defer { h.close() }
            h.drag(
                from: CGPoint(x: h.handleX, y: h.timeline.midY),
                to: CGPoint(x: h.timeline.minX - 50, y: h.timeline.midY))
            h.model.choose(minutes: 15)
            XCTAssertFalse(h.model.pinnedToOldest)
            XCTAssertEqual(h.model.clampedSelection, 900)
        }

        func testDraggingClearsTheQuickSpan() {
            let h = harness("recording", selection: 300, quick: 5)
            defer { h.close() }
            h.drag(from: CGPoint(x: h.handleX, y: h.timeline.midY), to: h.timelinePoint(0.6))
            XCTAssertNil(h.model.quickMinutes)
        }

        func testQuickSpansLongerThanTheTapeAreUnavailable() {
            let h = harness("partial", selection: 120, quick: nil)
            defer { h.close() }
            XCTAssertFalse(h.model.quickSpanAvailable(15), "15 min is unavailable with 4 min held")
            XCTAssertFalse(h.model.quickSpanAvailable(60))
            XCTAssertTrue(h.model.quickSpanAvailable(5), "5 min stays available")
            h.model.choose(minutes: 5)
            XCTAssertEqual(
                h.model.clampedSelection, h.model.state.timeline.held, accuracy: 0.5, "and saves what exists")
        }

        // MARK: Preview (the handle's play button)

        func testClickingTheKnobPreviewsTheSelection() {
            let h = harness("recording", selection: 900, quick: 15)
            defer { h.close() }
            XCTAssertTrue(h.click(control: "knob"))
            XCTAssertEqual(h.calls, ["preview 900"])
            XCTAssertEqual(h.model.clampedSelection, 900, "a click does not move the handle")
            XCTAssertTrue(h.click(control: "knob"))
            XCTAssertEqual(h.calls, ["preview 900", "preview 900"], "a second click stops it")
        }

        func testDraggingTheKnobMovesTheHandleWithoutPlaying() {
            let h = harness("recording")
            defer { h.close() }
            guard let knob = h.model.controlFrames["knob"] else { return XCTFail("no knob") }
            h.drag(from: CGPoint(x: knob.midX, y: knob.midY), to: CGPoint(x: h.timeline.minX - 40, y: knob.midY))
            XCTAssertTrue(h.model.pinnedToOldest)
            XCTAssertEqual(h.calls, [], "a drag is not a click")
        }

        func testSeekingWhilePlayingGoesOnFromTheNewPlace() {
            let h = harness("recording")
            defer { h.close() }
            h.click(control: "knob")
            XCTAssertNotNil(h.model.state.preview)
            h.drag(from: CGPoint(x: h.handleX, y: h.timeline.midY), to: h.timelinePoint(0.5))
            XCTAssertNotNil(h.model.state.preview, "the preview keeps playing")
            XCTAssertEqual(h.calls.count, 2, "one restart when the drag is released, not one per step: \(h.calls)")
            XCTAssertEqual(h.calls.last, "restart \(Int(h.model.selectedRange.duration.rounded()))")
        }

        func testSeekingWithTheKnobOrEndHandleOrAMeetingRestartsToo() {
            let h = harness("recording")
            defer { h.close() }
            h.click(control: "knob")
            guard let knob = h.model.controlFrames["knob"] else { return XCTFail("no knob") }
            h.drag(from: CGPoint(x: knob.midX, y: knob.midY), to: CGPoint(x: knob.midX - 60, y: knob.midY))
            XCTAssertTrue(h.calls.last?.hasPrefix("restart") ?? false, "\(h.calls)")
            h.drag(from: CGPoint(x: h.endX - 2, y: h.timeline.minY + 20), to: h.timelinePoint(0.9))
            XCTAssertEqual(h.calls.last, "restart \(Int(h.model.selectedRange.duration.rounded()))")
            h.click(control: "meeting-0")
            XCTAssertEqual(h.calls.last, "restart \(Int(h.model.selectedRange.duration.rounded()))")
            h.model.choose(minutes: 5)
            XCTAssertEqual(h.calls.last, "restart 300")
            XCTAssertNotNil(h.model.state.preview)
        }

        func testSeekingWhenNotPlayingDoesNotPlay() {
            let h = harness("recording")
            defer { h.close() }
            h.drag(from: CGPoint(x: h.handleX, y: h.timeline.midY), to: h.timelinePoint(0.5))
            h.click(control: "meeting-0")
            XCTAssertEqual(h.calls, [])
            XCTAssertNil(h.model.state.preview)
        }

        func testPreviewShowsProgressInsteadOfTheSpan() {
            var playing = state("recording")
            playing.preview = .init(elapsed: 691, duration: 2160)
            let h = PopoverHarness(state: playing, selection: 2160)
            defer { h.close() }
            XCTAssertTrue(h.has("save"), "Save stays available while previewing")
            XCTAssertEqual(playing.preview?.fraction ?? 0, 691.0 / 2160, accuracy: 0.0001)
            XCTAssertEqual(DurationText.clock(691), "11:31")
            XCTAssertEqual(DurationText.clock(3909), "1:05:09")
        }

        // MARK: Selecting a meeting, trimming the end

        func testClickingAMeetingSelectsOnlyIt() {
            let h = harness("recording")
            defer { h.close() }
            let zoom = h.model.state.timeline.meetings[0]
            XCTAssertTrue(h.click(control: "meeting-0"), "the meeting's line and name are a click target")
            XCTAssertEqual(h.model.selectedRange.start, zoom.start)
            XCTAssertEqual(h.model.selectedRange.end, zoom.end, "the end is trimmed to the meeting's end")
            XCTAssertEqual(h.model.selectedMeeting?.label, "Zoom · 10:41")
            XCTAssertFalse(h.model.endsNow)
            XCTAssertTrue(h.has("endHandle"))
            h.click(control: "save")
            XCTAssertEqual(h.calls, ["save \(Int(zoom.end.timeIntervalSince(zoom.start).rounded()))"])
        }

        func testAMeetingStillGoingEndsNow() {
            let h = harness("meeting")
            defer { h.close() }
            h.click(control: "meeting-0")
            XCTAssertTrue(h.model.endsNow, "a meeting that has not ended keeps recording into the selection")
            XCTAssertEqual(h.model.selectedRange.start, h.model.state.timeline.meetings[0].start)
            XCTAssertNotNil(h.model.selectedMeeting)
        }

        func testMeetingSelectionStaysPutAsTimePasses() {
            let h = harness("recording")
            defer { h.close() }
            h.click(control: "meeting-0")
            let range = h.model.selectedRange
            h.advance(120)
            XCTAssertEqual(h.model.selectedRange, range, "both ends are times, not distances from now")
        }

        func testMovingTheStartAfterAMeetingKeepsTheEnd() {
            let h = harness("recording")
            defer { h.close() }
            h.click(control: "meeting-0")
            let end = h.model.selectedRange.end
            h.drag(from: CGPoint(x: h.handleX, y: h.timeline.midY), to: h.timelinePoint(0.3))
            XCTAssertEqual(h.model.selectedRange.end, end)
            XCTAssertEqual(
                h.model.selectedRange.start.timeIntervalSince(h.date(at: 0.3)), 0,
                accuracy: h.model.state.timeline.span / 200)
            XCTAssertNil(h.model.selectedMeeting, "the selection is no longer exactly the meeting")
        }

        func testEndHandleIsHiddenUntilHoveringNearTheRightEnd() {
            let h = harness("recording")
            defer { h.close() }
            XCTAssertTrue(h.model.endsNow)
            h.hover(h.timelinePoint(0.5))
            h.hover(CGPoint(x: h.timeline.maxX - 6, y: h.timeline.minY + 20))
            guard let grip = h.model.controlFrames["endHandle"] else { return XCTFail("no end handle") }
            h.drag(from: CGPoint(x: grip.midX, y: grip.midY), to: h.timelinePoint(0.8))
            XCTAssertFalse(h.model.endsNow)
            XCTAssertEqual(
                h.model.selectedRange.end.timeIntervalSince(h.date(at: 0.8)), 0,
                accuracy: h.model.state.timeline.span / 150)
            h.click(control: "save")
            XCTAssertEqual(h.calls, ["save \(Int(h.model.selectedRange.duration.rounded()))"])
        }

        func testDraggingTheEndBackToTheRightEdgeEndsNow() {
            let h = harness("recording")
            defer { h.close() }
            h.model.dragEnd(to: h.date(at: 0.8))
            h.pump()
            h.drag(
                from: CGPoint(x: h.endX, y: h.timeline.minY + 20),
                to: CGPoint(x: h.timeline.maxX + 30, y: h.timeline.minY + 20))
            XCTAssertTrue(h.model.endsNow)
            XCTAssertEqual(h.model.selectedRange.duration, h.model.clampedSelection, accuracy: 0.01)
        }

        func testTheEndCannotPassTheStart() {
            let h = harness("recording", selection: 600, quick: nil)
            defer { h.close() }
            h.model.dragEnd(to: h.date(at: 0.1))
            XCTAssertEqual(h.model.selectedRange.duration, PopoverModel.minimumSelection, accuracy: 0.01)
        }

        func testQuickSpanEndsNowAgain() {
            let h = harness("recording")
            defer { h.close() }
            h.click(control: "meeting-0")
            h.model.choose(minutes: 15)
            XCTAssertTrue(h.model.endsNow)
            XCTAssertNil(h.model.selectedMeeting)
            XCTAssertEqual(h.model.selectedRange.duration, 900, accuracy: 0.01)
        }

        // MARK: Save, keyboard

        func testSaveSendsTheSelection() {
            let h = harness("recording", selection: 900, quick: 15)
            defer { h.close() }
            h.click(control: "save")
            XCTAssertEqual(h.calls, ["save 900"])
        }

        func testReturnSaves() {
            let h = harness("recording", selection: 300, quick: 5)
            defer { h.close() }
            h.pressReturn()
            XCTAssertEqual(h.calls, ["save 300"])
        }

        func testNothingHeldDisablesSaveAndChips() {
            var empty = state("recording")
            empty.timeline.heldStart = nil
            empty.timeline.lanes = []
            let h = PopoverHarness(state: empty)
            defer { h.close() }
            h.click(control: "save")
            XCTAssertFalse(h.model.quickSpanAvailable(5), "no quick span without audio")
            h.click(h.timelinePoint(0.5))
            XCTAssertEqual(h.calls, [])
            XCTAssertFalse(h.model.pinnedToOldest)
        }

        func testSelectionLongerThanWhatIsHeldIsClamped() {
            let h = harness("partial", selection: 3600, quick: nil)
            defer { h.close() }
            XCTAssertEqual(h.model.clampedSelection, h.model.state.timeline.held, accuracy: 0.5)
            h.click(control: "save")
            XCTAssertEqual(h.calls, ["save \(Int(h.model.state.timeline.held.rounded()))"])
        }

        func testAccessibilityStepsByAMinute() {
            let h = harness("recording", selection: 600, quick: nil)
            defer { h.close() }
            h.model.drag(to: h.model.clampedSelection + 60)
            XCTAssertEqual(h.model.clampedSelection, 660)
            h.model.drag(to: h.model.clampedSelection - 120)
            XCTAssertEqual(h.model.clampedSelection, 540)
            h.model.drag(to: h.model.state.timeline.held + 60)
            XCTAssertTrue(h.model.pinnedToOldest, "stepping past the oldest audio pins")
        }

        // MARK: Bookmarks

        func testBookmarkWithLabel() {
            let h = harness("recording")
            defer { h.close() }
            h.model.bookmark()
            h.pump()
            XCTAssertNotNil(h.model.pendingBookmark)
            XCTAssertTrue(h.has("labelField"))
            XCTAssertTrue(h.has("save"), "Save stays in the header while labelling")
            h.type("decision")
            h.pressReturn()
            XCTAssertEqual(h.calls, ["bookmark", "label decision"], "Return labels the bookmark and does not save")
            XCTAssertNil(h.model.pendingBookmark)
            XCTAssertFalse(h.has("labelField"), "the field closes")
        }

        func testBookmarkWithoutLabelThroughAdd() {
            let h = harness("recording")
            defer { h.close() }
            h.model.bookmark()
            h.pump()
            h.click(control: "add")
            XCTAssertEqual(h.calls, ["bookmark"], "an empty label is not stored")
            XCTAssertNil(h.model.pendingBookmark)
        }

        /// A point in the row under the tape at `fraction` of the width, clear of the meeting's name.
        private func underTape(_ h: PopoverHarness, _ fraction: CGFloat) -> CGPoint {
            CGPoint(x: h.timeline.minX + h.timeline.width * fraction, y: h.timeline.minY + TimelineView.tapeHeight + 4)
        }

        func testABookmarkFollowsThePointerUnderTheTape() {
            let h = harness("recording")
            defer { h.close() }
            h.hover(h.timelinePoint(0.4))
            XCTAssertFalse(h.has("bookmarkGhost"), "not over the tape itself")
            h.hover(underTape(h, 0.4))
            guard let ghost = h.model.controlFrames["bookmarkGhost"], ghost.width > 0 else {
                return XCTFail("no bookmark under the pointer")
            }
            XCTAssertEqual(ghost.minX + 3.5, underTape(h, 0.4).x, accuracy: 1.5, "the icon is centred on the pointer")
            h.hover(underTape(h, 0.6))
            XCTAssertEqual(h.model.controlFrames["bookmarkGhost"]!.minX + 3.5, underTape(h, 0.6).x, accuracy: 1.5)
        }

        func testClickingUnderTheTapeBookmarksThatMoment() {
            let h = harness("recording")
            defer { h.close() }
            let selection = h.model.selectedRange
            h.hover(underTape(h, 0.4))
            h.click(underTape(h, 0.4))
            let back = Int((0.6 * h.model.state.timeline.span).rounded())
            guard let call = h.calls.first, call.hasPrefix("bookmark "),
                let seconds = Int(call.split(separator: " ")[1].dropLast())
            else {
                return XCTFail("no bookmark: \(h.calls)")
            }
            XCTAssertEqual(Double(seconds), Double(back), accuracy: h.model.state.timeline.span / 150)
            XCTAssertNotNil(h.model.pendingBookmark, "the label field opens")
            XCTAssertEqual(h.model.selectedRange, selection, "a bookmark does not move the handles")
            h.type("idea")
            h.pressReturn()
            XCTAssertEqual(h.calls.last, "label idea")
        }

        func testBookmarkingOverAMeetingLineStillBookmarks() {
            let h = harness("recording")
            defer { h.close() }
            // The Zoom meeting spans 52 % to 86 %; its name sits at the left end of its line.
            h.click(
                CGPoint(x: h.timeline.minX + h.timeline.width * 0.75, y: h.timeline.minY + TimelineView.tapeHeight + 5))
            XCTAssertEqual(h.calls.count, 1)
            XCTAssertTrue(h.calls[0].hasPrefix("bookmark "))
            XCTAssertNil(h.model.selectedMeeting)
        }

        func testNoBookmarkBeforeTheOldestAudio() {
            let h = harness("partial", selection: 120, quick: nil)
            defer { h.close() }
            h.hover(underTape(h, 0.2))
            XCTAssertFalse(h.has("bookmarkGhost"), "nothing is held there")
            h.click(underTape(h, 0.2))
            XCTAssertEqual(h.calls, [])
        }

        func testBookmarkingThePastWorksWhilePaused() {
            let h = harness("paused")
            defer { h.close() }
            h.click(underTape(h, 0.5))
            XCTAssertEqual(h.calls.count, 1, "the audio at that moment exists")
        }

        func testEscapeClosesTheLabelField() {
            let h = harness("recording")
            defer { h.close() }
            h.model.bookmark()
            h.pump()
            h.type("x")
            h.pressEscape()
            XCTAssertNil(h.model.pendingBookmark)
        }

        func testBookmarkIsDisabledWhilePaused() {
            let h = harness("paused")
            defer { h.close() }
            XCTAssertFalse(h.model.canBookmark)
            h.model.bookmark()
            XCTAssertEqual(h.calls, [])
            XCTAssertNil(h.model.pendingBookmark)
        }

        // MARK: Tools and banners

        func testPausedStillSaves() {
            let h = harness("paused", selection: 600, quick: nil)
            defer { h.close() }
            XCTAssertTrue(h.has("more"), "pause, Library and Settings are in the more menu")
            h.click(control: "save")
            XCTAssertEqual(h.calls, ["save 600"])
        }

        func testMeetingBanner() {
            let h = harness("meeting")
            defer { h.close() }
            XCTAssertTrue(h.click(control: "saveMeeting"))
            XCTAssertEqual(h.calls, ["saveMeeting"])
        }

        func testPermissionBanner() {
            let h = harness("needs-permission")
            defer { h.close() }
            XCTAssertTrue(h.click(control: "fix"))
            XCTAssertTrue(h.click(control: "alternative"))
            XCTAssertEqual(h.calls, ["fix", "alternative"])
        }

        func testSavingShowsCancelAndBlocksSave() {
            let h = harness("saving", selection: 3600, quick: 60)
            defer { h.close() }
            XCTAssertFalse(h.has("save"))
            XCTAssertTrue(h.click(control: "cancel"))
            h.pressReturn()
            XCTAssertEqual(h.calls, ["cancel"], "Return does not start a second save")
        }

        func testDraggingWhileSavingStillMovesTheHandle() {
            let h = harness("saving", selection: 3600, quick: 60)
            defer { h.close() }
            h.drag(
                from: CGPoint(x: h.handleX, y: h.timeline.midY),
                to: CGPoint(x: h.timeline.minX - 40, y: h.timeline.midY))
            XCTAssertTrue(h.model.pinnedToOldest)
            XCTAssertEqual(h.calls, [])
        }
    }
#endif
