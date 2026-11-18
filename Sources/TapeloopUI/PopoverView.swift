#if os(macOS)
    import AppKit
    import SwiftUI
    import TapeloopCore

    /// The menu bar popover, kept minimal: a header line (status, length, Save, a "more" menu) and one mirrored tape
    /// (your voice above the centre line, your Mac's sound below) across the full width, which shows the audio held.
    /// The selected length sits beside the handle's play button, which previews the span without saving it. Bookmarks
    /// and meetings sit under the tape.
    ///
    /// Colour has jobs: red is live (recording, the preview playhead and what has played), amber is what you act on
    /// (the handle and Save), and the rest is grey.
    public struct PopoverView: View {
        @Bindable var model: PopoverModel
        @FocusState private var labelFocused: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        /// Off for still images (snapshots), which would otherwise catch the recording dot mid-blink.
        nonisolated(unsafe) public static var animates = true
        @State private var dotDim = false

        /// Creates the popover content.
        public init(model: PopoverModel) {
            self.model = model
        }

        private var state: PopoverState { model.state }

        public var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let subtitle = state.subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                if let banner = state.banner { bannerView(banner).padding(.top, 10) }
                if state.timeline.held > 0 || state.status != .needsAttention {
                    TimelineView(model: model).padding(.top, 26)
                }
                if let saving = state.saving {
                    savingView(saving).padding(.top, 10)
                } else if model.pendingBookmark != nil {
                    bookmarkField.padding(.top, 10)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            .frame(width: 380)
        }

        // MARK: Header

        private var header: some View {
            HStack(spacing: 7) {
                statusDot
                Text(state.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let stat = state.stat {
                    Text("· \(stat)").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.secondary)
                        .help("How much audio Tapeloop is keeping")
                }
                Spacer(minLength: 8)
                if state.saving == nil {
                    Button("Save") { model.actions.save(model.selectedRange) }
                        .buttonStyle(.tapePrimary)
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                        .disabled(state.timeline.held <= 0)
                        .help("Save the selected \(DurationText.long(model.selectedRange.duration)) as an audio file")
                        .reportFrame("save", to: model)
                }
                moreMenu
            }
        }

        @ViewBuilder private var statusDot: some View {
            switch state.status {
            case .recording:
                // Blinks slowly while recording (steady when Reduce Motion is on).
                Circle().fill(Tape.red).frame(width: 8, height: 8)
                    .background(Circle().fill(Tape.red.opacity(0.18)).frame(width: 14, height: 14))
                    .opacity(dotDim ? 0.25 : 1)
                    .onAppear {
                        guard !reduceMotion, Self.animates else { return }
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dotDim = true }
                    }
                    .onDisappear { dotDim = false }
            case .paused: Circle().fill(Tape.grey).frame(width: 8, height: 8)
            case .needsAttention: Circle().strokeBorder(Tape.red, lineWidth: 2).frame(width: 9, height: 9)
            }
        }

        /// Everything that is not the tape or Save: pause, bookmark, quick spans, Library and Settings. A plain button
        /// that opens a native menu (a SwiftUI `Menu` cannot be drawn into the snapshot images).
        private var moreMenu: some View {
            Button {
                showMoreMenu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ToolButtonStyle())
            .foregroundStyle(.secondary)
            .help("More: pause, bookmark, quick spans, Library, Settings")
            .accessibilityLabel("More")
            .reportFrame("more", to: model)
        }

        private func showMoreMenu() {
            var items: [PopupMenu.Item] = [
                .init(state.isPaused ? "Resume Recording" : "Pause Recording") { model.actions.togglePause() },
                .init("Bookmark This Moment", enabled: model.canBookmark) { model.bookmark() },
                .separator,
            ]
            for minutes in PopoverModel.quickSpans {
                items.append(
                    .init(
                        minutes < 60 ? "Select the Last \(minutes) Minutes" : "Select the Last Hour",
                        enabled: model.quickSpanAvailable(minutes)
                    ) {
                        model.choose(minutes: minutes)
                    })
            }
            items += [
                .separator,
                .init("Library…") { model.actions.openLibrary() },
                .init("Settings…") { model.actions.openSettings() },
            ]
            PopupMenu.show(items)
        }

        // MARK: Banner

        @ViewBuilder private func bannerView(_ banner: PopoverState.Banner) -> some View {
            switch banner {
            case .meeting(let id, let title, let detail, let calendarTitle):
                HStack(spacing: 10) {
                    Image(systemName: "video").foregroundStyle(Tape.meeting)
                    VStack(alignment: .leading, spacing: 1) {
                        (Text(title).bold() + Text(" · \(detail)")).font(.system(size: 12))
                        if let calendarTitle {
                            Text(calendarTitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    Button("Save meeting") { model.actions.saveMeeting(id) }.buttonStyle(.tape)
                        .reportFrame("saveMeeting", to: model)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Tape.radius).fill(Tape.meeting.opacity(0.14)))
            case .problem(let message, let fix, let alternative):
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Tape.red)
                        Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Tape.radius).fill(Tape.red.opacity(0.12)))
                    if fix != nil || alternative != nil {
                        HStack(spacing: 6) {
                            if let fix {
                                Button(fix) { model.actions.fixProblem() }.buttonStyle(.tapePrimary)
                                    .reportFrame("fix", to: model)
                            }
                            if let alternative {
                                Button(alternative) { model.actions.problemAlternative() }.buttonStyle(.tape)
                                    .reportFrame("alternative", to: model)
                            }
                        }
                    }
                }
            case .info(let text):
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
        }

        // MARK: Below the tape (only while saving or labelling a bookmark)

        /// A save in progress: what is being saved, a thin progress bar, and Cancel.
        private func savingView(_ saving: PopoverState.Saving) -> some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(saving.label).font(.system(size: 12))
                        Spacer()
                        Text("\(Int((saving.progress * 100).rounded())) %").font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.12))
                            Capsule().fill(Color.primary.opacity(0.75))
                                .frame(width: proxy.size.width * min(1, max(0, saving.progress)))
                        }
                    }
                    .frame(height: 3)
                }
                Button("Cancel") { model.actions.cancelSave() }.buttonStyle(.tape).reportFrame("cancel", to: model)
            }
        }

        private var bookmarkField: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("Label (optional)", text: $model.bookmarkLabel)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Tape.radius).fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Tape.radius)
                                .strokeBorder(labelFocused ? Tape.amber : Tape.line, lineWidth: labelFocused ? 2 : 1)
                        )
                        .focused($labelFocused)
                        .onSubmit { model.commitBookmark() }
                        .onExitCommand { model.commitBookmark() }
                        .reportFrame("labelField", to: model)
                    Button("Add") { model.commitBookmark() }.buttonStyle(.tapePrimary).reportFrame("add", to: model)
                }
                if let date = model.pendingBookmark {
                    Text(
                        "Bookmarked at \(date.formatted(date: .omitted, time: .shortened)). A label is optional; press Return to add it."
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { labelFocused = true }
        }

    }

    /// The rewind tape: one mirrored waveform, the handle with its play button, the preview playhead, and the
    /// bookmarks and meetings beneath it.
    struct TimelineView: View {
        @Bindable var model: PopoverModel
        /// The waveform's height; the marker row for bookmarks and meetings sits below it.
        static let tapeHeight: CGFloat = 52
        static let markerHeight: CGFloat = 24
        static let height: CGFloat = tapeHeight + markerHeight
        /// Bars: one hairline every `pitch` points.
        private let pitch: CGFloat = 3
        private let barWidth: CGFloat = 1

        @State private var knobDrag: (start: CGFloat, moved: Bool)?
        @State private var draggingEnd = false
        /// How near the right end (in points) the pointer brings out the end handle.
        static let endReveal: CGFloat = 36

        private var data: TimelineData { model.state.timeline }

        var body: some View {
            GeometryReader { proxy in
                let width = proxy.size.width
                let range = model.selectedRange
                let selectionX = xOf(range.start, width: width)
                let endX = min(width, xOf(range.end, width: width))
                let preview = model.state.preview
                let playX = preview.map { selectionX + (endX - selectionX) * CGFloat($0.fraction) }
                let hover = model.timelineHover
                let showEnd =
                    !model.endsNow || draggingEnd
                    || (hover.map { $0.x > width - Self.endReveal && $0.y < Self.tapeHeight } ?? false)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        draw(in: &context, size: size, selectionX: selectionX, endX: endX, playX: playX)
                    }
                    bookmarkRow(width: width)
                    meetingTargets(width: width)
                    if let ghostX = ghostBookmarkX(width: width) {
                        ghostBookmark(at: ghostX, width: width)
                    }
                    if data.held > 0 {
                        // The grab area stays inside the tape (clicks past its edge are lost); the drawing sits on the end.
                        let grabX = min(endX - 10, width - 20)
                        endHandle(visible: showEnd, shift: endX - 10 - grabX)
                            .offset(x: grabX)
                            .gesture(endGesture(width: width))
                        if let playX {
                            Rectangle().fill(Tape.red).frame(width: 1.5, height: Self.tapeHeight).offset(
                                x: playX - 0.75
                            )
                            .allowsHitTesting(false)
                        }
                        Rectangle().fill(Tape.amber).frame(width: 2.5, height: Self.tapeHeight)
                            .offset(x: selectionX - 1.25)
                            .allowsHitTesting(false)
                        handleLabel(knobX: selectionX, width: width)
                        knob(playing: preview != nil)
                            .offset(x: selectionX - 10, y: -10)
                            .gesture(knobGesture(selectionX: selectionX, width: width))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): model.timelineHover = point
                    case .ended: model.timelineHover = nil
                    }
                }
                .help(
                    "Top: your voice. Bottom: your Mac's sound. Drag to choose where to start; hover over the right end to move the end; click under the tape to bookmark a moment."
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let target = secondsBack(atX: value.location.x, width: width)
                            model.drag(to: target.seconds, pin: target.pinned)
                        }
                        .onEnded { _ in model.selectionSettled() }
                )
            }
            .frame(height: Self.height)
            .coordinateSpace(.named("tape"))
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { model.timelineFrame = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in model.timelineFrame = frame }
                }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rewind timeline")
            .accessibilityValue("Saving \(DurationText.long(model.selectedRange.duration))")
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = 60
                switch direction {
                case .increment:
                    model.drag(to: model.clampedSelection + step)
                    model.selectionSettled()
                case .decrement:
                    model.drag(to: model.clampedSelection - step)
                    model.selectionSettled()
                default: break
                }
            }
            .accessibilityAction(named: "Preview") { model.togglePreview() }
        }

        /// The end of the selection: a slim grip on a line. Hidden while the selection ends now, until the pointer comes
        /// near the right end; always shown once the end has been moved in.
        private func endHandle(visible: Bool, shift: CGFloat) -> some View {
            // Only the drawing fades: the grab area is always there, so a drag that starts as the handle appears works.
            ZStack {
                Rectangle().fill(Tape.amber).frame(width: 2.5, height: Self.tapeHeight)
                Capsule().fill(Tape.amber)
                    .frame(width: 7, height: 20)
                    .overlay(Capsule().fill(Tape.onAmber.opacity(0.5)).frame(width: 1.5, height: 9))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
            }
            .offset(x: shift)
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: visible)
            .frame(width: 20, height: Self.tapeHeight)
            .contentShape(Rectangle())
            .help("Drag to choose where the saved span ends; back to the right edge to end now")
            .reportFrame("endHandle", to: model)
        }

        private func endGesture(width: CGFloat) -> some Gesture {
            DragGesture(minimumDistance: 0, coordinateSpace: .named("tape"))
                .onChanged { value in
                    draggingEnd = true
                    let date = date(atX: value.location.x, width: width)
                    // Within a few points of the right edge counts as now.
                    let slack = Double(Self.pinSlop / max(1, width)) * data.span
                    model.dragEnd(to: date, slack: slack)
                }
                .onEnded { _ in
                    draggingEnd = false
                    model.selectionSettled()
                }
        }

        /// Invisible click targets over each meeting's name (or its line, for a meeting without one): a click selects
        /// exactly that meeting. The rest of the row under the tape places bookmarks.
        private func meetingTargets(width: CGFloat) -> some View {
            ForEach(Array(data.meetings.enumerated()), id: \.offset) { index, meeting in
                if let rect = meetingTarget(meeting, width: width) {
                    Rectangle().fill(Color.clear)
                        .frame(width: rect.width, height: rect.height)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectMeeting(meeting) }
                        .help("Select only \(meeting.label.map { "the \($0) meeting" } ?? "this meeting")")
                        .reportFrame("meeting-\(index)", to: model)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }

        static let labelFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        private static var markerTop: CGFloat { tapeHeight + 4 }

        /// Where a meeting's name is drawn.
        private func labelRect(_ meeting: TimelineData.Span, width: CGFloat) -> CGRect? {
            guard let label = meeting.label else { return nil }
            let x0 = max(0, xOf(meeting.start, width: width))
            guard min(width, xOf(meeting.end, width: width)) > x0 else { return nil }
            let size = (label as NSString).size(withAttributes: [.font: Self.labelFont])
            let left = min(x0, max(0, width - size.width))
            return CGRect(x: left, y: Self.markerTop + 8, width: ceil(size.width), height: ceil(size.height))
        }

        /// The click target that selects a meeting: its name, padded a little, or its line when it has no name.
        private func meetingTarget(_ meeting: TimelineData.Span, width: CGFloat) -> CGRect? {
            if let rect = labelRect(meeting, width: width) { return rect.insetBy(dx: -3, dy: -2) }
            let x0 = max(0, xOf(meeting.start, width: width))
            let x1 = min(width, xOf(meeting.end, width: width))
            guard x1 > x0 else { return nil }
            return CGRect(x: x0, y: Self.markerTop - 4, width: x1 - x0, height: 10)
        }

        /// The row under the tape: a click places a bookmark at that moment.
        private func bookmarkRow(width: CGFloat) -> some View {
            Rectangle().fill(Color.clear)
                .frame(width: width, height: Self.markerHeight)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    // The bookmark goes where the following icon shows it; without hover (keyboard, tests), at the click.
                    if model.timelineHover != nil {
                        guard let x = ghostBookmarkX(width: width) else { return }
                        model.bookmark(at: date(atX: x, width: width))
                    } else {
                        model.bookmark(at: date(atX: location.x, width: width))
                    }
                }
                .reportFrame("bookmarkRow", to: model)
                .offset(y: Self.tapeHeight)
        }

        /// Where the bookmark that follows the pointer is, if the pointer is in the row under the tape, over audio
        /// that is held, and not over a meeting's name.
        private func ghostBookmarkX(width: CGFloat) -> CGFloat? {
            guard let hover = model.timelineHover, hover.y >= Self.tapeHeight, hover.y <= Self.height, data.held > 0,
                model.pendingBookmark == nil
            else { return nil }
            let oldest = xOf(data.heldStart ?? data.start, width: width)
            guard hover.x >= oldest - 2, hover.x <= width + 1 else { return nil }
            if data.meetings.contains(where: { meetingTarget($0, width: width)?.contains(hover) ?? false }) {
                return nil
            }
            return min(max(hover.x, oldest), width)
        }

        /// The bookmark a click would place, with its time.
        private func ghostBookmark(at x: CGFloat, width: CGFloat) -> some View {
            let time = date(atX: x, width: width).formatted(date: .omitted, time: .shortened)
            let textWidth = (time as NSString).size(withAttributes: [.font: Self.labelFont]).width
            let flip = x + 6 + textWidth > width
            let icon = Image(systemName: "bookmark.fill").resizable().frame(width: 7, height: 9)
                .foregroundStyle(Tape.amber)
            return HStack(spacing: 3) {
                if flip { Text(time).font(Font(Self.labelFont)).foregroundStyle(Tape.amber) }
                icon
                if !flip { Text(time).font(Font(Self.labelFont)).foregroundStyle(Tape.amber) }
            }
            .fixedSize()
            .allowsHitTesting(false)
            .reportFrame("bookmarkGhost", to: model)
            // The icon's centre is on the pointer.
            .offset(x: flip ? x - ceil(textWidth) - 3 - 3.5 : x - 3.5, y: Self.tapeHeight + 1)
        }

        private func date(atX x: CGFloat, width: CGFloat) -> Date {
            data.start.addingTimeInterval(Double(min(max(0, x), width) / max(1, width)) * data.span)
        }

        /// Beside the play button: the selected length ("36 min"), the meeting it is ("Zoom · 10:41 · 40 min"), the times
        /// of a trimmed span, or, while previewing, the position ("11:31 / 36:00" in red). On the right of the button,
        /// or on its left when there is no room.
        private func handleLabel(knobX: CGFloat, width: CGFloat) -> some View {
            let (text, plain) = handleText
            let measured = (plain as NSString).size(withAttributes: [.font: Self.handleFont]).width
            let flip = knobX + 16 + measured > width
            return text.font(Font(Self.handleFont).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .allowsHitTesting(false)
                .reportFrame("handleLabel", to: model)
                .offset(x: flip ? knobX - 16 - ceil(measured) : knobX + 16, y: -7)
        }

        static let handleFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

        /// The label as styled text, and as plain text for measuring.
        private var handleText: (Text, String) {
            if let preview = model.state.preview {
                let plain = "\(DurationText.clock(preview.elapsed)) / \(DurationText.clock(preview.duration))"
                return (Text(plain).foregroundStyle(Tape.red), plain)
            }
            let range = model.selectedRange
            let length = DurationText.short(range.duration)
            if let meeting = model.selectedMeeting {
                let name = meeting.label ?? "Meeting"
                return (
                    Text(name).foregroundStyle(Tape.meeting) + Text(" · \(length)").foregroundStyle(.primary),
                    "\(name) · \(length)"
                )
            }
            if model.endsNow { return (Text(length).foregroundStyle(.primary), length) }
            let times =
                "\(range.start.formatted(date: .omitted, time: .shortened))–\(range.end.formatted(date: .omitted, time: .shortened))"
            return (
                Text(times + " · ").foregroundStyle(.secondary) + Text(length).foregroundStyle(.primary),
                "\(times) · \(length)"
            )
        }

        /// The handle's top: a round button that plays (or stops) the preview. Dragging it moves the handle.
        private func knob(playing: Bool) -> some View {
            Circle().fill(Tape.amber)
                .frame(width: 20, height: 20)
                .overlay(
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Tape.onAmber)
                        .offset(x: playing ? 0 : 0.8)
                )
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .contentShape(Circle().inset(by: -4))
                .help(playing ? "Stop the preview" : "Play from here, without saving; drag to move")
                .reportFrame("knob", to: model)
        }

        /// A click on the knob toggles the preview; a drag of more than a few points moves the handle instead.
        private func knobGesture(selectionX: CGFloat, width: CGFloat) -> some Gesture {
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if knobDrag == nil { knobDrag = (selectionX, false) }
                    guard let drag = knobDrag else { return }
                    if drag.moved || abs(value.translation.width) > 3 {
                        knobDrag = (drag.start, true)
                        let target = secondsBack(atX: drag.start + value.translation.width, width: width)
                        model.drag(to: target.seconds, pin: target.pinned)
                    }
                }
                .onEnded { _ in
                    if knobDrag?.moved == false {
                        model.togglePreview()
                    } else {
                        model.selectionSettled()
                    }
                    knobDrag = nil
                }
        }

        private func x(forSecondsBack seconds: TimeInterval, width: CGFloat) -> CGFloat {
            width * CGFloat(1 - seconds / data.span)
        }

        /// The selection for a pointer at `x`. At or left of the oldest audio (within a few points, so a fast drag
        /// to the edge lands there), the selection pins to everything held.
        func secondsBack(atX x: CGFloat, width: CGFloat) -> (seconds: TimeInterval, pinned: Bool) {
            let fraction = min(1, max(0, Double(x / max(1, width))))
            let seconds = (1 - fraction) * data.span
            let oldestX = self.x(forSecondsBack: data.held, width: width)
            if x <= oldestX + Self.pinSlop || seconds >= data.held { return (data.held, true) }
            return (max(PopoverModel.minimumSelection, seconds), false)
        }

        /// How close (in points) to the oldest audio counts as reaching it.
        static let pinSlop: CGFloat = 4

        private func xOf(_ date: Date, width: CGFloat) -> CGFloat {
            width * CGFloat(date.timeIntervalSince(data.start) / data.span)
        }

        /// The loudest level in the bins under `[x0, x1)`; -1 when there is no audio there.
        private func level(_ levels: [Float], from x0: CGFloat, to x1: CGFloat, width: CGFloat) -> Float {
            guard !levels.isEmpty else { return -1 }
            let count = levels.count
            let i0 = max(0, min(count - 1, Int(x0 / width * CGFloat(count))))
            let i1 = max(i0 + 1, min(count, Int(x1 / width * CGFloat(count))))
            var peak: Float = -1
            for index in i0..<i1 { peak = max(peak, levels[index]) }
            return peak
        }

        private func draw(
            in context: inout GraphicsContext, size: CGSize, selectionX: CGFloat, endX: CGFloat, playX: CGFloat?
        ) {
            let width = size.width
            let mid = Self.tapeHeight / 2
            let reach = mid - 2
            let rest = Color.primary.opacity(0.26)
            let kept = Color.primary.opacity(0.85)

            // The centre line.
            context.fill(
                Path(CGRect(x: 0, y: mid, width: width, height: 0.5)), with: .color(Color.primary.opacity(0.12)))

            // The waveform: your voice rises above the line, your Mac's sound hangs below it.
            let voice = data.lanes.first?.levels ?? []
            let mac = data.lanes.count > 1 ? data.lanes[1].levels : []
            var restPath = Path()
            var keptPath = Path()
            var playedPath = Path()
            var x: CGFloat = 0
            while x < width {
                let up = level(voice, from: x, to: x + pitch, width: width)
                let down = level(mac, from: x, to: x + pitch, width: width)
                if up >= 0 || down >= 0 {
                    var bar = Path()
                    let upHeight = max(0.8, CGFloat(Self.visual(max(0, up))) * reach)
                    let downHeight = max(0.8, CGFloat(Self.visual(max(0, down))) * reach * 0.9)
                    bar.addRect(CGRect(x: x, y: mid - 1 - upHeight, width: barWidth, height: upHeight))
                    bar.addRect(CGRect(x: x, y: mid + 1.5, width: barWidth, height: downHeight))
                    if let playX, x >= selectionX, x <= playX {
                        playedPath.addPath(bar)
                    } else if x >= selectionX, x <= endX {
                        keptPath.addPath(bar)
                    } else {
                        restPath.addPath(bar)
                    }
                }
                x += pitch
            }
            context.fill(restPath, with: .color(rest))
            context.fill(keptPath, with: .color(kept))
            context.fill(playedPath, with: .color(Tape.red))

            // Under the tape: meetings (a line with the meeting's name beneath it) and bookmarks (bookmark icons).
            let markerTop = Self.tapeHeight + 4
            for meeting in data.meetings {
                let x0 = max(0, xOf(meeting.start, width: width))
                let x1 = min(width, xOf(meeting.end, width: width))
                guard x1 > x0 else { continue }
                context.fill(
                    Path(roundedRect: CGRect(x: x0, y: markerTop, width: x1 - x0, height: 2), cornerRadius: 1),
                    with: .color(Tape.meeting.opacity(0.85)))
                if let label = meeting.label, let rect = labelRect(meeting, width: width) {
                    var text = context.resolve(Text(label).font(Font(Self.labelFont)))
                    text.shading = .color(Tape.meeting)
                    context.draw(text, at: rect.origin, anchor: .topLeading)
                }
            }
            var mark = context.resolve(Image(systemName: "bookmark.fill"))
            mark.shading = .color(Color.primary.opacity(0.6))
            for bookmark in data.bookmarks {
                let bx = xOf(bookmark.date, width: width)
                guard bx >= 0, bx <= width else { continue }
                context.draw(mark, in: CGRect(x: bx - 3.5, y: Self.tapeHeight + 1, width: 7, height: 9))
            }
        }

        /// Maps a linear peak (0 to 1) to a bar height fraction on a 50 dB scale, so speech is visible.
        static func visual(_ level: Float) -> Float {
            guard level > 0 else { return 0 }
            let db = 20 * log10(level)
            return min(1, max(0.06, (db + 50) / 50))
        }
    }

    /// A native menu shown at the pointer, built from closures.
    @MainActor
    enum PopupMenu {
        struct Item {
            var title: String
            var enabled = true
            var action: (() -> Void)?

            init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
                self.title = title
                self.enabled = enabled
                self.action = action
            }

            private init() {
                title = ""
                action = nil
            }

            static var separator: Item { Item() }
        }

        static func show(_ items: [Item]) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                guard let action = item.action else {
                    menu.addItem(.separator())
                    continue
                }
                let target = MenuTarget(action)
                let entry = NSMenuItem(title: item.title, action: #selector(MenuTarget.fire), keyEquivalent: "")
                entry.target = target
                entry.representedObject = target  // the item's target is weak; this keeps it alive
                entry.isEnabled = item.enabled
                menu.addItem(entry)
            }
            guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    final class MenuTarget: NSObject {
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }

    extension View {
        /// Records where this control is drawn into `model.controlFrames[name]` (UI tests aim pointer events there).
        func reportFrame(_ name: String, to model: PopoverModel) -> some View {
            background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { model.controlFrames[name] = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in model.controlFrames[name] = frame }
                        .onDisappear { model.controlFrames[name] = nil }
                })
        }
    }
#endif
