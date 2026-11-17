#if os(macOS)
    import AppKit
    import TapeloopCore
    import XCTest

    @testable import TapeloopUI

    /// User-level tests of the popover: real pointer and keyboard events on the real views.
    @MainActor
    final class TimelineDragTests: XCTestCase {
        private func state(_ name: String) -> PopoverState {
            Samples.popoverStates().first { $0.name == name }!.state
        }

        private func harness(_ name: String, selection: TimeInterval = 36 * 60, quick: Int? = nil) -> PopoverHarness {
            PopoverHarness(state: state(name), selection: selection, quick: quick)
        }

        // MARK: Dragging the handle

        func testHarnessFindsTheTimelineAndControls() {
            let h = harness("recording")
            defer { h.close() }
            XCTAssertGreaterThan(h.timeline.width, 300, "\(h.timeline)")
            for name in ["chip-5", "chip-15", "chip-30", "chip-60", "save", "pause", "bookmark", "library", "settings"]
            {
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
            let h = harness("just-started", selection: 120, quick: nil)
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
            let h = harness("just-started", selection: 60, quick: nil)
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

        // MARK: Quick spans

        func testChipsSelectAndHighlight() {
            let h = harness("recording")
            defer { h.close() }
            for minutes in [5, 15, 30, 60] {
                XCTAssertTrue(h.click(control: "chip-\(minutes)"))
                XCTAssertEqual(h.model.quickMinutes, minutes)
                XCTAssertEqual(h.model.clampedSelection, Double(minutes) * 60)
                XCTAssertFalse(h.model.pinnedToOldest)
            }
        }

        func testChipAfterPinningUnpins() {
            let h = harness("recording")
            defer { h.close() }
            h.drag(
                from: CGPoint(x: h.handleX, y: h.timeline.midY),
                to: CGPoint(x: h.timeline.minX - 50, y: h.timeline.midY))
            h.click(control: "chip-15")
            XCTAssertFalse(h.model.pinnedToOldest)
            XCTAssertEqual(h.model.clampedSelection, 900)
        }

        func testDraggingClearsTheChip() {
            let h = harness("recording", selection: 300, quick: 5)
            defer { h.close() }
            h.drag(from: CGPoint(x: h.handleX, y: h.timeline.midY), to: h.timelinePoint(0.6))
            XCTAssertNil(h.model.quickMinutes)
        }

        func testChipsLongerThanTheTapeAreDisabled() {
            let h = harness("just-started", selection: 120, quick: nil)
            defer { h.close() }
            h.click(control: "chip-15")
            XCTAssertNotEqual(h.model.quickMinutes, 15, "15 min is disabled with 4 min held")
            h.click(control: "chip-60")
            XCTAssertNotEqual(h.model.quickMinutes, 60)
            h.click(control: "chip-5")
            XCTAssertEqual(h.model.quickMinutes, 5, "5 min stays enabled")
            XCTAssertEqual(
                h.model.clampedSelection, h.model.state.timeline.held, accuracy: 0.5, "and saves what exists")
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
            h.click(control: "chip-5")
            h.click(h.timelinePoint(0.5))
            XCTAssertEqual(h.calls, [])
            XCTAssertFalse(h.model.pinnedToOldest)
        }

        func testSelectionLongerThanWhatIsHeldIsClamped() {
            let h = harness("just-started", selection: 3600, quick: nil)
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
            XCTAssertTrue(h.click(control: "bookmark"))
            XCTAssertNotNil(h.model.pendingBookmark)
            XCTAssertTrue(h.has("labelField"))
            XCTAssertFalse(h.has("save"), "the label field replaces the chips")
            h.type("decision")
            h.pressReturn()
            XCTAssertEqual(h.calls, ["bookmark", "label decision"], "Return labels the bookmark and does not save")
            XCTAssertNil(h.model.pendingBookmark)
            XCTAssertTrue(h.has("save"), "the chips come back")
        }

        func testBookmarkWithoutLabelThroughAdd() {
            let h = harness("recording")
            defer { h.close() }
            h.click(control: "bookmark")
            h.click(control: "add")
            XCTAssertEqual(h.calls, ["bookmark"], "an empty label is not stored")
            XCTAssertNil(h.model.pendingBookmark)
        }

        func testEscapeClosesTheLabelField() {
            let h = harness("recording")
            defer { h.close() }
            h.click(control: "bookmark")
            h.type("x")
            h.pressEscape()
            XCTAssertNil(h.model.pendingBookmark)
        }

        func testBookmarkIsDisabledWhilePaused() {
            let h = harness("paused")
            defer { h.close() }
            h.click(control: "bookmark")
            XCTAssertEqual(h.calls, [])
            XCTAssertNil(h.model.pendingBookmark)
        }

        // MARK: Tools and banners

        func testToolButtons() {
            let h = harness("recording")
            defer { h.close() }
            h.click(control: "pause")
            h.click(control: "library")
            h.click(control: "settings")
            XCTAssertEqual(h.calls, ["pause", "library", "settings"])
        }

        func testPausedShowsResumeAndStillSaves() {
            let h = harness("paused", selection: 600, quick: nil)
            defer { h.close() }
            h.click(control: "pause")
            h.click(control: "save")
            XCTAssertEqual(h.calls, ["pause", "save 600"])
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
