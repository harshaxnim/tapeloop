import Foundation

/// What Tapeloop knows about a saved recording, beyond the audio file itself.
///
/// It is stored as JSON in a hidden folder next to the recordings (`<save folder>/.tapeloop/<file name>.json`), so
/// the audio files stay ordinary `.m4a` files the user can move, play or share anywhere. New fields must be optional
/// or have defaults in `init(from:)`, so files written by older versions still load.
public struct RecordingMetadata: Codable, Equatable, Sendable {
    /// The format version of this JSON.
    public var version: Int
    /// A title the user gave the recording; `nil` means "use the meeting title or the file name".
    public var title: String?
    /// The wall-clock time of the first sample.
    public var start: Date
    /// The length in seconds.
    public var duration: TimeInterval
    /// The sources in the file.
    public var sources: [SourceKind]
    /// Whether several sources were mixed into one track.
    public var mixed: Bool
    /// The meeting the recording belongs to, when one was detected.
    public var meeting: MeetingInfo?
    /// Bookmarks inside the recording.
    public var bookmarks: [RecordingBookmark]
    /// The on-device transcript, once made.
    public var transcript: Transcript?

    /// Creates metadata.
    public init(
        title: String? = nil, start: Date, duration: TimeInterval, sources: [SourceKind], mixed: Bool,
        meeting: MeetingInfo? = nil, bookmarks: [RecordingBookmark] = [], transcript: Transcript? = nil
    ) {
        self.version = 1
        self.title = title
        self.start = start
        self.duration = duration
        self.sources = sources
        self.mixed = mixed
        self.meeting = meeting
        self.bookmarks = bookmarks
        self.transcript = transcript
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        title = try c.decodeIfPresent(String.self, forKey: .title)
        start = try c.decode(Date.self, forKey: .start)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        sources = try c.decodeIfPresent([SourceKind].self, forKey: .sources) ?? []
        mixed = try c.decodeIfPresent(Bool.self, forKey: .mixed) ?? false
        meeting = try c.decodeIfPresent(MeetingInfo.self, forKey: .meeting)
        bookmarks = try c.decodeIfPresent([RecordingBookmark].self, forKey: .bookmarks) ?? []
        transcript = try c.decodeIfPresent(Transcript.self, forKey: .transcript)
    }
}

/// The meeting a recording came from.
public struct MeetingInfo: Codable, Equatable, Hashable, Sendable {
    /// The app's display name, for example "Zoom".
    public var appName: String
    /// The app's bundle identifier, when known.
    public var bundleID: String?
    /// The calendar event's title, when the calendar was used.
    public var calendarTitle: String?

    /// Creates meeting information.
    public init(appName: String, bundleID: String? = nil, calendarTitle: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.calendarTitle = calendarTitle
    }
}

/// A bookmark inside a saved recording.
public struct RecordingBookmark: Codable, Equatable, Hashable, Sendable {
    /// Seconds from the start of the recording.
    public var offset: TimeInterval
    /// The optional label.
    public var label: String?

    /// Creates a bookmark.
    public init(offset: TimeInterval, label: String? = nil) {
        self.offset = offset
        self.label = label
    }
}

/// A transcript made on this Mac.
public struct Transcript: Codable, Equatable, Sendable {
    /// The recognition language, for example "en-US".
    public var locale: String
    /// When it was made.
    public var createdAt: Date
    /// The lines, in time order.
    public var segments: [TranscriptSegment]

    /// Creates a transcript.
    public init(locale: String, createdAt: Date = Date(), segments: [TranscriptSegment]) {
        self.locale = locale
        self.createdAt = createdAt
        self.segments = segments
    }

    /// All the text, for search.
    public var text: String { segments.map(\.text).joined(separator: " ") }
}

/// One line of a transcript.
public struct TranscriptSegment: Codable, Equatable, Hashable, Sendable {
    /// Seconds from the start of the recording.
    public var start: TimeInterval
    /// Seconds from the start of the recording.
    public var end: TimeInterval
    /// Who spoke, when known from the source ("You" for the microphone, "System" for the other side).
    public var speaker: SourceKind?
    /// The words.
    public var text: String

    /// Creates a segment.
    public init(start: TimeInterval, end: TimeInterval, speaker: SourceKind? = nil, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

/// A meeting seen while recording: an app (Zoom, Teams, a browser call, …) used the microphone for a while.
public struct MeetingSpan: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// A stable id.
    public var id: UUID
    /// When it started.
    public var start: Date
    /// When it ended; `nil` while it is still going on.
    public var end: Date?
    /// The meeting's details.
    public var info: MeetingInfo

    /// Creates a span.
    public init(id: UUID = UUID(), start: Date, end: Date? = nil, info: MeetingInfo) {
        self.id = id
        self.start = start
        self.end = end
        self.info = info
    }

    /// Whether the meeting is still going on.
    public var isOngoing: Bool { end == nil }

    /// The span, using `now` for an ongoing meeting's end.
    public func range(now: Date = Date()) -> TimeRange { TimeRange(start: start, end: end ?? now) }

    /// The best label: the calendar title, else the app's name.
    public var label: String { info.calendarTitle ?? info.appName }
}
