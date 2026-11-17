import Foundation

/// Turns a transcript into text files: plain text with times, and SubRip subtitles (`.srt`).
public enum TranscriptFormatter {
    /// The name shown for a speaker: "You" for the microphone, "System" for the system audio.
    public static func speakerName(_ speaker: SourceKind) -> String {
        switch speaker {
        case .microphone: "You"
        case .system: "System"
        }
    }

    /// A position in a recording as `m:ss`-style text: `mm:ss` below an hour (`03:07`), `h:mm:ss` from an hour on
    /// (`1:02:03`). Negative values count as zero.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// The transcript as plain text, one line per segment: `[mm:ss] You: text`. With a title, the title and a blank
    /// line come first.
    public static func plainText(_ transcript: Transcript, title: String? = nil) -> String {
        var lines: [String] = []
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            lines += [title, ""]
        }
        for segment in transcript.segments {
            var line = "[\(timestamp(segment.start))] "
            if let speaker = segment.speaker { line += "\(speakerName(speaker)): " }
            line += singleLine(segment.text)
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The transcript as SubRip subtitles: numbered cues with `HH:MM:SS,mmm --> HH:MM:SS,mmm` times, the speaker
    /// ("You: ", "System: ") before the text when known.
    public static func srt(_ transcript: Transcript) -> String {
        var cues: [String] = []
        for (index, segment) in transcript.segments.enumerated() {
            let start = max(0, segment.start)
            let end = max(start, segment.end)
            var text = singleLine(segment.text)
            if let speaker = segment.speaker { text = "\(speakerName(speaker)): " + text }
            cues.append("\(index + 1)\n\(srtTime(start)) --> \(srtTime(end))\n\(text)\n")
        }
        return cues.joined(separator: "\n")
    }

    /// `HH:MM:SS,mmm`.
    static func srtTime(_ seconds: TimeInterval) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// The text with line breaks turned into spaces, so a segment stays one line (and an SRT cue stays intact).
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
