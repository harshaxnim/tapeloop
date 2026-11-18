#if os(macOS)
    import AppKit
    import Foundation
    import SwiftUI
    import TapeloopCore

    /// Realistic sample content for snapshots, previews and documentation screenshots. Never used by the running app.
    public enum Samples {
        /// A fixed "now" so snapshots are stable: Tuesday 17 November 2026, 11:24.
        public static let now: Date = {
            var c = DateComponents()
            (c.year, c.month, c.day, c.hour, c.minute) = (2026, 11, 17, 11, 24)
            return Calendar(identifier: .gregorian).date(from: c) ?? Date(timeIntervalSince1970: 1_795_000_000)
        }()

        /// Deterministic pseudo-random levels (0 to 1) for a lane, with quiet stretches.
        static func levels(_ count: Int, seed: UInt64, base: Float, amplitude: Float, silent: [Range<Int>] = [])
            -> [Float]
        {
            var state = seed
            return (0..<count).map { index in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let noise = Float((state >> 33) % 1000) / 1000
                if silent.contains(where: { $0.contains(index) }) { return -1 }
                let wave = (sin(Float(index) * 0.45) * 0.5 + noise * 0.8 - 0.2) * amplitude
                return min(0.9, max(0.004, (base + wave) * 0.5))
            }
        }

        static func timeline(
            hours: Double = 2, held: Double? = nil, gaps: [(Double, Double)] = [(0.317, 0.375)],
            meetings: [(Double, Double, String?)] = [], marks: [(Double, String?)] = [], micSilent: [Range<Int>] = [],
            systemFlat: Bool = false
        ) -> TimelineData {
            let span = hours * 3600
            let start = now.addingTimeInterval(-span)
            let at = { (f: Double) in start.addingTimeInterval(f * span) }
            let n = 120
            let gapBins = gaps.map { Int($0.0 * Double(n))..<Int($0.1 * Double(n)) }
            let heldFrom = held.map { 1 - $0 / span } ?? 0
            let beforeHeld = 0..<Int(heldFrom * Double(n))
            let mic = levels(n, seed: 11, base: 0.25, amplitude: 0.5, silent: gapBins + micSilent + [beforeHeld])
            let system =
                systemFlat
                ? [Float](repeating: 0.004, count: n)
                : levels(n, seed: 23, base: 0.15, amplitude: 0.55, silent: gapBins + [0..<18, beforeHeld])
            return TimelineData(
                start: start, end: now, heldStart: at(heldFrom),
                lanes: [.init(label: "You", levels: mic), .init(label: "System", levels: system)],
                meetings: meetings.map { .init(start: at($0.0), end: at($0.1), label: $0.2) },
                bookmarks: marks.map { .init(date: at($0.0), label: $0.1) },
                gaps: gaps.map { .init(start: at($0.0), end: at($0.1)) })
        }

        /// The popover states shown in the documentation, with a short name each. ``selectSample(_:in:)`` adds the
        /// selection that a name implies (a clicked meeting, a trimmed end).
        public static func popoverStates() -> [(
            name: String, state: PopoverState, selection: TimeInterval, quick: Int?
        )] {
            let recording = PopoverState(
                status: .recording, title: "Recording", stat: "2 h",
                timeline: timeline(meetings: [(0.52, 0.86, "Zoom · 10:41")], marks: [(0.79, "decision"), (0.2, nil)]))
            var meeting = recording
            meeting.subtitle = nil
            meeting.banner = .meeting(
                id: UUID(), title: "Zoom meeting", detail: "38 min",
                calendarTitle: "Weekly sync")
            meeting.timeline = timeline(meetings: [(0.68, 1, "Zoom · now")])
            var saving = recording
            saving.subtitle = nil
            saving.saving = .init(label: "Saving 1 h 00 min…", progress: 0.64)
            var paused = PopoverState(
                status: .paused, title: "Paused", stat: "1 h 12 min",
                timeline: timeline(gaps: [(0.317, 0.375), (0.82, 1)], meetings: [(0.52, 0.6, nil)]), isPaused: true)
            paused.timeline.lanes = paused.timeline.lanes.map { lane in
                var lane = lane
                lane.levels = lane.levels.enumerated().map { $0.offset >= 98 ? -1 : $0.element }
                return lane
            }
            let started = PopoverState(
                status: .recording, title: "Recording", stat: "4 min",
                timeline: timeline(hours: 0.25, held: 240, gaps: []))
            let permission = PopoverState(
                status: .needsAttention, title: "System audio is not being recorded",
                banner: .problem(
                    message:
                        "Tapeloop needs the System Audio Recording permission to hear the other side of calls. Your microphone is still recorded.",
                    fixLabel: "Open System Settings", alternativeLabel: "Record microphone only"),
                timeline: timeline(gaps: [], systemFlat: true))
            let disk = PopoverState(
                status: .recording, title: "Recording", stat: "5 h",
                subtitle: "The older 1 h 20 min is on disk and is erased when Tapeloop quits.",
                timeline: timeline(hours: 5, meetings: [(0.52, 0.86, nil)]))
            var previewing = recording
            previewing.preview = .init(elapsed: 11 * 60 + 31, duration: 36 * 60)
            var trimmed = recording
            trimmed.timeline.bookmarks = [.init(date: Samples.now.addingTimeInterval(-0.8 * 7200), label: nil)]
            return [
                ("recording", recording, 36 * 60, nil), ("previewing", previewing, 36 * 60, nil),
                ("meeting", meeting, 38 * 60, nil), ("meeting-selected", recording, 36 * 60, nil),
                ("trimmed", trimmed, 36 * 60, nil),
                ("bookmark-hover", recording, 36 * 60, nil),
                ("saving", saving, 3600, 60),
                ("paused", paused, 45 * 60, nil), ("just-started", started, 240, 5),
                ("needs-permission", permission, 24 * 60, nil), ("disk", disk, 30 * 60, 30),
            ]
        }

        /// Sets the selection a sample's name implies: "meeting-selected" clicks the Zoom meeting; "trimmed" ends the
        /// selection 20 minutes before now.
        @MainActor
        public static func selectSample(_ name: String, in model: PopoverModel) {
            switch name {
            case "meeting-selected":
                if let meeting = model.state.timeline.meetings.first { model.selectMeeting(meeting) }
            case "bookmark-hover":
                model.timelineHover = CGPoint(x: 118, y: TimelineView.tapeHeight + 6)
            case "trimmed":
                model.drag(to: 50 * 60)
                model.dragEnd(to: now.addingTimeInterval(-14 * 60))
            default: break
            }
        }

        /// Settings services with realistic, fixed answers.
        @MainActor
        public static func services() -> SettingsServices {
            var services = SettingsServices()
            services.inputDevices = { [("builtin", "MacBook Pro Microphone"), ("usb", "Shure MV7")] }
            services.defaultInputName = { "MacBook Pro Microphone" }
            services.levels = { [.microphone: 0.2, .system: 0.06] }
            services.bytesInRAM = { 41_000_000 }
            services.permission = { kind in
                switch kind {
                case .microphone, .calendar: .allowed
                case .systemAudio: .allowed
                case .speech: .notAsked
                }
            }
            services.launchAtLogin = { true }
            services.calendars = {
                [("work", "Work", Tape.meeting), ("home", "Personal", Tape.green), ("hol", "Holidays", Tape.red)]
            }
            services.transcriptionLanguages = { [("en_US", "English (United States)")] }
            services.speechModelStatus = { .downloading(0.42) }
            services.appInfo = { id in
                [
                    "com.apple.Music": ("Music", NSWorkspace.shared.icon(forFile: "/System/Applications/Music.app")),
                    "com.spotify.client": ("Spotify", nil),
                ][id]
            }
            return services
        }

        /// Settings as a returning user might have them.
        public static var settings: AppSettings {
            var settings = AppSettings()
            settings.excludedBundleIDs = ["com.apple.Music", "com.spotify.client"]
            settings.meetings.useCalendar = true
            settings.meetings.calendarIDs = ["work", "home"]
            settings.transcription.enabled = true
            return settings
        }
    }
#endif
