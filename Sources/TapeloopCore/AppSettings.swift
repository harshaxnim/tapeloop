import Foundation

/// Everything the user can set in Tapeloop's Settings window. Stored as JSON in the app's defaults.
///
/// New fields must have defaults in `init(from:)`, so settings written by an older version still load.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Recording and buffer settings, used by the recorder engine.
    public var recorder: RecorderSettings
    /// Global keyboard shortcuts.
    public var shortcuts: Shortcuts
    /// How many minutes the "save" shortcut saves.
    public var shortcutSaveMinutes: Int
    /// Ask before quitting (quitting erases the buffer).
    public var warnOnQuit: Bool
    /// Pause recording while the screen is locked.
    public var pauseWhenLocked: Bool
    /// The microphone's device UID; `nil` follows the system default input.
    public var inputDeviceUID: String?
    /// Apps whose sound is left out of the system audio, by bundle identifier.
    public var excludedBundleIDs: [String]
    /// Meeting detection and calendar options.
    public var meetings: MeetingSettings
    /// Transcription options.
    public var transcription: TranscriptionSettings
    /// Whether the first-run guide was completed.
    public var onboardingDone: Bool

    /// The defaults.
    public init(
        recorder: RecorderSettings = RecorderSettings(), shortcuts: Shortcuts = Shortcuts(),
        shortcutSaveMinutes: Int = 5,
        warnOnQuit: Bool = true, pauseWhenLocked: Bool = false, inputDeviceUID: String? = nil,
        excludedBundleIDs: [String] = [], meetings: MeetingSettings = MeetingSettings(),
        transcription: TranscriptionSettings = TranscriptionSettings(), onboardingDone: Bool = false
    ) {
        self.recorder = recorder
        self.shortcuts = shortcuts
        self.shortcutSaveMinutes = shortcutSaveMinutes
        self.warnOnQuit = warnOnQuit
        self.pauseWhenLocked = pauseWhenLocked
        self.inputDeviceUID = inputDeviceUID
        self.excludedBundleIDs = excludedBundleIDs
        self.meetings = meetings
        self.transcription = transcription
        self.onboardingDone = onboardingDone
    }

    public init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recorder = try c.decodeIfPresent(RecorderSettings.self, forKey: .recorder) ?? d.recorder
        shortcuts = try c.decodeIfPresent(Shortcuts.self, forKey: .shortcuts) ?? d.shortcuts
        shortcutSaveMinutes = try c.decodeIfPresent(Int.self, forKey: .shortcutSaveMinutes) ?? d.shortcutSaveMinutes
        warnOnQuit = try c.decodeIfPresent(Bool.self, forKey: .warnOnQuit) ?? d.warnOnQuit
        pauseWhenLocked = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenLocked) ?? d.pauseWhenLocked
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? d.excludedBundleIDs
        meetings = try c.decodeIfPresent(MeetingSettings.self, forKey: .meetings) ?? d.meetings
        transcription = try c.decodeIfPresent(TranscriptionSettings.self, forKey: .transcription) ?? d.transcription
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? d.onboardingDone
    }
}

/// A keyboard shortcut: a key code plus modifiers, in Carbon terms (so it can be registered as a global hot key).
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    /// The virtual key code (for example 1 for "S").
    public var keyCode: UInt32
    /// Carbon modifier flags (cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096).
    public var modifiers: UInt32
    /// The key's character as shown to the user, for example "S".
    public var key: String

    /// Creates a combo.
    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// The symbols as macOS shows them, in its order: ⌃⌥⇧⌘ then the key.
    public var display: String {
        var text = ""
        if modifiers & 4096 != 0 { text += "⌃" }
        if modifiers & 2048 != 0 { text += "⌥" }
        if modifiers & 512 != 0 { text += "⇧" }
        if modifiers & 256 != 0 { text += "⌘" }
        return text + key.uppercased()
    }

    /// Control + Option + key.
    public static func controlOption(_ keyCode: UInt32, _ key: String) -> KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: 4096 | 2048, key: key)
    }
}

/// The global shortcuts. `nil` means none.
public struct Shortcuts: Codable, Equatable, Sendable {
    /// Save the last N minutes (⌃⌥S).
    public var save: KeyCombo?
    /// Bookmark this moment (⌃⌥B).
    public var bookmark: KeyCombo?
    /// Pause or resume (⌃⌥P).
    public var pause: KeyCombo?
    /// Open the popover (none by default).
    public var openPopover: KeyCombo?

