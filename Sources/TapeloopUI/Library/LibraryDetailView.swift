#if os(macOS)
    import AppKit
    import SwiftUI
    import TapeloopCore

    /// The right side of the Library: title (renamable), facts, player, actions and transcript.
    struct LibraryDetailView: View {
        let model: LibraryModel
        let item: LibraryRecording
        @Binding var editingTitle: Bool
        @Binding var confirmingDelete: Bool

        @State private var draftTitle = ""
        @State private var shareAnchor = ViewAnchor()
        @State private var exportAnchor = ViewAnchor()
        @FocusState private var titleFieldFocused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                titleRow
                facts
                    .padding(.top, 3)
                    .padding(.bottom, 12)
                PlayerPanel(model: model, item: item)
                actions
                    .padding(.vertical, 12)
                TranscriptSection(model: model, item: item)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: editingTitle) { _, editing in
                if editing {
                    draftTitle = item.title
                    titleFieldFocused = true
                }
            }
        }

        // MARK: Title

        @ViewBuilder private var titleRow: some View {
            if editingTitle {
                TextField("Name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: Tape.radius).fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(RoundedRectangle(cornerRadius: Tape.radius).strokeBorder(Tape.amber, lineWidth: 1))
                    .padding(.horizontal, -6)
                    .focused($titleFieldFocused)
                    .onSubmit(commitTitle)
                    .onExitCommand { editingTitle = false }
                    .onChange(of: titleFieldFocused) { _, focused in
                        // Clicking elsewhere keeps the new name, as in Finder.
                        if !focused && editingTitle { commitTitle() }
                    }
                    .onAppear {
                        draftTitle = item.title
                        titleFieldFocused = true
                    }
            } else {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .onTapGesture(count: 2) { startEditing() }
                    Button(action: startEditing) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.transcribing.contains(item.url))
                    .help("Rename")
                    .accessibilityLabel("Rename")
                }
            }
        }

        private func startEditing() {
            guard !model.transcribing.contains(item.url) else { return }
            editingTitle = true
        }

        private func commitTitle() {
            guard editingTitle else { return }
            editingTitle = false
            model.rename(item.url, to: draftTitle)
        }

        // MARK: Facts

        private var facts: some View {
            FlowLayout(spacing: 10, lineSpacing: 3) {
                ForEach(factTexts, id: \.self) { text in
                    Text(text)
                }
                if let meeting = item.metadata?.meeting {
                    TagView("\(meeting.appName) meeting")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }

        private var factTexts: [String] {
            let calendar = model.displayCalendar
            var texts = [LibraryFormat.span(start: item.start, end: item.end, calendar: calendar)]
            if let duration = item.duration ?? (model.player.duration > 0 ? model.player.duration : nil) {
                texts.append(RecordingName.lengthLabel(duration))
            }
            if let metadata = item.metadata,
                let sources = LibraryFormat.sources(metadata.sources, mixed: metadata.mixed)
            {
                texts.append(sources)
            }
            texts.append(LibraryFormat.size(item.fileSize))
            return texts
        }

        // MARK: Actions

        private var actions: some View {
            HStack(spacing: 6) {
                Button {
                    if let view = shareAnchor.view { model.share(from: view) }
                } label: {
                    ActionLabel("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.tape)
                .background(ViewAnchorRepresentable(anchor: shareAnchor))
                .help("Send the audio file with AirDrop, Mail, Messages and more")
                Button(action: model.revealSelected) {
                    ActionLabel("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.tape)
                Button {
                    if let view = exportAnchor.view { model.showExportMenu(from: view) }
                } label: {
                    HStack(spacing: 5) {
                        ActionLabel("Export Transcript", systemImage: "doc.text")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                }
                .buttonStyle(.tape)
                .background(ViewAnchorRepresentable(anchor: exportAnchor))
                .disabled(item.metadata?.transcript == nil)
                .help("Save the transcript as plain text (.txt) or subtitles (.srt)")
                Spacer(minLength: 6)
                Button {
                    confirmingDelete = true
                } label: {
                    ActionLabel("Delete", systemImage: "trash")
                }
                .buttonStyle(.tapeDestructive)
                .help("Move the recording to the Trash")
            }
        }
    }

    /// An icon and a title for the action buttons.
    struct ActionLabel: View {
        let title: String
        let systemImage: String

        init(_ title: String, systemImage: String) {
            self.title = title
            self.systemImage = systemImage
        }

        var body: some View {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
                Text(title)
            }
        }
    }

    // MARK: - Player

    /// The waveform, play button, position, next bookmark and speed.
    struct PlayerPanel: View {
        let model: LibraryModel
        let item: LibraryRecording

        var body: some View {
            let player = model.player
            VStack(alignment: .leading, spacing: 8) {
                WaveformView(
                    peaks: model.peaks, progress: player.progress, markers: markers,
                    onSeek: { model.seek(toFraction: $0) })
                HStack(spacing: 10) {
                    Button(action: player.togglePlayPause) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Tape.onAmber)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: Tape.radius).fill(Tape.amber))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(player.loadError != nil)
                    .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Text(
                        "\(TranscriptFormatter.timestamp(player.currentTime)) / "
                            + TranscriptFormatter.timestamp(player.duration)
                    )
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    if let error = player.loadError {
                        Text(error).font(.system(size: 12)).foregroundStyle(Tape.red)
                    } else if let bookmark = nextBookmark {
                        Button {
                            model.seek(to: bookmark.offset)
                        } label: {
                            // The long form when there is room, else shorter ones.
                            ViewThatFits(in: .horizontal) {
                                Label(bookmarkLabel(bookmark, short: false), systemImage: "bookmark")
                                Label(bookmarkLabel(bookmark, short: true), systemImage: "bookmark")
                                Image(systemName: "bookmark")
                            }
                            .labelStyle(CompactLabelStyle())
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help(bookmarkLabel(bookmark, short: false) + ". Click to go there.")
                    }
                    Spacer(minLength: 8)
                    TapeSegmented(
                        AudioPlayer.rates.map { (value: $0, label: Self.rateLabel($0)) },
                        selection: Binding(get: { player.rate }, set: { player.rate = $0 })
                    )
                    .help("Playback speed")
                }
            }
            .tapePanel(padding: 11)
        }

        private var duration: TimeInterval { model.player.duration > 0 ? model.player.duration : item.duration ?? 0 }

        private var markers: [WaveformMarker] {
            guard duration > 0 else { return [] }
            return (item.metadata?.bookmarks ?? []).map {
                WaveformMarker(fraction: $0.offset / duration, label: $0.label)
            }
        }

        /// The first bookmark after the playhead, else the first one.
        private var nextBookmark: RecordingBookmark? {
            let bookmarks = (item.metadata?.bookmarks ?? []).sorted { $0.offset < $1.offset }
            return bookmarks.first { $0.offset > model.player.currentTime + 0.5 } ?? bookmarks.first
        }

        /// "Bookmark “decision” at 23:40", or the short form "“decision” 23:40".
        private func bookmarkLabel(_ bookmark: RecordingBookmark, short: Bool) -> String {
            let time = TranscriptFormatter.timestamp(bookmark.offset)
            let label = bookmark.label.flatMap { $0.isEmpty ? nil : "“\($0)”" }
            if short { return [label, time].compactMap { $0 }.joined(separator: " ") }
            return ["Bookmark", label, "at", time].compactMap { $0 }.joined(separator: " ")
        }

        static func rateLabel(_ rate: Float) -> String {
            let text = rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)
            return text + "×"
        }
    }

    /// An icon and a title, 4 points apart.
    struct CompactLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon.imageScale(.small)
                configuration.title
            }
        }
    }

    // MARK: - Transcript

    /// The transcript list with clickable times, or what to do when there is none.
    struct TranscriptSection: View {
        let model: LibraryModel
        let item: LibraryRecording

        /// The search-match background (a yellow highlighter).
        static let matchColor = Color(red: 1, green: 214 / 255, blue: 10 / 255).opacity(0.45)

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Tape.line).frame(height: 1)
                HStack {
                    Text("Transcript").font(.system(size: 12.5, weight: .bold))
                    Spacer()
                    if let transcript = item.metadata?.transcript {
                        Text("Made on this Mac · \(LibraryFormat.language(transcript.locale))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 6)
                content
            }
        }

        @ViewBuilder private var content: some View {
            if model.transcribing.contains(item.url) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            } else if let transcript = item.metadata?.transcript, !transcript.segments.isEmpty {
                TranscriptList(model: model, transcript: transcript)
            } else if item.metadata?.transcript != nil {
                note("The transcript is empty: no speech was recognised.")
            } else if model.canTranscribe {
                VStack(alignment: .leading, spacing: 8) {
                    note("No transcript yet. Transcription runs on this Mac; the audio is not sent anywhere.")
                    Button("Transcribe", action: model.transcribeSelected).buttonStyle(.tape)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    note("No transcript. Transcription can be turned on in Settings.")
                    Button("Open Settings", action: model.openSettings).buttonStyle(.tape)
                }
            }
        }

        private func note(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    /// The transcript lines: time (click to play from there), speaker, text with search matches highlighted; the
    /// line at the playhead is tinted and kept in view while playing.
    struct TranscriptList: View {
        let model: LibraryModel
        let transcript: Transcript

        var body: some View {
            let segments = transcript.segments
            let current = currentIndex
            let words = Self.words(model.query)
            let hasSpeakers = segments.contains { $0.speaker != nil }
            let timeWidth: CGFloat = (segments.last?.start ?? 0) >= 3600 ? 60 : 48
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                            line(
                                segment, current: index == current, words: words, hasSpeakers: hasSpeakers,
                                timeWidth: timeWidth
                            )
                            .id(index)
                        }
                    }
                }
                .onChange(of: current) { _, index in
                    guard model.player.isPlaying, let index else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }

        private func line(
            _ segment: TranscriptSegment, current: Bool, words: [String], hasSpeakers: Bool, timeWidth: CGFloat
        ) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    model.play(from: segment.start)
                } label: {
                    Text(TranscriptFormatter.timestamp(segment.start))
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Tape.meeting)
                }
                .buttonStyle(.plain)
                .frame(width: timeWidth, alignment: .leading)
                .help("Play from here")
                if hasSpeakers {
                    Text(segment.speaker.map(TranscriptFormatter.speakerName) ?? "")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                }
                Text(Self.highlighted(segment.text, words: words))
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 2).fill(current ? Tape.amber.opacity(0.18) : .clear))
        }

        /// The line at the playhead, once playback has started or the playhead was moved.
        private var currentIndex: Int? {
            let player = model.player
            guard player.isPlaying || player.currentTime > 0 else { return nil }
            let time = player.currentTime + 0.05
            return transcript.segments.lastIndex { $0.start <= time }
        }

        /// The search words.
        static func words(_ query: String) -> [String] {
            query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }

        /// `text` with every occurrence of each word (ignoring case and accents) on a highlighter background.
        static func highlighted(_ text: String, words: [String]) -> AttributedString {
            var attributed = AttributedString(text)
            for word in words {
                var searchStart = text.startIndex
                while searchStart < text.endIndex,
                    let range = text.range(
                        of: word, options: [.caseInsensitive, .diacriticInsensitive],
                        range: searchStart..<text.endIndex)
                {
                    if let attributedRange = Range(range, in: attributed) {
                        attributed[attributedRange].backgroundColor = matchColor
                    }
                    searchStart = range.upperBound
                }
            }
            return attributed
        }

        static let matchColor = TranscriptSection.matchColor
    }

    // MARK: - Anchors for AppKit menus

    /// Holds the AppKit view behind a SwiftUI button, so menus and the share picker can open next to it.
    @MainActor
    final class ViewAnchor {
        weak var view: NSView?
    }

    /// Puts an invisible AppKit view behind its parent and records it in `anchor`.
    struct ViewAnchorRepresentable: NSViewRepresentable {
        let anchor: ViewAnchor

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            anchor.view = nsView
        }
    }
#endif
