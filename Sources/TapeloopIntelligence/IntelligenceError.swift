#if os(macOS)
    import Foundation
    import TapeloopCore
    import os

    /// Loggers under the app's subsystem. Read them with
    /// `log show --predicate 'subsystem == "io.github.harshaxnim.tapeloop"' --last 10m`.
    enum Log {
        static let meetings = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "meetings")
        static let calendar = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "calendar")
        static let transcription = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "transcription")
    }

    /// Everything that can go wrong in meeting detection, the calendar and transcription, with a message that can be
    /// shown to the user as is.
    public enum IntelligenceError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
        /// The user denied (or a profile restricts) speech recognition.
        case speechNotAllowed
        /// Speech recognition has not been asked for yet.
        case speechNotRequested
        /// The language cannot be transcribed on this Mac (no on-device model, or not supported at all).
        case onDeviceUnavailable(language: String)
        /// The recognizer exists but is not available right now (for example while its model is being set up).
        case recognizerUnavailable(language: String)
        /// The audio file could not be opened or read.
        case unreadableAudio(fileName: String)
        /// The recognizer failed with this reason.
        case recognitionFailed(reason: String)
        /// The user denied calendar access, or it was never asked for.
        case calendarNotAllowed
        /// Meeting detection needs macOS 14.2 or later.
        case meetingDetectionUnsupported

        /// A plain-English message.
        public var description: String {
            switch self {
            case .speechNotAllowed:
                "Speech recognition is not allowed. Turn it on in System Settings › Privacy & Security › "
                    + "Speech Recognition."
            case .speechNotRequested:
                "Tapeloop has not been allowed to use speech recognition yet. Turn on transcription in Tapeloop's "
                    + "Settings to be asked."
            case .onDeviceUnavailable(let language):
                "On-device transcription is not available for \(language) on this Mac."
            case .recognizerUnavailable(let language):
                "Speech recognition for \(language) is not available right now. Try again in a moment."
            case .unreadableAudio(let fileName):
                "Tapeloop could not read the audio file “\(fileName)”."
            case .recognitionFailed(let reason):
                "Transcription failed: \(reason)"
            case .calendarNotAllowed:
                "Calendar access is not allowed. Turn it on in System Settings › Privacy & Security › Calendars."
            case .meetingDetectionUnsupported:
                "Meeting detection needs macOS 14.2 or later."
            }
        }

        /// The same message, for `localizedDescription`.
        public var errorDescription: String? { description }

        /// The language's name in the user's language, for example "English (United States)".
        static func languageName(_ locale: Locale) -> String {
            Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        }
    }
#endif
