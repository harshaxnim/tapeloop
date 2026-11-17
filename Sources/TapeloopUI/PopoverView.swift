#if os(macOS)
    import SwiftUI
    import TapeloopCore

    /// The menu bar popover: status, the rewind timeline, quick spans, Save, and the tool row. Kept minimal: one header
    /// line, the tape, its two ends, the spans with Save, and four icon buttons (labels are in their tooltips).
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
                if let banner = state.banner { bannerView(banner).padding(.top, 10) }
                if state.timeline.held > 0 || state.status != .needsAttention {
                    TimelineView(model: model).padding(.top, 16)
                    ticks.padding(.top, 3)
                }
                if let saving = state.saving {
                    savingView(saving).padding(.top, 12)
                } else if model.pendingBookmark != nil {
                    bookmarkField.padding(.top, 12)
                } else {
                    chips.padding(.top, 12)
                }
                tools.padding(.top, 8)
            }
            .padding(14)
            .frame(width: 380)
        }

        // MARK: Header

        private var header: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    statusDot
                    Text(state.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 8)
                    if let stat = state.stat {
                        Text(stat).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                            .help("How much audio Tapeloop is keeping, and the memory it uses")
                    }
                }
                if let subtitle = state.subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        @ViewBuilder private var statusDot: some View {
            switch state.status {
            case .recording: Circle().fill(Tape.amber).frame(width: 9, height: 9)
            case .paused: Circle().fill(Tape.grey).frame(width: 9, height: 9)
            case .needsAttention: Circle().strokeBorder(Tape.red, lineWidth: 2).frame(width: 9, height: 9)
            }
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

        // MARK: Ticks, chips, saving, bookmark

        /// The two ends of the tape: how far back it reaches, and now.
        private var ticks: some View {
            HStack {
                Text(DurationText.tick(state.timeline.span))
                Spacer(minLength: 0)
                Text(DurationText.tick(0))
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.tertiary)
        }

        private var chips: some View {
            let held = state.timeline.held
            return HStack(spacing: 0) {
                ForEach(PopoverModel.quickSpans, id: \.self) { minutes in
                    let enabled =
                        held > 0 && (minutes == PopoverModel.quickSpans[0] || Double(minutes) * 60 <= held + 30)
                    Button(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h") { model.choose(minutes: minutes) }
                        .buttonStyle(SpanButtonStyle(selected: model.quickMinutes == minutes))
                        .disabled(!enabled)
                        .reportFrame("chip-\(minutes)", to: model)
                        .help("Select the last \(minutes < 60 ? "\(minutes) minutes" : "hour")")
                }
                Spacer(minLength: 6)
                Button("Save \(DurationText.short(model.clampedSelection))") {
                    model.actions.save(model.clampedSelection)
                }
                .buttonStyle(.tapePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(held <= 0)
                .reportFrame("save", to: model)
            }
        }

        private func savingView(_ saving: PopoverState.Saving) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(saving.label).font(.system(size: 12))
                    Spacer()
                    Text("\(Int((saving.progress * 100).rounded())) %").font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Tape.selectedFill)
                        Rectangle().fill(Tape.amber).frame(width: proxy.size.width * min(1, max(0, saving.progress)))
                    }
                }
                .frame(height: 4)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                HStack {
                    Button("Cancel") { model.actions.cancelSave() }.buttonStyle(.tape).reportFrame("cancel", to: model)
                    Spacer()
                    Button("Save \(DurationText.short(model.clampedSelection))") {}.buttonStyle(.tapePrimary).disabled(
                        true)
                }
                .padding(.top, 6)
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

        // MARK: Tools

        private var tools: some View {
            HStack(spacing: 0) {
                Button {
                    model.actions.togglePause()
                } label: {
                    Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                }
                .help(state.isPaused ? "Resume recording" : "Pause recording; what is kept stays")
                .accessibilityLabel(state.isPaused ? "Resume" : "Pause")
                .reportFrame("pause", to: model)
                Button {
                    model.bookmark()
                } label: {
                    Image(systemName: "bookmark")
                }
                .disabled(state.isPaused || state.status == .paused)
                .help("Bookmark this moment")
                .accessibilityLabel("Bookmark")
                .reportFrame("bookmark", to: model)
                Spacer()
                Button {
                    model.actions.openLibrary()
                } label: {
                    Image(systemName: "books.vertical")
                }
                .help("Library: your saved recordings")
                .accessibilityLabel("Library")
                .reportFrame("library", to: model)
                Button {
                    model.actions.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Settings")
                .reportFrame("settings", to: model)
            }
            .buttonStyle(ToolButtonStyle())
            .foregroundStyle(.secondary)
        }
    }

    /// A quick span (5 min, 15 min, …): plain text, amber when chosen.
    struct SpanButtonStyle: ButtonStyle {
        var selected: Bool
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 12, weight: selected ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(selected ? Tape.amber : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? Tape.amber.opacity(0.14) : .clear))
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
                .contentShape(Rectangle())
        }
    }

    /// The rewind timeline: two level lanes, meetings, gaps, bookmarks, and the draggable selection.
    struct TimelineView: View {
        @Bindable var model: PopoverModel
        static let height: CGFloat = 70
        private let laneTops: [CGFloat] = [16, 43]
        private let laneHeight: CGFloat = 24

        private var data: TimelineData { model.state.timeline }

        var body: some View {
            GeometryReader { proxy in
                let width = proxy.size.width
                let selectionX = x(forSecondsBack: model.clampedSelection, width: width)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in draw(in: &context, size: size, selectionX: selectionX) }
                    if data.held > 0 {
                        Rectangle().fill(Tape.amber.opacity(0.08))
                            .frame(width: max(0, width - selectionX), height: Self.height)
                            .offset(x: selectionX)
                            .allowsHitTesting(false)
                        Rectangle().fill(Tape.amber).frame(width: 1.5, height: Self.height).offset(x: selectionX - 0.75)
                            .allowsHitTesting(false)
                        handle.offset(x: selectionX - 7, y: -2)
                    }
                }
                .contentShape(Rectangle())
                .help("Top: your microphone. Bottom: your Mac's sound. Drag to choose how far back to save.")
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
        }

        private var handle: some View {
            RoundedRectangle(cornerRadius: 2).fill(Tape.amber)
                .frame(width: 14, height: 18)
                .overlay(
                    HStack(spacing: 3) {
                        Rectangle().frame(width: 1.5, height: 8)
                        Rectangle().frame(width: 1.5, height: 8)
                    }
                    .foregroundStyle(Color.black.opacity(0.55))
                )
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                .help("Drag to choose how far back to save")
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

        private func draw(in context: inout GraphicsContext, size: CGSize, selectionX: CGFloat) {
            let width = size.width
            let height = size.height
            // Meetings.
            for meeting in data.meetings {
                let x0 = max(0, xOf(meeting.start, width: width))
                let x1 = min(width, xOf(meeting.end, width: width))
                guard x1 > x0 else { continue }
                context.fill(
                    Path(CGRect(x: x0, y: 12, width: x1 - x0, height: height - 12)),
                    with: .color(Tape.meeting.opacity(0.09)))
                context.fill(Path(CGRect(x: x0, y: 12, width: x1 - x0, height: 1.5)), with: .color(Tape.meeting))
            }
            // Gaps (sleep, pause), hatched.
            for gap in data.gaps {
                let x0 = max(0, xOf(gap.start, width: width))
                let x1 = min(width, xOf(gap.end, width: width))
                guard x1 > x0 else { continue }
                let rect = CGRect(x: x0, y: 14, width: x1 - x0, height: height - 14)
                var hatch = Path()
                var hx = x0 - (height - 14)
                while hx < x1 {
                    hatch.move(to: CGPoint(x: hx, y: height))
                    hatch.addLine(to: CGPoint(x: hx + (height - 14), y: 14))
                    hx += 6
                }
                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    layer.stroke(hatch, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
                }
            }
            // Level lanes.
            for (laneIndex, lane) in data.lanes.enumerated() where laneIndex < laneTops.count {
                let top = laneTops[laneIndex]
                let count = max(1, lane.levels.count)
                let step = width / CGFloat(count)
                var quiet = Path()
                var inSelection = Path()
                var outside = Path()
                for (index, level) in lane.levels.enumerated() {
                    let x = CGFloat(index) * step
                    if level < 0 {
                        quiet.addRect(CGRect(x: x, y: top + laneHeight / 2, width: max(1, step - 1), height: 0.8))
                        continue
                    }
                    let h = max(1.5, CGFloat(Self.visual(level)) * laneHeight)
                    let rect = CGRect(x: x + 0.5, y: top + (laneHeight - h) / 2, width: max(1, step - 1), height: h)
                    if x + step / 2 >= selectionX { inSelection.addRect(rect) } else { outside.addRect(rect) }
                }
                context.fill(quiet, with: .color(Color.primary.opacity(0.12)))
                context.fill(outside, with: .color(Color.primary.opacity(0.3)))
                context.fill(inSelection, with: .color(Tape.amber))
            }
            // Bookmarks.
            for mark in data.bookmarks {
                let x = xOf(mark.date, width: width)
                guard x >= 0, x <= width else { continue }
                context.fill(
                    Path(CGRect(x: x, y: 2, width: 1, height: height - 2)), with: .color(Color.primary.opacity(0.35)))
                var flag = Path()
                flag.move(to: CGPoint(x: x, y: 2))
                flag.addLine(to: CGPoint(x: x + 7, y: 2))
                flag.addLine(to: CGPoint(x: x + 5, y: 4.75))
                flag.addLine(to: CGPoint(x: x + 7, y: 7.5))
                flag.addLine(to: CGPoint(x: x, y: 7.5))
                flag.closeSubpath()
                context.fill(flag, with: .color(Color.primary.opacity(0.8)))
            }
        }

        /// Maps a linear peak (0 to 1) to a bar height fraction on a 50 dB scale, so speech is visible.
        static func visual(_ level: Float) -> Float {
            guard level > 0 else { return 0 }
            let db = 20 * log10(level)
            return min(1, max(0.06, (db + 50) / 50))
        }
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
