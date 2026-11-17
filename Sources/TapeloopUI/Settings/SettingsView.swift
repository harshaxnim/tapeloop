#if os(macOS)
    import AppKit
    import Carbon.HIToolbox
    import SwiftUI
    import TapeloopCore
    import UniformTypeIdentifiers

    /// The Settings window: eight tabs in a toolbar strip, each a two-column form (labels right-aligned on the left).
    public struct SettingsView: View {
        @Bindable var model: SettingsModel
        private let scrolls: Bool

        /// Creates the window content. `scrolls: false` lays the tab out without a scroll view (for snapshots, which
        /// cannot render scroll views).
        public init(model: SettingsModel, scrolls: Bool = true) {
            self.model = model
            self.scrolls = scrolls
        }

        public var body: some View {
            VStack(spacing: 0) {
                tabStrip
                Rectangle().fill(Tape.line).frame(height: 1)
                if scrolls {
                    ScrollView { form }
                } else {
                    form
                }
            }
            .frame(width: 640)
            .frame(minHeight: 420)
        }

        private var tabStrip: some View {
            HStack(spacing: 2) {
                ForEach(SettingsModel.Tab.allCases) { tab in
                    let on = model.tab == tab
                    Button {
                        model.tab = tab
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.symbol).font(.system(size: 17)).frame(height: 20)
                            Text(tab.rawValue).font(.system(size: 11))
                        }
                        .frame(width: 70, height: 46)
                        .foregroundStyle(on ? Tape.amber : .secondary)
                        .background(RoundedRectangle(cornerRadius: Tape.radius).fill(on ? Tape.selectedFill : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }

        private var form: some View {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        @ViewBuilder private var content: some View {
            switch model.tab {
            case .general: GeneralTab(model: model)
            case .recording: RecordingTab(model: model)
            case .memory: MemoryTab(model: model)
            case .shortcuts: ShortcutsTab(model: model)
            case .meetings: MeetingsTab(model: model)
            case .transcripts: TranscriptsTab(model: model)
            case .privacy: PrivacyTab(model: model)
            case .about: AboutTab()
            }
        }
    }

    // MARK: - Layout helpers

    /// A settings row: a right-aligned label, then the controls and an optional help line.
    struct Row<Content: View>: View {
        let label: String
        let help: String?
        @ViewBuilder let content: Content

        init(_ label: String, help: String? = nil, @ViewBuilder content: () -> Content) {
            self.label = label
            self.help = help
            self.content = content()
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(label.isEmpty ? "" : "\(label):")
                    .font(.system(size: 13))
                    .frame(width: 170, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                    content
                    if let help {
                        Text(help).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The "Allowed" / "Allow…" / "Open System Settings" control for a permission.
    struct PermissionBadge: View {
        let state: PermissionState
        let request: () -> Void
        let open: () -> Void

        var body: some View {
            switch state {
            case .allowed:
                Label("Allowed", systemImage: "checkmark").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tape.green).labelStyle(.titleAndIcon)
            case .notAsked: Button("Allow…", action: request).buttonStyle(.tape)
            case .asked:
                HStack(spacing: 8) {
                    Text("Asked").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Button("Check in System Settings", action: open).buttonStyle(.tape)
                }
                .help("If you chose Don't Allow, turn it on in System Settings.")
            case .denied: Button("Open System Settings", action: open).buttonStyle(.tape)
            case .unavailable: Text("Not available on this Mac").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    /// Text in a flat, bordered box (a static "pop-up" look).
    struct Boxed: View {
        let text: String
        var body: some View {
            Text(text).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: Tape.radius).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Tape.radius).strokeBorder(Tape.line))
        }
    }

    // MARK: - General

    struct GeneralTab: View {
        @Bindable var model: SettingsModel
        @State private var launch = false

        var body: some View {
            Row("Startup", help: model.launchError) {
                Toggle("Open Tapeloop when I log in", isOn: $launch).toggleStyle(.tapeCheckbox)
                    .onAppear { launch = model.services.launchAtLogin() }
                    .onChange(of: launch) { _, value in
                        guard value != model.services.launchAtLogin() else { return }
                        model.launchError = model.services.setLaunchAtLogin(value)
                        launch = model.services.launchAtLogin()
                    }
            }
            Row("Save recordings to") {
                HStack(spacing: 8) {
                    Boxed(text: Self.display(model.settings.recorder.saveFolder))
                    Button("Choose…") { chooseFolder() }.buttonStyle(.tape)
                    Button {
                        NSWorkspace.shared.open(model.settings.recorder.saveFolder)
                    } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open the folder in Finder")
                }
            }
            Row(
                "With both sources",
                help: "A mixed file is easiest to share. Separate files keep you and the other side apart, for editing."
            ) {
                TapeSegmented(
                    [(true, "One mixed file"), (false, "One file per source")],
                    selection: $model.settings.recorder.mixSources)
            }
            Row("File names", help: "Date, time and length, then the meeting or calendar title when known.") {
                Text("Tapeloop 2026-11-17 10.48 (36 min) Weekly sync.m4a").font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Row("When quitting") {
                Toggle("Warn me that the buffer will be erased", isOn: $model.settings.warnOnQuit).toggleStyle(
                    .tapeCheckbox)
            }
            Row("Welcome guide") {
                Button("Show Welcome Guide Again") { model.services.showWelcome() }.buttonStyle(.tape)
            }
        }

        static func display(_ url: URL) -> String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path = url.path.hasPrefix(home) ? String(url.path.dropFirst(home.count + 1)) : url.path
            return path.split(separator: "/").joined(separator: " › ")
        }

        private func chooseFolder() {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose"
            panel.message = "Choose where Tapeloop saves recordings."
            panel.directoryURL = model.settings.recorder.saveFolder
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url {
                model.settings.recorder.saveFolderPath = url.path
            }
        }
    }

    // MARK: - Recording

    struct RecordingTab: View {
        @Bindable var model: SettingsModel

        private func sourceBinding(_ kind: SourceKind) -> Binding<Bool> {
            Binding(
                get: { model.settings.recorder.sources.contains(kind) },
                set: { on in
                    if on {
                        model.settings.recorder.sources.insert(kind)
                    } else {
                        model.settings.recorder.sources.remove(kind)
                    }
                })
        }

        var body: some View {
            let devices = model.services.inputDevices()
            let defaultName = model.services.defaultInputName().map { "\($0) (default)" } ?? "System default"
            Row(
                "Microphone",
                help: "Follows the system default when set to default; restarts by itself when you plug in a headset."
            ) {
                HStack(spacing: 10) {
                    Toggle("", isOn: sourceBinding(.microphone)).toggleStyle(.tapeSwitch).labelsHidden()
                    Picker("", selection: $model.settings.inputDeviceUID) {
                        Text(defaultName).tag(String?.none)
                        if !devices.isEmpty { Divider() }
                        ForEach(devices, id: \.uid) { device in Text(device.name).tag(Optional(device.uid)) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(!model.settings.recorder.sources.contains(.microphone))
                }
            }
            Row("System audio") {
                HStack(spacing: 10) {
                    Toggle("", isOn: sourceBinding(.system)).toggleStyle(.tapeSwitch).labelsHidden()
                    Text(
                        model.settings.excludedBundleIDs.isEmpty
                            ? "All apps" : "All apps except those excluded in Privacy"
                    )
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
            Row("Levels") {
                let _ = model.tick
                let levels = model.services.levels()
                VStack(alignment: .leading, spacing: 5) {
                    LevelMeter(label: "You", level: levels[.microphone] ?? 0)
                    LevelMeter(label: "System", level: levels[.system] ?? 0)
                }
            }
            Row(
                "Quality",
                help: Self.qualityHelp(
                    bitRate: model.settings.recorder.bitRate, sources: model.settings.recorder.sources.count)
            ) {
                TapeSegmented(
                    RecorderSettings.presetBitRates.map { ($0, "\($0 / 1000) kbps") },
                    selection: $model.settings.recorder.bitRate)
            }
            Row("Pause recording") {
                Toggle("While the Mac sleeps (always)", isOn: .constant(true)).toggleStyle(.tapeCheckbox).disabled(true)
                Toggle("While the screen is locked", isOn: $model.settings.pauseWhenLocked).toggleStyle(.tapeCheckbox)
            }
        }
    }

    extension RecordingTab {
        /// Describes the chosen AAC bit rate: how it sounds and the memory it needs per hour (the same estimate the
        /// Memory tab uses).
        nonisolated static func qualityHelp(bitRate: Int, sources: Int) -> String {
            let kbps = bitRate / 1000
            let sound =
                switch bitRate {
                case ..<40_000: "The smallest: speech stays understandable but sounds thin."
                case ..<56_000: "Clear for speech (recommended)."
                case ..<80_000: "Fuller sound, for speech with music in the background."
                default: "The best quality here, for music."
                }
            let mb = { (rates: [Int]) in
                "\(Int((Double(MemoryBudget(bitRates: rates).bytes(for: 3600)) / 1_000_000).rounded())) MB"
            }
            var text = "\(kbps) kbps AAC, per source. \(sound) About \(mb([bitRate])) of memory per hour per source"
            if sources > 1 {
                text += "; \(mb(Array(repeating: bitRate, count: sources))) per hour with both sources."
            } else {
                text += "."
            }
            return text
        }
    }

    /// A small horizontal level meter (50 dB scale).
    struct LevelMeter: View {
        let label: String
        let level: Float

        var body: some View {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Tape.fill)
                        Rectangle().fill(Tape.amber)
                            .frame(width: proxy.size.width * CGFloat(TimelineView.visual(level)))
                            .animation(.linear(duration: 0.2), value: level)
                    }
                }
                .frame(width: 200, height: 6)
                .clipShape(RoundedRectangle(cornerRadius: 1))
            }
        }
    }

    // MARK: - Memory

    struct MemoryTab: View {
        @Bindable var model: SettingsModel
        @State private var askDisk: TimeInterval?
        @State private var confirmErase = false

        private static let custom: [TimeInterval] = [10, 45, 180, 240, 480, 720].map { $0 * 60 }

        var body: some View {
            let recorder = model.settings.recorder
            let duration = Binding<TimeInterval>(get: { recorder.bufferDuration }, set: { choose($0) })
            Row("Keep the last", help: "Older audio is dropped as new audio arrives.") {
                HStack(spacing: 8) {
                    TapeSegmented(
                        RecorderSettings.presetDurations.map {
                            ($0, DurationText.short($0).replacingOccurrences(of: " 00", with: ""))
                        },
                        selection: duration)
                    Menu(
                        RecorderSettings.presetDurations.contains(recorder.bufferDuration)
                            ? "Custom…" : DurationText.long(recorder.bufferDuration)
                    ) {
                        ForEach(Self.custom, id: \.self) { value in Button(DurationText.long(value)) { choose(value) } }
                    }
                    .fixedSize()
                }
            }
            Row("Memory use") {
                let _ = model.tick
                let mb = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .decimal)
                }
                let full = model.budget.bytes(for: recorder.bufferDuration)
                Text(
                    "\(mb(model.services.bytesInRAM())) used now · about \(mb(min(full, recorder.ramLimitBytes))) when full · \(mb(recorder.ramLimitBytes)) limit"
                )
                .font(.system(size: 12.5).monospacedDigit())
                planNote
            }
            Row(
                "Memory limit",
                help:
                    "The most memory the buffer may use. \(DurationText.long(recorder.bufferDuration)) at \(recorder.bitRate / 1000) kbps with \(recorder.sources.count == 2 ? "two sources" : "one source") needs about \(ByteCountFormatter.string(fromByteCount: Int64(model.budget.bytes(for: recorder.bufferDuration)), countStyle: .decimal))."
            ) {
                Picker("", selection: $model.settings.recorder.ramLimitBytes) {
                    ForEach([100, 250, 500, 1000, 2000], id: \.self) { mb in
                        Text(mb < 1000 ? "\(mb) MB" : "\(mb / 1000) GB").tag(mb * 1_000_000)
                    }
                }
                .labelsHidden().fixedSize()
            }
            Row(
                "Beyond the limit",
                help:
                    "Off: a buffer that does not fit is shortened to what fits, and Tapeloop says so. On: the older part goes to a private folder on disk and is erased when Tapeloop quits or restarts."
            ) {
                Toggle("Use disk for the part beyond the memory limit", isOn: $model.settings.recorder.allowDisk)
                    .toggleStyle(.tapeCheckbox)
            }
            Row("When memory is short") {
                Text(
                    "If macOS runs low on memory, Tapeloop shortens the buffer (oldest first) rather than slowing your Mac down."
                )
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Row("") {
                Button("Erase Buffer Now…") { confirmErase = true }.buttonStyle(.tapeDestructive)
            }
            .alert(
                "Turn on disk use?", isPresented: Binding(get: { askDisk != nil }, set: { if !$0 { askDisk = nil } })
            ) {
                Button(
                    "Use Disk Beyond \(ByteCountFormatter.string(fromByteCount: Int64(recorder.ramLimitBytes), countStyle: .decimal))"
                ) {
                    if let value = askDisk {
                        model.settings.recorder.allowDisk = true
                        model.settings.recorder.bufferDuration = value
                    }
                }
                Button("Keep \(DurationText.long(model.budget.maxDurationInRAM)) in Memory Only") {
                    if let value = askDisk { model.settings.recorder.bufferDuration = value }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let value = askDisk {
                    Text(
                        "A \(DurationText.long(value)) buffer at this quality needs about \(ByteCountFormatter.string(fromByteCount: Int64(model.budget.bytes(for: value)), countStyle: .decimal)). The newest \(ByteCountFormatter.string(fromByteCount: Int64(recorder.ramLimitBytes), countStyle: .decimal)) stays in memory; the older part is kept in a private folder on disk and erased when Tapeloop quits."
                    )
                }
            }
            .alert("Erase the buffer?", isPresented: $confirmErase) {
                Button("Erase", role: .destructive) { model.services.eraseBuffer() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Everything Tapeloop is keeping in memory (and on disk, if used) is deleted. Saved recordings are not affected."
                )
            }
        }

        @ViewBuilder private var planNote: some View {
            switch model.settings.recorder.plan {
            case .ramOnly: EmptyView()
            case .spill(let ram, let disk):
                Text(
                    "The newest \(DurationText.long(ram)) stays in memory; the older \(DurationText.long(disk)) goes to disk."
                )
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            case .shortened(let to, _):
                Text("Only \(DurationText.long(to)) fits in the memory limit, so the buffer is shortened to that.")
                    .font(.system(size: 11.5)).foregroundStyle(Tape.red)
            }
        }

        private func choose(_ value: TimeInterval) {
            let recorder = model.settings.recorder
            if !recorder.allowDisk, value > recorder.budget.maxDurationInRAM {
                askDisk = value
            } else {
                model.settings.recorder.bufferDuration = value
            }
        }
    }

    // MARK: - Shortcuts

    struct ShortcutsTab: View {
        @Bindable var model: SettingsModel

        var body: some View {
            let taken = model.services.takenShortcuts()
            ForEach(ShortcutAction.allCases, id: \.self) { action in
                Row(
                    action.label,
                    help: model.recordingShortcut == action
                        ? "Press the keys now (with ⌘, ⌥ or ⌃), Escape to cancel, or Delete to clear."
                        : taken.contains(action)
                            ? "Another app already uses this shortcut. Choose a different one." : nil
                ) {
                    HStack(spacing: 8) {
                        if action == .save {
                            Picker("", selection: $model.settings.shortcutSaveMinutes) {
                                ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { m in
                                    Text(m < 60 ? "\(m) minutes" : "hour").tag(m)
                                }
                            }
                            .labelsHidden().fixedSize()
                        }
                        ShortcutField(model: model, action: action, taken: taken.contains(action))
                    }
                }
            }
            Row("") {
                Text("Shortcuts work from any app. If another app already uses one, Tapeloop says so here.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A click-to-record shortcut field.
    struct ShortcutField: View {
        @Bindable var model: SettingsModel
        let action: ShortcutAction
        let taken: Bool
        @State private var monitor: Any?

        var body: some View {
            let recording = model.recordingShortcut == action
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Type a shortcut…" : model.combo(action)?.display ?? "None")
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(recording ? .secondary : (model.combo(action) == nil ? .secondary : .primary))
                    .frame(minWidth: 110)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: Tape.radius).fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Tape.radius)
                            .strokeBorder(
                                recording ? Tape.amber : (taken ? Tape.red : Tape.line), lineWidth: recording ? 2 : 1))
            }
            .buttonStyle(.plain)
            .onDisappear { stop() }
        }

        private func start() {
            stop()
            model.recordingShortcut = action
            model.services.suspendShortcuts(true)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch Int(event.keyCode) {
                case kVK_Escape:
                    stop()
                case kVK_Delete, kVK_ForwardDelete:
                    model.setCombo(nil, for: action)
                    stop()
                default:
                    guard let combo = KeyCombo.from(event) else { return nil }
                    model.setCombo(combo, for: action)
                    stop()
                }
                return nil
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if model.recordingShortcut == action {
                model.recordingShortcut = nil
                model.services.suspendShortcuts(false)
            }
        }
    }

    extension KeyCombo {
        /// Builds a combo from a key-down event (Carbon modifier flags), or `nil` when no ⌘, ⌥ or ⌃ is held.
        public static func from(_ event: NSEvent) -> KeyCombo? {
            var modifiers: UInt32 = 0
            let flags = event.modifierFlags
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
            // The key's name without modifiers, from the keyboard layout (⌥ changes characters on macOS).
            let key = (event.charactersIgnoringModifiers ?? "").uppercased()
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                return nil
            }
            return KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
        }
    }

    // MARK: - Meetings

    struct MeetingsTab: View {
        @Bindable var model: SettingsModel

        var body: some View {
            let detect = model.settings.meetings.detect
            Row(
                "Meeting detection",
                help:
                    "Zoom, Microsoft Teams, Google Meet and Webex in a browser, FaceTime, Slack huddles, Discord, Skype. No permission is needed."
            ) {
                Toggle("Notice when a meeting app uses the microphone", isOn: $model.settings.meetings.detect)
                    .toggleStyle(.tapeSwitch)
            }
            Row("When a meeting ends") {
                Toggle("Offer to save it (notification)", isOn: $model.settings.meetings.offerToSave).toggleStyle(
                    .tapeCheckbox)
                Toggle("Save it automatically", isOn: $model.settings.meetings.autoSave).toggleStyle(.tapeCheckbox)
            }
            .disabled(!detect).opacity(detect ? 1 : 0.5)
            Row("On the timeline") {
                Toggle("Mark meetings as blue bands", isOn: $model.settings.meetings.showOnTimeline).toggleStyle(
                    .tapeCheckbox)
            }
            .disabled(!detect).opacity(detect ? 1 : 0.5)
            let calendarState = model.services.permission(.calendar)
            Row(
                "Calendar",
                help: "Names recordings after the calendar event you were in."
            ) {
                HStack(spacing: 12) {
                    Toggle("Use calendar event titles", isOn: $model.settings.meetings.useCalendar).toggleStyle(
                        .tapeSwitch)
                    if model.settings.meetings.useCalendar {
                        PermissionBadge(
                            state: calendarState,
                            request: {
                                Task {
                                    await model.services.request(.calendar); model.tick += 1
                                }
                            },
                            open: { model.services.openSystemSettings(.calendar) })
                    }
                }
            }
            if model.settings.meetings.useCalendar, calendarState == .allowed {
                let calendars = model.services.calendars()
                Row(
                    "Calendars to use",
                    help: model.settings.meetings.calendarIDs.isEmpty
                        ? "All calendars are used until you pick some." : nil
                ) {
                    ForEach(calendars, id: \.id) { calendar in
                        Toggle(isOn: calendarBinding(calendar.id, all: calendars.map(\.id))) {
                            HStack(spacing: 6) {
                                Circle().fill(calendar.color).frame(width: 8, height: 8)
                                Text(calendar.title)
                            }
                        }
                        .toggleStyle(.tapeCheckbox)
                    }
                }
            }
        }

        /// An empty list means "all calendars".
        private func calendarBinding(_ id: String, all: [String]) -> Binding<Bool> {
            Binding(
                get: {
                    model.settings.meetings.calendarIDs.isEmpty || model.settings.meetings.calendarIDs.contains(id)
                },
                set: { on in
                    var ids = model.settings.meetings.calendarIDs.isEmpty ? all : model.settings.meetings.calendarIDs
                    if on { ids.append(id) } else { ids.removeAll { $0 == id } }
                    ids = all.filter(ids.contains)
                    model.settings.meetings.calendarIDs = ids.count == all.count ? [] : ids
                })
        }
    }

    // MARK: - Transcripts

    struct TranscriptsTab: View {
        @Bindable var model: SettingsModel

        var body: some View {
            let settings = model.settings.transcription
            let enabled = settings.enabled
            let parakeet = settings.engine == .parakeet
            Row("Transcription", help: "Transcripts are made on this Mac. Audio never leaves it.") {
                Toggle("Transcribe recordings", isOn: $model.settings.transcription.enabled).toggleStyle(.tapeSwitch)
            }
            Group {
                Row(
                    "Engine",
                    help: parakeet
                        ? "NVIDIA Parakeet, a speech model that runs on this Mac's graphics processor. English only. Needs a one-time download of \(model.services.speechModelSize)."
                        : "Apple's on-device speech recognition. Many languages; needs the Speech Recognition permission."
                ) {
                    TapeSegmented(
                        [(TranscriptionEngine.parakeet, "Parakeet"), (.apple, "Apple speech recognition")],
                        selection: $model.settings.transcription.engine)
                }
                if parakeet {
                    Row("Speech model") { SpeechModelRow(services: model.services) }
                } else {
                    Row("Permission") {
                        PermissionBadge(
                            state: model.services.permission(.speech),
                            request: {
                                Task {
                                    await model.services.request(.speech); model.tick += 1
                                }
                            },
                            open: { model.services.openSystemSettings(.speech) })
                    }
                    Row(
                        "Language",
                        help: "Only languages your Mac can recognise without a network connection are listed."
                    ) {
                        let languages = model.services.transcriptionLanguages()
                        Picker("", selection: $model.settings.transcription.localeID) {
                            Text("The system language").tag(String?.none)
                            if !languages.isEmpty { Divider() }
                            ForEach(languages, id: \.id) { language in Text(language.name).tag(Optional(language.id)) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                Row(
                    "When",
                    help: Self.help(
                        for: parakeet ? settings.mode : (settings.mode == .live ? .afterSave : settings.mode))
                ) {
                    TapeSegmented(
                        parakeet
                            ? [
                                (TranscriptionMode.afterSave, "After each save"), (.live, "Live while recording"),
                                (.manual, "Only when I ask"),
                            ]
                            : [(TranscriptionMode.afterSave, "After each save"), (.manual, "Only when I ask")],
                        selection: Binding(
                            get: { parakeet || settings.mode != .live ? settings.mode : .afterSave },
                            set: { model.settings.transcription.mode = $0 }))
                }
                Row("Label speakers") {
                    Toggle(
                        "Mark lines as You or System (from the two sources)",
                        isOn: $model.settings.transcription.labelSpeakers
                    )
                    .toggleStyle(.tapeCheckbox)
                }
            }
            .disabled(!enabled).opacity(enabled ? 1 : 0.5)
            Row("") {
                Text(
                    "Transcripts are exported from the Library as plain text (.txt) or subtitles (.srt). Other engines, for example Whisper, can be added by developers; see the project's documentation."
                )
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }

        static func help(for mode: TranscriptionMode) -> String {
            switch mode {
            case .afterSave:
                "The model is loaded for each save and released afterwards, so it uses memory only while it works."
            case .live:
                "Audio is transcribed as it arrives, so a save includes its transcript at once. The model stays loaded while recording: about 0.8 GB of memory and steady graphics-processor use."
            case .manual: "Transcribe a recording from the Library when you want one."
            }
        }
    }

    /// The speech model's status and actions: Download (with progress and Cancel), Import, Delete, Try Again. It
    /// refreshes itself twice a second.
    public struct SpeechModelRow: View {
        let services: SettingsServices
        @State private var confirmDelete = false

        /// Creates the row.
        public init(services: SettingsServices) {
            self.services = services
        }

        public var body: some View {
            SwiftUI.TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                content(services.speechModelStatus())
            }
            .alert("Delete the speech model?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { services.deleteSpeechModel() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Transcription with Parakeet stops until the model is downloaded again (\(services.speechModelSize)). Existing transcripts are kept."
                )
            }
        }

        @ViewBuilder private func content(_ status: SpeechModelStatus) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(services.speechModelName).font(.system(size: 12.5))
                switch status {
                case .notInstalled:
                    HStack(spacing: 8) {
                        Button("Download (\(services.speechModelSize))") { services.downloadSpeechModel() }.buttonStyle(
                            .tapePrimary)
                        Button("Import File…") { services.importSpeechModel() }.buttonStyle(.tape)
                    }
                    Text("Downloaded from Tapeloop's GitHub page only when you press Download.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                case .downloading(let fraction):
                    HStack(spacing: 10) {
                        ProgressBar(fraction: fraction).frame(width: 200)
                        Text("\(Int((fraction * 100).rounded())) %").font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("Cancel") { services.cancelSpeechModelDownload() }.buttonStyle(.tape)
                    }
                case .verifying:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking the downloaded file…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                case .installed:
                    HStack(spacing: 10) {
                        Label("Installed", systemImage: "checkmark").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tape.green)
                        Text(services.speechModelSize).font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Delete…") { confirmDelete = true }.buttonStyle(.tape)
                    }
                case .failed(let message):
                    Text(message).font(.system(size: 12)).foregroundStyle(Tape.red).fixedSize(
                        horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Try Again") { services.downloadSpeechModel() }.buttonStyle(.tapePrimary)
                        Button("Import File…") { services.importSpeechModel() }.buttonStyle(.tape)
                    }
                }
            }
        }
    }

    /// A flat amber progress bar.
    struct ProgressBar: View {
        let fraction: Double
        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Tape.selectedFill)
                    Rectangle().fill(Tape.amber).frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: 4)
            .clipShape(RoundedRectangle(cornerRadius: 1))
        }
    }

    // MARK: - Privacy

    struct PrivacyTab: View {
        @Bindable var model: SettingsModel
        @State private var selected: String?

        var body: some View {
            Row(
                "Never record audio from",
                help: "Their sound is left out of system audio, so background music does not fill your recordings."
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 0) {
                        if model.settings.excludedBundleIDs.isEmpty {
                            Text("No apps excluded").font(.system(size: 12.5)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        ForEach(model.settings.excludedBundleIDs, id: \.self) { id in
                            let info = model.services.appInfo(id)
                            HStack(spacing: 8) {
                                if let icon = info?.icon {
                                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                                }
                                Text(info?.name ?? id).font(.system(size: 12.5))
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(selected == id ? Tape.amber.opacity(0.25) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = id }
                        }
                    }
                    .frame(width: 300)
                    .frame(minHeight: 60, alignment: .top)
                    .background(Color(nsColor: .controlBackgroundColor))
                    HStack(spacing: 0) {
                        Button {
                            addApp()
                        } label: {
                            Image(systemName: "plus").frame(width: 24, height: 20)
                        }
                        .help("Exclude an app")
                        Rectangle().fill(Tape.line).frame(width: 1, height: 20)
                        Button {
                            model.settings.excludedBundleIDs.removeAll { $0 == selected }
                            selected = nil
                        } label: {
                            Image(systemName: "minus").frame(width: 24, height: 20)
                        }
                        .disabled(selected == nil)
                        .help("Record this app again")
                        Spacer()
                    }
                    .buttonStyle(.plain)
                    .frame(width: 300)
                    .overlay(Rectangle().fill(Tape.line).frame(height: 1), alignment: .top)
                }
                .clipShape(RoundedRectangle(cornerRadius: Tape.radius))
                .overlay(RoundedRectangle(cornerRadius: Tape.radius).strokeBorder(Tape.line))
            }
            Row("Locked screen") {
                Toggle("Pause while the screen is locked", isOn: $model.settings.pauseWhenLocked).toggleStyle(
                    .tapeCheckbox)
            }
            Row("Recording indicator") {
                note(
                    "The menu bar dot is always shown while recording; it cannot be hidden. macOS also shows its own microphone indicator."
                )
            }
            Row("Data") {
                note(
                    "Tapeloop sends nothing anywhere. Its only network connection is the speech-model download, made only when you press Download. Recordings and transcripts are ordinary files in your save folder. The buffer is in memory (and, only if you allow it, a private folder on disk erased on quit)."
                )
            }
        }

        private func note(_ text: String) -> some View {
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
        }

        private func addApp() {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowsMultipleSelection = true
            panel.prompt = "Exclude"
            panel.message = "Choose apps whose sound Tapeloop should not record."
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK else { return }
            for url in panel.urls {
                guard let id = Bundle(url: url)?.bundleIdentifier, id != TapeloopInfo.bundleIdentifier,
                    !model.settings.excludedBundleIDs.contains(id)
                else { continue }
                model.settings.excludedBundleIDs.append(id)
            }
        }
    }

    // MARK: - About

    struct AboutTab: View {
        var body: some View {
            VStack(spacing: 12) {
                AppIconView(size: 96)
                Wordmark(height: 34)
                Text("Version \(TapeloopInfo.version) (\(TapeloopInfo.build))").font(.system(size: 12)).foregroundStyle(
                    .secondary)
                Text(
                    "Record the past: the last minutes of your microphone and your Mac's sound, kept in memory, saved when it matters."
                )
                .font(.system(size: 13)).multilineTextAlignment(.center).frame(maxWidth: 380)
                HStack(spacing: 8) {
                    link("GitHub", TapeloopInfo.repositoryURL)
                    link("Report an Issue", TapeloopInfo.repositoryURL.appendingPathComponent("issues/new"))
                    link("Licence (MIT)", TapeloopInfo.repositoryURL.appendingPathComponent("blob/main/LICENSE"))
                }
                link(
                    "Third-Party Notices",
                    TapeloopInfo.repositoryURL.appendingPathComponent("blob/main/THIRD_PARTY_NOTICES.md"))
                Text("Transcription uses transcribe.cpp (MIT) and NVIDIA Parakeet (CC-BY-4.0).").font(
                    .system(size: 11.5)
                )
                .foregroundStyle(.secondary)
                Text("Open source. Made by Harsha and contributors.").font(.system(size: 11.5)).foregroundStyle(
                    .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }

        private func link(_ title: String, _ url: URL) -> some View {
            Button(title) { NSWorkspace.shared.open(url) }.buttonStyle(.tape)
        }
    }

    /// The app icon drawn in SwiftUI (the cassette on a graphite tile), for About and the first-run guide.
    public struct AppIconView: View {
        let size: CGFloat

        /// Creates the icon `size` points square.
        public init(size: CGFloat) {
            self.size = size
        }

        public var body: some View {
            // The tile is 824/1024 of the canvas, as in the real icon; corner 185/824 of the tile.
            let tile = size * 824 / 1024
            ZStack {
                RoundedRectangle(cornerRadius: tile * 185 / 824, style: .continuous).fill(Tape.graphite)
                RoundedRectangle(cornerRadius: tile * 185 / 824, style: .continuous).strokeBorder(
                    Color.white.opacity(0.1), lineWidth: max(0.5, size / 256))
                CassetteShape().fill(
                    Color(red: 244 / 255, green: 244 / 255, blue: 245 / 255), style: FillStyle(eoFill: true)
                )
                .frame(width: tile * 640 / 824, height: tile * 640 / 824 * 13.2 / 20.8)
            }
            .frame(width: tile, height: tile)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }

    /// The Tapeloop wordmark from the bundled SVG, tinted for the current appearance.
    public struct Wordmark: View {
        let height: CGFloat
        @Environment(\.colorScheme) private var scheme

        /// Creates the wordmark `height` points tall.
        public init(height: CGFloat) {
            self.height = height
        }

        public var body: some View {
            if let image = Self.image(dark: scheme == .dark) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(
                    height: height
                )
                .accessibilityLabel("Tapeloop")
            } else {
                Text("tapeloop").font(.system(size: height * 0.8, weight: .bold))
            }
        }

        /// The SVG from the app bundle (Contents/Resources) or, when run from SwiftPM, the repository.
        static func image(dark: Bool) -> NSImage? {
            let name = dark ? "wordmark-on-dark" : "wordmark-on-light"
            if let url = Bundle.main.url(forResource: name, withExtension: "svg"), let image = NSImage(contentsOf: url)
            {
                return image
            }
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Brand/\(name).svg")
            return NSImage(contentsOf: repo)
        }
    }
#endif
