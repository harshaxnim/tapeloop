#if os(macOS)
    import Foundation
    import Observation
    import TapeloopCore

    /// Everything the popover shows, as plain values. The app builds it from the recorder; snapshots build it from
    /// sample data.
    public struct PopoverState: Equatable, Sendable {
        /// The headline state (it also picks the status dot's colour).
        public var status: RecorderStatus
        /// The headline, for example "Recording".
        public var title: String
        /// How much is kept, for example "2 h".
        public var stat: String?
        /// The line under the headline.
        public var subtitle: String?
        /// A banner between the headline and the timeline.
        public var banner: Banner?
        /// The timeline's content.
        public var timeline: TimelineData
        /// Whether the user paused recording (the tool row shows Resume).
        public var isPaused: Bool
        /// The save in progress, if any.
        public var saving: Saving?
        /// The preview playing, if any.
        public var preview: Preview?

        /// Creates a state.
        public init(
            status: RecorderStatus, title: String, stat: String? = nil, subtitle: String? = nil, banner: Banner? = nil,
            timeline: TimelineData, isPaused: Bool = false, saving: Saving? = nil, preview: Preview? = nil
        ) {
            self.status = status
            self.title = title
            self.stat = stat
            self.subtitle = subtitle
            self.banner = banner
            self.timeline = timeline
            self.isPaused = isPaused
            self.saving = saving
            self.preview = preview
        }

        /// A preview of the selected span: played from the handle towards now, without saving.
        public struct Preview: Equatable, Sendable {
            /// Seconds heard so far.
            public var elapsed: TimeInterval
            /// The length of the span being previewed.
            public var duration: TimeInterval

            /// Creates a value.
            public init(elapsed: TimeInterval, duration: TimeInterval) {
                self.elapsed = elapsed
                self.duration = duration
            }

            /// How far through the span the preview is, 0 to 1.
            public var fraction: Double { duration > 0 ? min(1, max(0, elapsed / duration)) : 0 }
        }

        /// A banner above the timeline.
        public enum Banner: Equatable, Sendable {
            /// A meeting is going on: offer to save it.
            case meeting(id: UUID, title: String, detail: String, calendarTitle: String?)
            /// A source cannot record: say what and how to fix it.
            case problem(message: String, fixLabel: String?, alternativeLabel: String?)
            /// Disk use is on and part of the buffer is on disk.
            case info(String)
        }

        /// A save in progress.
        public struct Saving: Equatable, Sendable {
            /// For example "Saving 1 h 00 min…".
            public var label: String
            /// 0 to 1.
            public var progress: Double

            /// Creates a saving state.
            public init(label: String, progress: Double) {
                self.label = label
                self.progress = progress
            }
        }
    }

    /// The timeline: what the buffer holds between `start` (the oldest audio) and `end` (now).
    public struct TimelineData: Equatable, Sendable {
        /// The left edge of the axis.
        public var start: Date
        /// The right edge (now).
        public var end: Date
        /// Where audio actually begins (may be later than `start` right after launch).
        public var heldStart: Date?
        /// One lane per source: a label and peak levels (0 to 1, or -1 where there is no audio) in equal bins.
        public var lanes: [Lane]
        /// Detected meetings.
        public var meetings: [Span]
        /// Bookmarks.
        public var bookmarks: [Mark]
        /// Stretches inside the buffer with no audio (sleep, pause).
        public var gaps: [Span]

        /// Creates timeline data.
        public init(
            start: Date, end: Date, heldStart: Date? = nil, lanes: [Lane] = [], meetings: [Span] = [],
            bookmarks: [Mark] = [], gaps: [Span] = []
        ) {
            self.start = start
            self.end = end
            self.heldStart = heldStart
            self.lanes = lanes
            self.meetings = meetings
            self.bookmarks = bookmarks
            self.gaps = gaps
        }

        /// The axis length in seconds.
        public var span: TimeInterval { max(1, end.timeIntervalSince(start)) }
        /// The seconds of audio available to save.
        public var held: TimeInterval { heldStart.map { max(0, end.timeIntervalSince($0)) } ?? 0 }

        /// A lane of levels.
        public struct Lane: Equatable, Sendable {
            /// "You" or "System".
            public var label: String
            /// Peak levels per bin, 0 to 1; -1 where there is no audio.
            public var levels: [Float]

            /// Creates a lane.
            public init(label: String, levels: [Float]) {
                self.label = label
                self.levels = levels
            }
        }

        /// A span on the axis.
        public struct Span: Equatable, Sendable {
            /// The start.
            public var start: Date
            /// The end.
            public var end: Date
            /// An optional label ("Zoom · 10:41").
            public var label: String?

            /// Creates a span.
            public init(start: Date, end: Date, label: String? = nil) {
                self.start = start
                self.end = end
                self.label = label
            }
        }

        /// A bookmark flag.
        public struct Mark: Equatable, Sendable {
            /// When.
            public var date: Date
            /// Its label.
            public var label: String?

            /// Creates a mark.
            public init(date: Date, label: String? = nil) {
                self.date = date
                self.label = label
            }
        }

        /// Bins peak levels from chunk level tracks into `count` equal bins between `start` and `end`.
        public static func bin(
            _ track: [(start: Date, duration: TimeInterval, levels: [Float])], from start: Date, to end: Date,
            count: Int
        ) -> [Float] {
            var bins = [Float](repeating: -1, count: count)
            let span = max(1, end.timeIntervalSince(start))
            for piece in track {
                guard !piece.levels.isEmpty else { continue }
                let step = piece.duration / Double(piece.levels.count)
                for (index, level) in piece.levels.enumerated() {
                    let t = piece.start.addingTimeInterval(Double(index) * step + step / 2)
                    let f = t.timeIntervalSince(start) / span
                    guard f >= 0, f < 1 else { continue }
                    let bin = min(count - 1, Int(f * Double(count)))
                    bins[bin] = max(bins[bin], level)
                }
            }
            return bins
        }

        /// The stretches longer than `minimum` seconds between consecutive pieces (and across all tracks).
        public static func gaps(
            in tracks: [[(start: Date, duration: TimeInterval, levels: [Float])]], minimum: TimeInterval = 8
        ) -> [Span] {
            let spans = tracks.flatMap { $0 }.map { ($0.start, $0.start.addingTimeInterval($0.duration)) }
                .sorted { $0.0 < $1.0 }
            var result: [Span] = []
            var covered: Date?
            for (start, end) in spans {
                if let edge = covered, start.timeIntervalSince(edge) > minimum {
                    result.append(Span(start: edge, end: start))
                }
                covered = max(covered ?? end, end)
            }
            return result
        }

        /// A "nice" axis length (5 min, 15 min, 30 min, 1 h, 2 h, …) that holds `held` seconds.
        public static func niceSpan(for held: TimeInterval, maximum: TimeInterval) -> TimeInterval {
            let steps: [TimeInterval] = [5, 10, 15, 30, 60, 90, 120, 180, 240, 300, 480, 600, 720].map { $0 * 60 }
            let fit = steps.first { $0 >= held } ?? held
            return max(min(fit, max(maximum, held)), 60)
        }
    }

    /// What the popover's buttons do. The app supplies the closures.
    public struct PopoverActions {
        /// Save the last `seconds` seconds.
        public var save: (TimeInterval) -> Void = { _ in }
        /// Cancel the save in progress.
        public var cancelSave: () -> Void = {}
        /// Play the last `seconds` seconds without saving, or stop the preview that is playing.
        public var togglePreview: (TimeInterval) -> Void = { _ in }
        /// Pause or resume.
        public var togglePause: () -> Void = {}
        /// Drop a bookmark now; returns its time.
        public var bookmark: () -> Date? = { nil }
        /// Label the bookmark made at a time.
        public var labelBookmark: (Date, String) -> Void = { _, _ in }
        /// Save the meeting with this id.
        public var saveMeeting: (UUID) -> Void = { _ in }
        /// The banner's fix button (for example "Open System Settings").
        public var fixProblem: () -> Void = {}
        /// The banner's alternative button (for example "Record microphone only").
        public var problemAlternative: () -> Void = {}
        /// Open the Library window.
        public var openLibrary: () -> Void = {}
        /// Open Settings.
        public var openSettings: () -> Void = {}

        /// Creates empty actions.
        public init() {}
    }

    /// The popover's live model.
    @MainActor
    @Observable
    public final class PopoverModel {
        /// What to show.
        public var state: PopoverState
        /// How far back the selection reaches, in seconds (the handle's position).
        public var selection: TimeInterval
        /// The quick span that set the selection, if any (it shows as the highlighted chip).
        public var quickMinutes: Int?
        /// Whether the handle was dragged to (or past) the oldest audio: the selection is then everything held, and
        /// it follows the oldest audio as recording continues instead of staying at a fixed time.
        public var pinnedToOldest = false
        /// The bookmark waiting for an optional label, if any.
        public var pendingBookmark: Date?
        /// The label being typed for it.
        public var bookmarkLabel = ""
        /// What the buttons do.
        @ObservationIgnored public var actions = PopoverActions()
        /// Where the timeline is drawn, in the popover's coordinates (top-left origin). Set by the view; UI tests use it
        /// to aim pointer events.
        @ObservationIgnored public var timelineFrame: CGRect = .zero
        /// Where each control is drawn (same coordinates), by a stable name such as "save" or "chip-15".
        @ObservationIgnored public var controlFrames: [String: CGRect] = [:]

        /// The quick spans, in minutes.
        public static let quickSpans = [5, 15, 30, 60]

        /// Creates the model.
        public init(state: PopoverState, selection: TimeInterval = 300) {
            self.state = state
            self.selection = selection
            self.quickMinutes = 5
        }

        /// The shortest selection, in seconds (or everything held, when less is held).
        public static let minimumSelection: TimeInterval = 5

        /// The seconds that Save saves: the selection clamped to what is held, at least ``minimumSelection``; all of
        /// it while ``pinnedToOldest``.
        public var clampedSelection: TimeInterval {
            let held = max(1, state.timeline.held)
            if pinnedToOldest { return held }
            return min(held, max(Self.minimumSelection, selection))
        }

        /// Sets the selection from a quick span.
        /// Whether a bookmark can be added now (not while paused).
        public var canBookmark: Bool { !state.isPaused && state.status != .paused }

        /// Whether the quick span of `minutes` can be chosen: something is held and, except for the shortest span, the
        /// tape is long enough (within 30 seconds).
        public func quickSpanAvailable(_ minutes: Int) -> Bool {
            let held = state.timeline.held
            return held > 0 && (minutes == Self.quickSpans[0] || Double(minutes) * 60 <= held + 30)
        }

        /// Stops a playing preview (moving the selection ends it).
        public func stopPreview() {
            if state.preview != nil { actions.togglePreview(0) }
        }

        public func choose(minutes: Int) {
            stopPreview()
            quickMinutes = minutes
            pinnedToOldest = false
            selection = Double(minutes) * 60
        }

        /// Sets the selection by dragging (or the keyboard). Reaching what is held pins the selection to the oldest
        /// audio; `pin` forces that (the handle was dragged past the oldest audio).
        public func drag(to seconds: TimeInterval, pin: Bool = false) {
            stopPreview()
            quickMinutes = nil
            let held = state.timeline.held
            pinnedToOldest = held > 0 && (pin || seconds >= held)
            selection = pinnedToOldest ? held : max(Self.minimumSelection, seconds)
        }

        /// Drops a bookmark and opens the label field.
        public func bookmark() {
            guard canBookmark, let date = actions.bookmark() else { return }
            pendingBookmark = date
            bookmarkLabel = ""
        }

        /// Saves the typed label (if any) and closes the field.
        public func commitBookmark() {
            if let date = pendingBookmark {
                let label = bookmarkLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty { actions.labelBookmark(date, label) }
            }
            pendingBookmark = nil
            bookmarkLabel = ""
        }
    }

    /// Short human labels for durations.
    public enum DurationText {
        /// "45 s", "12 min", "1 h 05".
        public static func short(_ seconds: TimeInterval) -> String {
            let s = Int(seconds.rounded())
            if s < 60 { return "\(s) s" }
            let m = s / 60
            if m < 60 { return "\(m) min" }
            return String(format: "%d h %02d", m / 60, m % 60)
        }

        /// A clock reading: "0:07", "11:31", "1:05:09".
        public static func clock(_ seconds: TimeInterval) -> String {
            let s = max(0, Int(seconds.rounded(.down)))
            if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) }
            return String(format: "%d:%02d", s / 60, s % 60)
        }

        /// "45 seconds", "12 min", "1 h 5 min", "2 h".
        public static func long(_ seconds: TimeInterval) -> String {
            let s = Int(seconds.rounded())
            if s < 60 { return "\(s) seconds" }
            let m = s / 60
            if m < 60 { return "\(m) min" }
            return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
        }

        /// A tick label for `seconds` before now: "now", "−30 min", "−1 h 30", "−2 h".
        public static func tick(_ seconds: TimeInterval) -> String {
            let m = Int((seconds / 60).rounded())
            if m == 0 { return "now" }
            if m < 60 { return "−\(m) min" }
            return m % 60 == 0 ? "−\(m / 60) h" : String(format: "−%d h %02d", m / 60, m % 60)
        }
    }
#endif
