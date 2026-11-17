#if os(macOS)
    import Foundation
    import TapeloopCore

    /// TapeloopIntelligence: everything Tapeloop works out about the audio, on the Mac only.
    ///
    /// - Meeting detection: ``MeetingDetector`` watches which known apps (``MeetingApp/known``) use the microphone,
    ///   through Core Audio process objects (macOS 14.2+), and reports ``MeetingEvent``s.
    /// - Calendar: ``CalendarProvider`` names meetings after calendar events and lists events that just ended.
    /// - Transcription: ``TranscriptionService`` makes a `Transcript` with a ``Transcriber``; the shipped one is
    ///   ``AppleSpeechTranscriber`` (on-device `SFSpeechRecognizer`).
    ///
    /// Errors are ``IntelligenceError``s, whose descriptions can be shown to the user.
    public enum TapeloopIntelligenceModule {
        /// The module name, used in logs.
        public static let name = "TapeloopIntelligence"
    }
#endif
