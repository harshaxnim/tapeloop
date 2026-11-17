#if os(macOS)
    import AppKit
    import SwiftUI
    import TapeloopCore

    /// The Library window: saved recordings grouped by day on the left; the selected one's details, player, actions
    /// and transcript on the right. Shows an explanation instead when there are no recordings.
    public struct LibraryView: View {
        @Bindable var model: LibraryModel
        @State private var confirmingDelete = false
        @State private var editingTitle = false
        @FocusState private var listFocused: Bool
        @Environment(\.colorScheme) private var colorScheme

        /// The smallest useful window size.
        public static let minimumSize = CGSize(width: 820, height: 520)
        /// A good first window size.
        public static let idealSize = CGSize(width: 1000, height: 620)

        /// Creates the view.
        public init(model: LibraryModel) {
            self.model = model
        }

        public var body: some View {
            Group {
                if model.recordings.isEmpty {
                    LibraryEmptyView(message: model.emptyStateMessage, onOpenSettings: model.openSettings)
                } else {
                    HStack(spacing: 0) {
                        sidebar
                            .frame(width: 270)
                            .background(sidebarBackground)
                        Rectangle().fill(Tape.line).frame(width: 1)
                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                model.reload()
                model.startWatching()
            }
            .onDisappear {
                model.stopWatching()
                model.player.pause()
            }
            .onChange(of: model.selectedURL) { editingTitle = false }
            .confirmationDialog(
                deleteQuestion, isPresented: $confirmingDelete, titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) { model.deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The audio file goes to the Trash. Its transcript and bookmarks are deleted.")
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }

        private var deleteQuestion: String {
            "Move “\(model.selected?.title ?? "this recording")” to the Trash?"
        }

        private var sidebarBackground: Color {
            Color.black.opacity(colorScheme == .dark ? 0.22 : 0.055)
        }

        // MARK: - Sidebar

        private var sidebar: some View {
            VStack(alignment: .leading, spacing: 0) {
                LibrarySearchField(text: $model.query)
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.filteredGroups) { group in
                                Text(group.title)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(group.items) { item in
                                    LibraryRow(
                                        item: item, selected: item.url == model.selectedURL,
                                        calendar: model.displayCalendar
                                    )
                                    .id(item.url)
                                    .onTapGesture {
                                        model.select(item.url)
                                        listFocused = true
                                    }
                                }
                            }
                            if model.filtered.isEmpty {
                                Text("No recordings match “\(model.query.trimmingCharacters(in: .whitespaces))”.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 10)
                    }
                    .onChange(of: model.selectedURL) { _, url in
                        if let url { proxy.scrollTo(url) }
                    }
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) {
                    model.selectPrevious()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.selectNext()
                    return .handled
                }
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    guard model.selected != nil else { return .ignored }
                    confirmingDelete = true
                    return .handled
                }
                .onKeyPress(.space) {
                    model.player.togglePlayPause()
                    return .handled
                }
                .onKeyPress(.return) {
                    guard model.selected != nil else { return .ignored }
                    editingTitle = true
                    return .handled
                }
            }
        }

        // MARK: - Detail

        @ViewBuilder private var detail: some View {
            if let item = model.selected {
                LibraryDetailView(
                    model: model, item: item, editingTitle: $editingTitle, confirmingDelete: $confirmingDelete)
            } else {
                Text("Select a recording.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Search field

    /// A flat search field with a magnifying glass; Escape clears it.
    struct LibrarySearchField: View {
        @Binding var text: String

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("Search", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onExitCommand { text = "" }
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Tape.radius).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Tape.radius).strokeBorder(Tape.line, lineWidth: 1))
            .help("Search names, meetings, bookmarks and transcripts")
        }
    }

    // MARK: - Row

    /// One recording in the list: title and length, then start time, app and a Meeting tag.
    struct LibraryRow: View {
        let item: LibraryRecording
        let selected: Bool
        let calendar: Calendar

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let duration = item.duration {
                        Text(RecordingName.lengthLabel(duration))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if item.metadata?.meeting != nil { TagView("Meeting") }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Tape.selectedFill : .clear)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(Tape.amber).frame(width: 2) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tape.radius))
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }

        private var subtitle: String {
            var parts = [LibraryFormat.time(item.start, calendar: calendar)]
            if let app = item.metadata?.meeting?.appName { parts.append(app) }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Empty state

    /// What the Library shows before anything was saved.
    struct LibraryEmptyView: View {
        let message: String
        let onOpenSettings: () -> Void

        var body: some View {
            VStack(spacing: 0) {
                CassetteShape()
                    .fill(.tertiary, style: FillStyle(eoFill: true))
                    .frame(width: 64, height: 44)
                Text("No recordings yet")
                    .font(.system(size: 15, weight: .bold))
                    .padding(.top, 10)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.tape)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Formatting

    /// Dates and sizes as the Library writes them.
    enum LibraryFormat {
        /// "10:48" (or "10:48 AM", following the user's settings).
        static func time(_ date: Date, calendar: Calendar) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }

        /// "Tuesday, 17 November 2026".
        static func day(_ date: Date, calendar: Calendar) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "EEEE, d MMMM yyyy"
            return formatter.string(from: date)
        }

        /// "Tuesday, 17 November 2026, 10:48 to 11:24"; the end's day is named when it differs.
        static func span(start: Date, end: Date?, calendar: Calendar) -> String {
            var text = "\(day(start, calendar: calendar)), \(time(start, calendar: calendar))"
            if let end {
                text += " to "
                if !calendar.isDate(start, inSameDayAs: end) { text += "\(day(end, calendar: calendar)), " }
                text += time(end, calendar: calendar)
            }
            return text
        }

        /// "Microphone + system audio, mixed".
        static func sources(_ sources: [SourceKind], mixed: Bool) -> String? {
            guard !sources.isEmpty else { return nil }
            let labels = sources.enumerated().map { index, source in
                index == 0 ? source.label : source.label.prefix(1).lowercased() + source.label.dropFirst()
            }
            var text = labels.joined(separator: " + ")
            if sources.count > 1 { text += mixed ? ", mixed" : ", separate tracks" }
            return text
        }

        /// "12.9 MB".
        static func size(_ bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }

        /// "English", from a locale identifier such as "en-US".
        static func language(_ identifier: String) -> String {
            let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
            return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? identifier
        }
    }

    // MARK: - Flow layout

    /// Lays out views in rows, wrapping to a new row when one is full.
    struct FlowLayout: Layout {
        var spacing: CGFloat = 10
        var lineSpacing: CGFloat = 3

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            arrange(width: proposal.width ?? .infinity, subviews: subviews).size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let result = arrange(width: bounds.width, subviews: subviews)
            for (index, point) in result.positions.enumerated() {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
            }
        }

        private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            var positions: [CGPoint] = []
            var rows: [(range: Range<Int>, height: CGFloat)] = []
            var x: CGFloat = 0
            var rowStart = 0
            var rowHeight: CGFloat = 0
            var widest: CGFloat = 0
            for (index, size) in sizes.enumerated() {
                if x > 0, x + size.width > width {
                    rows.append((rowStart..<index, rowHeight))
                    rowStart = index
                    x = 0
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: 0))
                x += size.width + spacing
                widest = max(widest, x - spacing)
                rowHeight = max(rowHeight, size.height)
            }
            if rowStart < sizes.count { rows.append((rowStart..<sizes.count, rowHeight)) }
            var y: CGFloat = 0
            for row in rows {
                for index in row.range {
                    positions[index].y = y + (row.height - sizes[index].height) / 2
                }
                y += row.height + lineSpacing
            }
            return (CGSize(width: min(widest, width), height: max(0, y - lineSpacing)), positions)
        }
    }
#endif
