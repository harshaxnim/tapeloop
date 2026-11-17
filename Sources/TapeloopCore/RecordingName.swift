import Foundation

/// Builds clear file names for saved recordings, for example `Tapeloop 2026-11-17 14.05 (15 min) Standup.m4a`.
public enum RecordingName {
    /// The file name for a recording that starts at `start` and lasts `duration` seconds.
    public static func make(
        start: Date, duration: TimeInterval, title: String? = nil, timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        let stamp = String(
            format: "%04d-%02d-%02d %02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        var name = "\(TapeloopInfo.name) \(stamp) (\(lengthLabel(duration)))"
        if let title = title.map(sanitize), !title.isEmpty { name += " \(title)" }
        return name + ".m4a"
    }

    /// A short length label: `45 s`, `15 min`, `1 h 05 min`.
    public static func lengthLabel(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// Removes characters that are unsafe in file names and trims the length.
    public static func sanitize(_ title: String) -> String {
        let banned = Set("/:\\?%*|\"<>\n\r\t")
        let cleaned = String(title.map { banned.contains($0) ? "-" : $0 })
        return String(cleaned.trimmingCharacters(in: .whitespaces).prefix(80))
    }
}
