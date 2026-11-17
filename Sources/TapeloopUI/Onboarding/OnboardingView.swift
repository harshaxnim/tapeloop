#if os(macOS)
    import AppKit
    import Observation
    import SwiftUI
    import TapeloopCore

    /// The first-run guide's model: five steps; permissions are asked from this visible window so macOS shows its
    /// prompts in front of the user.
    @MainActor
    @Observable
    public final class OnboardingModel {
        /// 1 to 5.
        public var step = 1
        /// Whether to open at login (on by default; applied when the guide finishes).
        public var launchAtLogin = true
        /// Bumped after a permission request, so states refresh.
        public var tick = 0
        /// The current shortcuts, for the last step.
        public var shortcuts: Shortcuts
        /// Live facts and actions (the same services Settings uses).
        @ObservationIgnored public var services: SettingsServices
        /// How many minutes the save shortcut saves.
        public var saveMinutes = 5
        /// Whether meeting detection is on.
        public var detectMeetings: Bool
        /// Called when the user finishes, with the launch-at-login and meeting-detection choices.
        @ObservationIgnored public var onFinish: (_ launchAtLogin: Bool, _ detectMeetings: Bool) -> Void = { _, _ in }

        /// Creates the model.
        public init(services: SettingsServices, shortcuts: Shortcuts = Shortcuts(), detectMeetings: Bool = true) {
            self.services = services
            self.shortcuts = shortcuts
            self.detectMeetings = detectMeetings
        }

        /// The state of a permission (re-read whenever `tick` changes).
        public func state(_ kind: PermissionKind) -> PermissionState {
            _ = tick
            return services.permission(kind)
        }

        /// Asks for a permission, then refreshes.
        public func request(_ kind: PermissionKind) {
            Task {
                await services.request(kind)
                tick += 1
            }
        }
    }

    /// The first-run guide (520 points wide).
    public struct OnboardingView: View {
        @Bindable var model: OnboardingModel

        /// Creates the guide.
        public init(model: OnboardingModel) {
            self.model = model
        }

        public var body: some View {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) { page }
                    .padding(.horizontal, 32).padding(.top, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
            }
            .frame(width: 520, height: 470)
        }

        @ViewBuilder private var page: some View {
            switch model.step {
            case 1: welcome
            case 2: microphone
            case 3: systemAudio
            case 4: extras
            default: done
            }
        }

        private var footer: some View {
            HStack {
                Button("Back") { model.step -= 1 }.buttonStyle(.tape).opacity(model.step > 1 ? 1 : 0).disabled(
                    model.step == 1)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { index in
                        Circle().fill(index == model.step ? Tape.amber : Color.primary.opacity(0.2)).frame(
                            width: 6, height: 6)
                    }
                }
                .accessibilityLabel("Step \(model.step) of 5")
                Spacer()
                if model.step == 3 && model.state(.systemAudio) != .allowed {
                    Button("Skip") { model.step += 1 }.buttonStyle(.tape)
                } else if model.step < 5 {
                    Button("Continue") { model.step += 1 }.buttonStyle(.tapePrimary).keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { model.onFinish(model.launchAtLogin, model.detectMeetings) }.buttonStyle(
                        .tapePrimary
                    )
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .overlay(Rectangle().fill(Tape.line).frame(height: 1), alignment: .top)
        }

        // MARK: Steps

        private var welcome: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    AppIconView(size: 88)
                    VStack(alignment: .leading, spacing: 6) {
                        Wordmark(height: 30)
                        Text("Record the past").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                Text(
                    "Tapeloop keeps the last minutes, or hours, of your microphone and your Mac's sound. When something worth keeping happens, you save it after the fact."
                )
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                promise(
                    "memorychip", "In memory only.",
                    "Audio is compressed and held in memory. Nothing touches the disk until you save.")
                promise(
                    "lock.shield", "Never uploaded.",
                    "Nothing you record leaves this Mac. The only download is the optional speech model, and only if you ask for it."
                )
                promise(
                    "info.circle", "Your responsibility.", "Recording others may need their consent where you live.")
            }
        }

        private func promise(_ symbol: String, _ title: String, _ text: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(Tape.amber).frame(width: 18)
                (Text(title).bold() + Text(" ") + Text(text).foregroundColor(.secondary)).font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private var microphone: some View {
            VStack(alignment: .leading, spacing: 14) {
                heading(
                    "Your microphone",
                    "To keep your side of conversations, Tapeloop needs the microphone. macOS asks you when you press Allow."
                )
                permissionRow(
                    .microphone, "mic", "Microphone", deniedText: "Denied earlier. Turn it on in System Settings.",
                    text: "Your voice, in calls and in the room")
            }
        }

        private var systemAudio: some View {
            VStack(alignment: .leading, spacing: 14) {
                heading(
                    "Your Mac's sound",
                    "To keep the other side of calls (and anything else the Mac plays), Tapeloop needs System Audio Recording. It does not need Screen Recording."
                )
                permissionRow(
                    .systemAudio, "speaker.wave.2", "System Audio Recording",
                    deniedText:
                        "Denied earlier. Turn it on in System Settings › Privacy & Security › Screen & System Audio Recording.",
                    text: "The other side of calls, videos, anything you hear")
                Text("You can skip this and record only the microphone.").font(.system(size: 12)).foregroundStyle(
                    .secondary)
            }
        }

        private var extras: some View {
            VStack(alignment: .leading, spacing: 14) {
                heading(
                    "Optional extras", "All of these run on this Mac. You can change them later in Settings.")
                permissionRow(
                    .calendar, "calendar", "Calendar", deniedText: nil,
                    text: "Name recordings after the meeting you were in")
                HStack(spacing: 12) {
                    Image(systemName: "text.quote").font(.system(size: 16)).foregroundStyle(Tape.amber).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcripts").font(.system(size: 13, weight: .semibold))
                        Text(
                            "Transcribe recordings on this Mac with NVIDIA Parakeet (English). A one-time download of \(model.services.speechModelSize) from Tapeloop's GitHub page."
                        )
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                    }
                    Spacer()
                    CompactModelControl(services: model.services)
                }
                .tapePanel()
                HStack(spacing: 12) {
                    Image(systemName: "video").font(.system(size: 16)).foregroundStyle(Tape.amber).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Meeting detection").font(.system(size: 13, weight: .semibold))
                        Text("Notice calls in Zoom, Teams, Meet and more").font(.system(size: 12)).foregroundStyle(
                            .secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.detectMeetings).toggleStyle(.tapeSwitch).labelsHidden()
                }
                .tapePanel()
            }
        }

        private var done: some View {
            VStack(alignment: .leading, spacing: 14) {
                heading(
                    "You are all set",
                    "When you press Done, Tapeloop starts recording to memory. Find it in the menu bar:")
                HStack(spacing: 10) {
                    Spacer()
                    Image(nsImage: CassetteIcon.image(for: .recording))
                    Text(Date().formatted(date: .omitted, time: .shortened)).font(.system(size: 13))
                    Spacer()
                }
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Tape.radius).fill(Tape.fill))
                VStack(alignment: .leading, spacing: 8) {
                    shortcut(model.shortcuts.save, "save the last \(model.saveMinutes) minutes")
                    shortcut(model.shortcuts.bookmark, "bookmark this moment")
                    shortcut(model.shortcuts.pause, "pause or resume")
                }
                Toggle("Open Tapeloop when I log in", isOn: $model.launchAtLogin).toggleStyle(.tapeCheckbox).padding(
                    .top, 4)
            }
        }

        @ViewBuilder private func shortcut(_ combo: KeyCombo?, _ text: String) -> some View {
            if let combo {
                HStack(spacing: 10) {
                    Text(combo.display).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .frame(width: 64).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: Tape.radius).fill(Tape.fill))
                        .overlay(RoundedRectangle(cornerRadius: Tape.radius).strokeBorder(Tape.line))
                    Text(text).font(.system(size: 13))
                }
            }
        }

        private func heading(_ title: String, _ text: String) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 20, weight: .bold))
                Text(text).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
        }

        private func permissionRow(
            _ kind: PermissionKind, _ symbol: String, _ title: String, deniedText: String?, text: String
        ) -> some View {
            let state = model.state(kind)
            return HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Tape.amber).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(state == .denied ? deniedText ?? text : text).font(.system(size: 12)).foregroundStyle(
                        .secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                PermissionBadge(
                    state: state, request: { model.request(kind) }, open: { model.services.openSystemSettings(kind) })
            }
            .tapePanel()
        }
    }

    /// The welcome screen's model control: Download, then progress, then Ready.
    struct CompactModelControl: View {
        let services: SettingsServices

        var body: some View {
            SwiftUI.TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                switch services.speechModelStatus() {
                case .notInstalled:
                    Button("Download") { services.downloadSpeechModel() }.buttonStyle(.tape)
                case .downloading(let fraction):
                    HStack(spacing: 6) {
                        Text("\(Int((fraction * 100).rounded())) %").font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button {
                            services.cancelSpeechModelDownload()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel the download")
                    }
                case .verifying:
                    ProgressView().controlSize(.small)
                case .installed:
                    Label("Ready", systemImage: "checkmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tape.green)
                case .failed(let message):
                    Button("Try Again") { services.downloadSpeechModel() }.buttonStyle(.tape).help(message)
                }
            }
        }
    }
#endif
