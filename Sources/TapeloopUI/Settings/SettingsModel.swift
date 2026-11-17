#if os(macOS)
    import AppKit
    import Foundation
    import Observation
    import SwiftUI
    import TapeloopCore

    /// A permission's state, as Settings and the first-run guide show it.
    public enum PermissionState: Equatable, Sendable {
        /// Not asked yet.
        case notAsked
        /// Asked, but the answer cannot be read (system audio has no public query until sound is heard).
        case asked
        /// Allowed.
        case allowed
        /// Denied; only System Settings can change it.
        case denied
        /// Not available on this Mac (for example, macOS older than 14.2 for system audio).
        case unavailable
    }

    /// What Settings needs from the rest of the app: live facts and actions. The app fills it in; snapshots use
    /// `SettingsServices.sample`.
    @MainActor
    public struct SettingsServices {
        /// Input devices: (UID, name). The system default is shown separately.
        public var inputDevices: () -> [(uid: String, name: String)] = { [] }
        /// The name of the system's default input.
        public var defaultInputName: () -> String? = { nil }
        /// The live peak level (0 to 1) per source.
        public var levels: () -> [SourceKind: Float] = { [:] }
        /// The buffer's bytes in memory right now.
        public var bytesInRAM: () -> Int = { 0 }
        /// Permission state for the microphone, system audio, calendar and speech recognition.
        public var permission: (PermissionKind) -> PermissionState = { _ in .notAsked }
        /// Asks for a permission (shows macOS's prompt when it can).
        public var request: (PermissionKind) async -> Void = { _ in }
        /// Opens the right System Settings page.
        public var openSystemSettings: (PermissionKind) -> Void = { _ in }
        /// Whether Tapeloop opens at login, and a setter (returns an error message on failure).
        public var launchAtLogin: () -> Bool = { false }
        public var setLaunchAtLogin: (Bool) -> String? = { _ in nil }
        /// Calendars: (id, title, colour).
        public var calendars: () -> [(id: String, title: String, color: Color)] = { [] }
        /// Languages that can be transcribed on this Mac: (identifier, display name).
        public var transcriptionLanguages: () -> [(id: String, name: String)] = { [] }
        /// Apps that can be excluded (installed or running): (bundle ID, name, icon).
        public var appInfo: (String) -> (name: String, icon: NSImage?)? = { _ in nil }
        /// The shortcuts that another app holds.
        public var takenShortcuts: () -> Set<ShortcutAction> = { [] }
        /// The speech model: its name, its size ("731 MB"), its state, and actions.
        public var speechModelName = "Parakeet Unified English 0.6B (8-bit)"
        public var speechModelSize = "731 MB"
        public var speechModelStatus: () -> SpeechModelStatus = { .notInstalled }
        public var downloadSpeechModel: () -> Void = {}
        public var cancelSpeechModelDownload: () -> Void = {}
        public var deleteSpeechModel: () -> Void = {}
        public var importSpeechModel: () -> Void = {}
        /// Erases the buffer.
        public var eraseBuffer: () -> Void = {}
        /// Shows the first-run guide again.
        public var showWelcome: () -> Void = {}
        /// Pauses or resumes global shortcuts while one is being recorded.
        public var suspendShortcuts: (Bool) -> Void = { _ in }

        /// Creates empty services.
        public init() {}
    }

    /// The downloadable speech model's state, as Settings and the first-run guide show it.
    public enum SpeechModelStatus: Equatable, Sendable {
        case notInstalled
        /// 0 to 1.
        case downloading(Double)
        case verifying
        case installed
        /// The message says what went wrong.
        case failed(String)
    }

    /// The permissions Tapeloop uses.
    public enum PermissionKind: String, CaseIterable, Sendable {
        case microphone, systemAudio, calendar, speech
    }

    /// The four global shortcuts.
    public enum ShortcutAction: String, CaseIterable, Sendable {
        case save, bookmark, pause, openPopover

        /// The row label.
        public var label: String {
            switch self {
            case .save: "Save the last"
            case .bookmark: "Bookmark this moment"
            case .pause: "Pause or resume"
            case .openPopover: "Open the popover"
            }
        }
    }

    /// The Settings window's model.
    @MainActor
    @Observable
    public final class SettingsModel {
        /// The tabs, in order.
        public enum Tab: String, CaseIterable, Identifiable, Sendable {
            case general = "General"
            case recording = "Recording"
            case memory = "Memory"
            case shortcuts = "Shortcuts"
            case meetings = "Meetings"
            case transcripts = "Transcripts"
            case privacy = "Privacy"
            case about = "About"

            public var id: String { rawValue }

            /// The SF Symbol for the toolbar.
            public var symbol: String {
                switch self {
                case .general: "gearshape"
                case .recording: "mic"
                case .memory: "memorychip"
                case .shortcuts: "keyboard"
                case .meetings: "video"
                case .transcripts: "text.quote"
                case .privacy: "lock"
                case .about: "info.circle"
                }
            }
        }

        /// The settings being edited; every change is applied at once through `apply`.
        public var settings: AppSettings {
            didSet { if settings != oldValue { apply(settings) } }
        }
        /// The selected tab.
        public var tab: Tab = .general
        /// The shortcut being recorded, if any.
        public var recordingShortcut: ShortcutAction?
        /// A message to show next to launch at login when it could not be changed.
        public var launchError: String?
        /// Bumped every second while the window is open, so live values refresh.
        public var tick = 0
        /// Live facts and actions.
        @ObservationIgnored public var services: SettingsServices
        @ObservationIgnored private let apply: (AppSettings) -> Void

        /// Creates the model. `apply` receives every change.
        public init(settings: AppSettings, services: SettingsServices, apply: @escaping (AppSettings) -> Void) {
            self.settings = settings
            self.services = services
            self.apply = apply
        }

        /// The memory estimate for the chosen buffer and sources.
        public var budget: MemoryBudget { settings.recorder.budget }

        /// The combo for an action.
        public func combo(_ action: ShortcutAction) -> KeyCombo? {
            switch action {
            case .save: settings.shortcuts.save
            case .bookmark: settings.shortcuts.bookmark
            case .pause: settings.shortcuts.pause
            case .openPopover: settings.shortcuts.openPopover
            }
        }

        /// Sets (or clears) the combo for an action; a combo already used by another action moves.
        public func setCombo(_ combo: KeyCombo?, for action: ShortcutAction) {
            var shortcuts = settings.shortcuts
            if let combo {
                for other in ShortcutAction.allCases where other != action && self.combo(other) == combo {
                    Self.set(nil, other, in: &shortcuts)
                }
            }
            Self.set(combo, action, in: &shortcuts)
            settings.shortcuts = shortcuts
        }

        private static func set(_ combo: KeyCombo?, _ action: ShortcutAction, in shortcuts: inout Shortcuts) {
            switch action {
            case .save: shortcuts.save = combo
            case .bookmark: shortcuts.bookmark = combo
            case .pause: shortcuts.pause = combo
            case .openPopover: shortcuts.openPopover = combo
            }
        }
    }
#endif
