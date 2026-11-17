#if os(macOS)
    import AppKit
    import SwiftUI
    import TapeloopCore
    import XCTest

    @testable import TapeloopUI

    /// Hosts the real popover view in an off-screen window and drives it with real mouse and keyboard events, so tests
    /// go through SwiftUI's gestures, buttons and focus exactly as a user does.
    @MainActor
    final class PopoverHarness {
        let model: PopoverModel
        let window: NSWindow
        let host: NSHostingView<PopoverView>
        /// What the buttons did, in order.
        private(set) var calls: [String] = []
        private var eventNumber = 0

        init(state: PopoverState, selection: TimeInterval = 300, quick: Int? = 5) {
            _ = NSApplication.shared
            model = PopoverModel(state: state, selection: selection)
            model.quickMinutes = quick
            host = NSHostingView(rootView: PopoverView(model: model))
            let size = host.fittingSize
            window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            window.makeKey()
            var actions = PopoverActions()
            actions.save = { [unowned self] in self.calls.append("save \(Int($0.rounded()))") }
            actions.cancelSave = { [unowned self] in self.calls.append("cancel") }
            actions.togglePause = { [unowned self] in self.calls.append("pause") }
            actions.bookmark = { [unowned self] in
                self.calls.append("bookmark")
                return Samples.now
            }
            actions.labelBookmark = { [unowned self] _, label in self.calls.append("label \(label)") }
            actions.saveMeeting = { [unowned self] _ in self.calls.append("saveMeeting") }
            actions.fixProblem = { [unowned self] in self.calls.append("fix") }
            actions.problemAlternative = { [unowned self] in self.calls.append("alternative") }
            actions.openLibrary = { [unowned self] in self.calls.append("library") }
            actions.openSettings = { [unowned self] in self.calls.append("settings") }
            model.actions = actions
            pump()
        }

        func close() {
            window.orderOut(nil)
        }

        /// Lets SwiftUI process pending updates.
        func pump(_ seconds: TimeInterval = 0.05) {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            host.layoutSubtreeIfNeeded()
        }

        var timeline: CGRect { model.timelineFrame }

        // MARK: Pointer

        private func send(_ type: NSEvent.EventType, at point: CGPoint) {
            eventNumber += 1
            let location = host.convert(point, to: nil)
            let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1)!
            window.sendEvent(event)
            pump(0.01)
        }

        /// Presses at `from`, drags through `steps` points to `to` (which may lie outside the view), and releases.
        func drag(from: CGPoint, to: CGPoint, steps: Int = 12) {
            send(.leftMouseDown, at: from)
            for index in 1...steps {
                let t = CGFloat(index) / CGFloat(steps)
                send(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            }
            send(.leftMouseUp, at: to)
            pump()
        }

        func click(_ point: CGPoint) {
            send(.leftMouseDown, at: point)
            send(.leftMouseUp, at: point)
            pump()
        }

        /// Clicks the centre of the control reported as `name`; returns false when it is not on screen.
        @discardableResult
        func click(control name: String) -> Bool {
            guard let frame = model.controlFrames[name], frame.width > 0 else { return false }
            click(CGPoint(x: frame.midX, y: frame.midY))
            return true
        }

        func has(_ name: String) -> Bool { (model.controlFrames[name]?.width ?? 0) > 0 }

        /// Moves time forward: the axis slides, the oldest audio stays (so more is held), like the app's timer.
        func advance(_ seconds: TimeInterval) {
            var state = model.state
            state.timeline.end = state.timeline.end.addingTimeInterval(seconds)
            state.timeline.start = state.timeline.start.addingTimeInterval(seconds)
            model.state = state
            pump()
        }

        /// A point on the timeline at `fraction` of its width (0 = left edge), at mid height.
        func timelinePoint(_ fraction: CGFloat) -> CGPoint {
            CGPoint(x: timeline.minX + timeline.width * fraction, y: timeline.midY)
        }

        /// Where the handle is (x of the selection line), from the model.
        var handleX: CGFloat {
            let data = model.state.timeline
            return timeline.minX + timeline.width * CGFloat(1 - model.clampedSelection / data.span)
        }

        // MARK: Keyboard

        func type(_ text: String) {
            for character in text { key(String(character), keyCode: 0) }
        }

        func key(_ characters: String, keyCode: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
                window.sendEvent(event)
            }
            pump()
        }

        func pressReturn() { key("\r", keyCode: 36) }
        func pressEscape() { key("\u{1b}", keyCode: 53) }

        // MARK: Accessibility (buttons by their label)

        /// Every accessibility element under the popover.
        func elements() -> [NSAccessibilityProtocol] {
            var result: [NSAccessibilityProtocol] = []
            func walk(_ element: Any) {
                guard let element = element as? NSAccessibilityProtocol else { return }
                result.append(element)
                for child in element.accessibilityChildren() ?? [] { walk(child) }
            }
            for child in host.accessibilityChildren() ?? [] { walk(child) }
            return result
        }

        func label(of element: NSAccessibilityProtocol) -> String {
            [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        }

        /// The button whose label contains `text`.
        func button(_ text: String) -> NSAccessibilityProtocol? {
            elements().first { $0.accessibilityRole() == .button && label(of: $0).contains(text) }
        }

        /// Presses the button labelled `text`; returns false when there is none or it is disabled.
        @discardableResult
        func press(_ text: String) -> Bool {
            guard let button = button(text), button.isAccessibilityEnabled() else { return false }
            _ = button.accessibilityPerformPress()
            pump()
            return true
        }

        func isEnabled(_ text: String) -> Bool? { button(text)?.isAccessibilityEnabled() }

        /// All visible button labels (for diagnostics).
        var buttonLabels: [String] {
            elements().filter { $0.accessibilityRole() == .button }.map { label(of: $0) }
        }
    }
#endif
