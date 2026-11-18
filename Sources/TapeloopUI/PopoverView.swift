#if os(macOS)
    import AppKit
    import SwiftUI
    import TapeloopCore

    /// The menu bar popover, kept minimal: a header line (status, length, a "more" menu), one mirrored tape (your voice
    /// above the centre line, your Mac's sound below), and the span with Save. Bookmarks and meetings sit under the
    /// tape. Clicking the handle's play button previews the span without saving it.
    ///
    /// Colour has jobs: red is live (recording, the preview playhead and what has played), amber is what you act on
    /// (the handle and Save), and the rest is grey.
    public struct PopoverView: View {
        @Bindable var model: PopoverModel
        @FocusState private var labelFocused: Bool

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
                    TimelineView(model: model).padding(.top, 22)
                }
                Group {
                    if let saving = state.saving {
                        savingView(saving)
                    } else if model.pendingBookmark != nil {
                        bookmarkField
                    } else {
                        footer
                    }
                }
                .padding(.top, 8)
            }
            .padding(14)
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
                moreMenu
            }
        }

        @ViewBuilder private var statusDot: some View {
            switch state.status {
            case .recording:
                Circle().fill(Tape.red).frame(width: 8, height: 8)
                    .background(Circle().fill(Tape.red.opacity(0.18)).frame(width: 14, height: 14))
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

        // MARK: Footer

        /// The span a save would keep (or the preview's progress) and Save.
        private var footer: some View {
            HStack(spacing: 8) {
                if let preview = state.preview {
                    (Text("▶ Preview").foregroundStyle(Tape.red).fontWeight(.semibold)
                        + Text("  \(DurationText.clock(preview.elapsed)) of \(DurationText.clock(preview.duration))")
                        .foregroundStyle(.secondary))
                        .font(.system(size: 12).monospacedDigit())
                } else {
                    (Text("Last ").foregroundStyle(.secondary)
                        + Text(DurationText.short(model.clampedSelection)).fontWeight(.semibold))
                        .font(.system(size: 12.5).monospacedDigit())
                }
                Spacer(minLength: 6)
                Button("Save") { model.actions.save(model.clampedSelection) }
                    .buttonStyle(.tapePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.timeline.held <= 0)
                    .help("Save the last \(DurationText.long(model.clampedSelection)) as an audio file")
                    .reportFrame("save", to: model)
            }
        }

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

        private var data: TimelineData { model.state.timeline }

        var body: some View {
            GeometryReader { proxy in
                let width = proxy.size.width
                let selectionX = x(forSecondsBack: model.clampedSelection, width: width)
                let preview = model.state.preview
                let playX = preview.map { selectionX + (width - selectionX) * CGFloat($0.fraction) }
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in draw(in: &context, size: size, selectionX: selectionX, playX: playX) }
                    if data.held > 0 {
                        if let playX {
                            Rectangle().fill(Tape.red).frame(width: 1.5, height: Self.tapeHeight).offset(
                                x: playX - 0.75
                            )
                            .allowsHitTesting(false)
                        }
                        Rectangle().fill(Tape.amber).frame(width: 1.5, height: Self.tapeHeight)
                            .offset(x: selectionX - 0.75)
                            .allowsHitTesting(false)
                        knob(playing: preview != nil)
                            .offset(x: selectionX - 10, y: -10)
                            .gesture(knobGesture(selectionX: selectionX, width: width))
                    }
                }
                .contentShape(Rectangle())
                .help("Top: your voice. Bottom: your Mac's sound. Drag to choose how far back to save.")
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let target = secondsBack(atX: value.location.x, width: width)
                        model.drag(to: target.seconds, pin: target.pinned)
                    }
                )
            }
            .frame(height: Self.height)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { model.timelineFrame = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in model.timelineFrame = frame }
                }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rewind timeline")
            .accessibilityValue("Saving the last \(DurationText.long(model.clampedSelection))")
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = 60
                switch direction {
                case .increment: model.drag(to: model.clampedSelection + step)
                case .decrement: model.drag(to: model.clampedSelection - step)
                default: break
                }
            }
            .accessibilityAction(named: "Preview") { model.actions.togglePreview(model.clampedSelection) }
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
                    if knobDrag?.moved == false { model.actions.togglePreview(model.clampedSelection) }
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

        private func draw(in context: inout GraphicsContext, size: CGSize, selectionX: CGFloat, playX: CGFloat?) {
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
                    } else if x >= selectionX {
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
                if let label = meeting.label {
                    var text = context.resolve(
                        Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Tape.meeting))
                    text.shading = .color(Tape.meeting)
                    let measured = text.measure(in: CGSize(width: 300, height: 20))
                    let left = min(max(0, x0), max(0, width - measured.width))
                    context.draw(text, at: CGPoint(x: left, y: markerTop + 8), anchor: .topLeading)
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