    /// The defaults: ⌃⌥S, ⌃⌥B, ⌃⌥P.
    public init(
        save: KeyCombo? = .controlOption(1, "S"), bookmark: KeyCombo? = .controlOption(11, "B"),
        pause: KeyCombo? = .controlOption(35, "P"), openPopover: KeyCombo? = nil
    ) {
        self.save = save
        self.bookmark = bookmark
        self.pause = pause
        self.openPopover = openPopover
    }
}

/// Meeting detection and calendar options.
public struct MeetingSettings: Codable, Equatable, Sendable {
    /// Notice when a meeting app uses the microphone.
    public var detect: Bool
    /// When a meeting ends, offer to save it in a notification.
    public var offerToSave: Bool
    /// When a meeting ends, save it without asking.
    public var autoSave: Bool
    /// Show meetings as bands on the timeline.
    public var showOnTimeline: Bool
    /// Use calendar event titles (needs the Calendar permission).
    public var useCalendar: Bool
    /// The calendars to use, by identifier; empty means all.
    public var calendarIDs: [String]

    /// The defaults: detect, offer to save, show on the timeline; calendar off until allowed.
    public init(
        detect: Bool = true, offerToSave: Bool = true, autoSave: Bool = false, showOnTimeline: Bool = true,
        useCalendar: Bool = false, calendarIDs: [String] = []
    ) {
        self.detect = detect
        self.offerToSave = offerToSave
        self.autoSave = autoSave
        self.showOnTimeline = showOnTimeline
        self.useCalendar = useCalendar
        self.calendarIDs = calendarIDs
    }
}

/// Which speech recognizer transcribes recordings.
public enum TranscriptionEngine: String, Codable, CaseIterable, Sendable {
    /// NVIDIA Parakeet through transcribe.cpp, from a model the user downloads (English).
    case parakeet
    /// Apple's on-device speech recognition (needs the Speech Recognition permission; many languages).
    case apple
}

/// When recordings are transcribed.
public enum TranscriptionMode: String, Codable, CaseIterable, Sendable {
    /// Right after each save (the model is loaded for the job, then released).
    case afterSave
    /// Continuously while recording, kept in memory beside the audio, so a save includes its transcript at once.
    case live
    /// Only when the user asks, from the Library.
    case manual
}

/// Transcription options.
public struct TranscriptionSettings: Codable, Equatable, Sendable {
    /// Transcribe recordings at all.
    public var enabled: Bool
    /// The recognizer.
    public var engine: TranscriptionEngine
    /// When to transcribe.
    public var mode: TranscriptionMode
    /// The recognition locale identifier for the Apple engine, for example "en-US"; `nil` uses the system language.
    public var localeID: String?
    /// Label lines as You or System using the two sources.
    public var labelSpeakers: Bool

    /// The defaults: off until a model is downloaded (or the Speech permission is given); Parakeet; after each save;
    /// system language; labelled.
    public init(
        enabled: Bool = false, engine: TranscriptionEngine = .parakeet, mode: TranscriptionMode = .afterSave,
        localeID: String? = nil, labelSpeakers: Bool = true
    ) {
        self.enabled = enabled
        self.engine = engine
        self.mode = mode
        self.localeID = localeID
        self.labelSpeakers = labelSpeakers
    }

    /// Whether a save starts transcription by itself (after each save, or live with a fallback to after-save).
    public var automatic: Bool { mode != .manual }

    private enum CodingKeys: String, CodingKey {
        case enabled, engine, mode, localeID, labelSpeakers, automatic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TranscriptionSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        localeID = try c.decodeIfPresent(String.self, forKey: .localeID)
        labelSpeakers = try c.decodeIfPresent(Bool.self, forKey: .labelSpeakers) ?? d.labelSpeakers
        if let engine = try c.decodeIfPresent(TranscriptionEngine.self, forKey: .engine) {
            self.engine = engine
        } else {
            // Settings from before Parakeet: transcription meant Apple's recognizer.
            engine = c.contains(.enabled) ? .apple : d.engine
        }
        if let mode = try c.decodeIfPresent(TranscriptionMode.self, forKey: .mode) {
            self.mode = mode
        } else {
            let automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? true
            mode = automatic ? .afterSave : .manual
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(engine, forKey: .engine)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(localeID, forKey: .localeID)
        try c.encode(labelSpeakers, forKey: .labelSpeakers)
    }
}
