#if os(macOS)
    import Foundation
    import TapeloopCore

    extension LibraryModel {
        /// A Library with realistic sample recordings, for snapshots and previews. It never touches the disk.
        ///
        /// "Today" is Tuesday, 17 November 2026 in `calendar`'s time zone. "Weekly sync" (a 36-minute Zoom meeting
        /// with a transcript and a bookmark) is selected, paused at 13:02, at 1.5× speed.
        /// - Parameters:
        ///   - query: The search text; the default, "deck", highlights matches in the transcript. Pass "" for the
        ///     full list.
        ///   - calendar: The calendar and time zone for dates.
        ///   - transcribing: Whether "Weekly sync" is shown as being transcribed (with no transcript yet).
        public static func sample(
            query: String = "deck", calendar: Calendar = .current, transcribing: Bool = false
        ) -> LibraryModel {
            func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
                calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))
                    ?? Date(timeIntervalSince1970: 1_794_900_000)
            }
            let folder = URL(fileURLWithPath: "/Users/Shared/Tapeloop", isDirectory: true)
            func recording(
                _ title: String, _ start: Date, minutes: Double, app: String? = nil, calendarTitle: Bool = false,
                bookmarks: [RecordingBookmark] = [], lines: [(TimeInterval, SourceKind, String)] = []
            ) -> LibraryRecording {
                let duration = minutes * 60
                let meeting = app.map { MeetingInfo(appName: $0, calendarTitle: calendarTitle ? title : nil) }
                let transcript =
                    lines.isEmpty
                    ? nil
                    : Transcript(
                        locale: "en-US", createdAt: start.addingTimeInterval(duration + 120),
                        segments: lines.enumerated().map { index, line in
                            let end = index + 1 < lines.count ? lines[index + 1].0 : line.0 + 12
                            return TranscriptSegment(start: line.0, end: end, speaker: line.1, text: line.2)
                        })
                let metadata = RecordingMetadata(
                    title: calendarTitle ? nil : title, start: start, duration: duration,
                    sources: app == nil ? [.microphone] : [.microphone, .system], mixed: app != nil, meeting: meeting,
                    bookmarks: bookmarks, transcript: transcript)
                let name = RecordingName.make(
                    start: start, duration: duration, title: title, timeZone: calendar.timeZone)
                return LibraryRecording(
                    url: folder.appendingPathComponent(name), metadata: metadata,
                    fileSize: Int(duration * (app == nil ? 3_000 : 5_940)), modified: start.addingTimeInterval(duration)
                )
            }

            let weeklySync = recording(
                "Weekly sync", date(17, 10, 48), minutes: 2170 / 60, app: "Zoom", calendarTitle: true,
                bookmarks: [RecordingBookmark(offset: 1420, label: "decision")],
                lines: [
                    (751, .system, "Okay, so the release is Friday. Does anyone have blockers?"),
                    (782, .microphone, "Only the onboarding copy. I will send the updated deck tonight."),
                    (800, .system, "Great. Can you also put the pricing slide back in the deck?"),
                    (821, .microphone, "Yes, with the numbers from last week."),
                    (845, .system, "Perfect. Next item is the migration plan…"),
                    (872, .system, "Marco, where are we with the database move?"),
                    (889, .microphone, "The staging copy finished last night. I would like a second pair of eyes."),
                    (915, .system, "I can look at it tomorrow morning."),
                ])
            let items = [
                weeklySync,
                recording("Idea for the onboarding", date(17, 11, 24), minutes: 2),
                recording(
                    "Call with Priya", date(17, 9, 12), minutes: 14, app: "FaceTime",
                    lines: [(65, .system, "Did you get a chance to look at the investor deck?")]),
                recording(
                    "Design review", date(16, 16, 5), minutes: 52, app: "Google Meet", calendarTitle: true,
                    lines: [(140, .system, "The last section of the deck still uses the old colours.")]),
                recording("Voice note", date(16, 13, 40), minutes: 1),
                recording("Lecture: Signals, week 9", date(16, 9, 0), minutes: 58),
                recording(
                    "Standup", date(13, 9, 30), minutes: 15, app: "Microsoft Teams", calendarTitle: true,
                    lines: [(30, .microphone, "Yesterday I finished the deck for the sales team.")]),
                recording("Brainstorm", date(13, 15, 10), minutes: 24),
            ]
            let model = LibraryModel(recordings: items, now: date(17, 11, 40), calendar: calendar)
            model.query = query
            model.select(weeklySync.url)
            model.player.rate = 1.5
            model.player.preview(url: weeklySync.url, currentTime: 782, duration: 2170)
            if transcribing {
                if let index = model.recordings.firstIndex(where: { $0.url == weeklySync.url }) {
                    model.recordings[index].metadata?.transcript = nil
                }
                model.transcribing = [weeklySync.url]
            }
            return model
        }
    }
#endif
