#if os(macOS)
    import CoreGraphics
    @preconcurrency import EventKit
    import Foundation
    import TapeloopCore

    /// A calendar the user can pick in Settings.
    public struct CalendarInfo: Hashable, Identifiable, Sendable {
        /// EventKit's calendar identifier (stored in `MeetingSettings.calendarIDs`).
        public var id: String
        /// The calendar's name.
        public var title: String
        /// The calendar's colour as `#RRGGBB` (sRGB).
        public var colorHex: String
        /// The account it belongs to, for example "iCloud" or a Google address.
        public var source: String

        /// Creates a value.
        public init(id: String, title: String, colorHex: String, source: String = "") {
            self.id = id
            self.title = title
            self.colorHex = colorHex
            self.source = source
        }
    }

    /// A calendar event reduced to what meeting matching needs. Plain data, so the matching can be unit-tested.
    public struct CalendarEvent: Hashable, Sendable {
        /// The event's title.
        public var title: String
        /// When it starts and ends.
        public var range: TimeRange
        /// Whether it is an all-day event (never a meeting).
        public var isAllDay: Bool

        /// Creates a value.
        public init(title: String, range: TimeRange, isAllDay: Bool = false) {
            self.title = title
            self.range = range
            self.isAllDay = isAllDay
        }
    }

    /// Reads calendar events (EventKit) to name meetings and to offer saving an event's span when it ends.
    ///
    /// Needs the Calendars "Full Access" permission (`NSCalendarsFullAccessUsageDescription`). Every method is
    /// safe to call from any thread; EventKit reads are synchronous, so call them off the main thread when the
    /// calendars are large.
    public final class CalendarProvider: @unchecked Sendable {
        private let storeLock = NSLock()
        private var _store: EKEventStore?
        /// Created on first use: an event store connects to the calendar service and holds memory, and most launches
        /// never need it.
        private var store: EKEventStore {
            storeLock.withLock {
                if let _store { return _store }
                let store = EKEventStore()
                _store = store
                return store
            }
        }

        /// Creates a provider. It does not ask for access.
        public init() {}

        /// Whether Tapeloop may read events. (`.authorized` is the deprecated name of `.fullAccess`, same value.)
        public static var isAuthorized: Bool {
            EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }

        /// Asks for full access to events (shows the system prompt the first time). Returns whether it was given.
        public func requestAccess() async -> Bool {
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                Log.calendar.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        /// The event calendars, sorted by account then name. Empty without access.
        public func calendars() -> [CalendarInfo] {
            guard Self.isAuthorized else { return [] }
            return store.calendars(for: .event)
                .map {
                    CalendarInfo(
                        id: $0.calendarIdentifier, title: $0.title, colorHex: Self.hex($0.cgColor),
                        source: $0.source?.title ?? "")
                }
                .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
        }

        /// The title of the timed event that best matches `range` (see ``bestMatch(for:among:)``), or `nil`.
        /// `calendarIDs` empty means all calendars.
        public func eventTitle(overlapping range: TimeRange, calendarIDs: [String]) -> String? {
            Self.bestMatch(for: range, among: events(in: range, calendarIDs: calendarIDs))?.title
        }

        /// The timed events that ended after `start` and at or before `end`, oldest end first. For "offer to save
        /// an event's span when it ends": poll with the previous poll's time as `start`.
        public func eventsEnded(between start: Date, and end: Date, calendarIDs: [String]) -> [(
            title: String, range: TimeRange
        )] {
            let window = TimeRange(start: start, end: end)
            return Self.ended(in: window, among: events(in: window, calendarIDs: calendarIDs)).map {
                (title: $0.title, range: $0.range)
            }
        }

        /// The event that best matches a meeting span: the timed event with the largest overlap, provided the overlap
        /// is at least half of the shorter of the two spans or at least 5 minutes. Ties go to the event whose start
        /// is closest to the span's start. All-day and untitled events never match.
        public static func bestMatch(for range: TimeRange, among events: [CalendarEvent]) -> CalendarEvent? {
            var best: (event: CalendarEvent, overlap: TimeInterval)?
            for event in events where !event.isAllDay && !event.title.isEmpty {
                guard let overlap = event.range.intersection(range)?.duration, overlap > 0 else { continue }
                let needed = min(min(event.range.duration, range.duration) * 0.5, 5 * 60)
                guard overlap >= needed else { continue }
                if let current = best {
                    let closer =
                        abs(event.range.start.timeIntervalSince(range.start))
                        < abs(current.event.range.start.timeIntervalSince(range.start))
                    guard overlap > current.overlap || (overlap == current.overlap && closer) else { continue }
                }
                best = (event, overlap)
            }
            return best?.event
        }

        /// The timed, titled events whose end lies in `window` (after its start, up to and including its end),
        /// oldest end first.
        public static func ended(in window: TimeRange, among events: [CalendarEvent]) -> [CalendarEvent] {
            events.filter {
                !$0.isAllDay && !$0.title.isEmpty && $0.range.end > window.start && $0.range.end <= window.end
            }
            .sorted { $0.range.end < $1.range.end }
        }

        private func events(in range: TimeRange, calendarIDs: [String]) -> [CalendarEvent] {
            guard Self.isAuthorized else { return [] }
            var calendars: [EKCalendar]?
            if !calendarIDs.isEmpty {
                let wanted = Set(calendarIDs)
                calendars = store.calendars(for: .event).filter { wanted.contains($0.calendarIdentifier) }
                if calendars?.isEmpty == true { return [] }
            }
            let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
            return store.events(matching: predicate).compactMap { event in
                guard event.status != .canceled, let start = event.startDate, let end = event.endDate else {
                    return nil
                }
                let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return CalendarEvent(title: title, range: TimeRange(start: start, end: end), isAllDay: event.isAllDay)
            }
        }

        private static func hex(_ color: CGColor?) -> String {
            guard let color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
                let parts = converted.components, parts.count >= 3
            else { return "#808080" }
            let byte = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
            return String(format: "#%02X%02X%02X", byte(parts[0]), byte(parts[1]), byte(parts[2]))
        }
    }
#endif
