import Foundation

/// A saved recording as the Library shows it: the audio file plus what Tapeloop knows about it.
public struct LibraryRecording: Identifiable, Equatable, Sendable {
    /// The audio file.
    public var url: URL
    /// The sidecar metadata, when there is one that could be read.
    public var metadata: RecordingMetadata?
    /// The audio file's size in bytes.
    public var fileSize: Int
    /// When the audio file was last modified.
    public var modified: Date

    /// Creates a recording.
    public init(url: URL, metadata: RecordingMetadata?, fileSize: Int, modified: Date) {
        self.url = url
        self.metadata = metadata
        self.fileSize = fileSize
        self.modified = modified
    }

    /// The file's URL identifies the recording.
    public var id: URL { url }

    /// The title to show: the user's title, else the calendar event's title, else the file name without extension.
    public var title: String {
        if let title = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let calendar = metadata?.meeting?.calendarTitle, !calendar.isEmpty { return calendar }
        return url.deletingPathExtension().lastPathComponent
    }

    /// When the recording starts: from the metadata, else estimated from the file's modification date.
    public var start: Date { metadata?.start ?? modified.addingTimeInterval(-(duration ?? 0)) }

    /// The length in seconds, when known from the metadata.
    public var duration: TimeInterval? { metadata?.duration }

    /// When the recording ends, when its length is known.
    public var end: Date? { duration.map { start.addingTimeInterval($0) } }
}

/// Errors from `LibraryStore`.
public enum LibraryStoreError: Error, Equatable, LocalizedError {
    /// The new title is empty and the file has no metadata to build a name from.
    case emptyTitle
    /// A file with every candidate name already exists.
    case nameUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: "The name cannot be empty."
        case .nameUnavailable(let name): "Another file is already named “\(name)”."
        }
    }
}

/// Reads and changes the recordings in a save folder.
///
/// Each recording is an ordinary `.m4a` file. What Tapeloop knows about it (title, meeting, bookmarks, transcript)
/// lives in a sidecar JSON file in a hidden folder: `<folder>/.tapeloop/<audio file name>.json`. The store keeps no
/// state besides the folder, so it can be used from any thread.
public final class LibraryStore: @unchecked Sendable {
    /// The save folder.
    public let folder: URL

    /// The name of the hidden folder that holds the sidecar files.
    public static let sidecarFolderName = ".tapeloop"

    private var fileManager: FileManager { .default }

    /// Creates a store for `folder`.
    public init(folder: URL) {
        self.folder = folder
    }

    /// The sidecar metadata file for the audio file at `url`.
    public static func sidecarURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(sidecarFolderName, isDirectory: true)
            .appendingPathComponent(url.lastPathComponent + ".json", isDirectory: false)
    }

    // MARK: - Reading

    /// Every `.m4a` file in the folder (hidden files excluded), newest first. An absent folder has no recordings.
    public func recordings() throws -> [LibraryRecording] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        let names = try fileManager.contentsOfDirectory(atPath: folder.path)
        var result: [LibraryRecording] = []
        for name in names where !name.hasPrefix(".") && (name as NSString).pathExtension.lowercased() == "m4a" {
            let url = folder.appendingPathComponent(name, isDirectory: false)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                (attributes[.type] as? FileAttributeType) == .typeRegular
            else { continue }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let modified = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            result.append(LibraryRecording(url: url, metadata: metadata(for: url), fileSize: size, modified: modified))
        }
        return result.sorted { a, b in
            a.start != b.start ? a.start > b.start : a.url.lastPathComponent < b.url.lastPathComponent
        }
    }

    /// The sidecar metadata for the audio file at `url`, or `nil` when there is none or it cannot be read.
    public func metadata(for url: URL) -> RecordingMetadata? {
        guard let data = try? Data(contentsOf: Self.sidecarURL(for: url)) else { return nil }
        return try? Self.decoder().decode(RecordingMetadata.self, from: data)
    }

    // MARK: - Changing

    /// Writes `metadata` as the sidecar of the audio file at `url`, atomically.
    public func save(_ metadata: RecordingMetadata, for url: URL) throws {
        let sidecar = Self.sidecarURL(for: url)
        try fileManager.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder().encode(metadata).write(to: sidecar, options: .atomic)
    }

    /// Gives the recording at `url` a new title and renames its file to match; returns the new file URL.
    ///
    /// With metadata, the title is stored in it and the file is named like a fresh save, `Tapeloop <date> (<length>)
    /// <title>.m4a`; an empty title clears the stored one. Without metadata, the file becomes `<title>.m4a`. A name
    /// that is taken gets " 2", " 3", … appended. The sidecar moves with the file.
    @discardableResult
    public func rename(_ url: URL, to title: String) throws -> URL {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var metadata = metadata(for: url)
        let baseName: String
        if var m = metadata {
            m.title = trimmed.isEmpty ? nil : trimmed
            metadata = m
            baseName =
                (RecordingName.make(start: m.start, duration: m.duration, title: m.title) as NSString)
                .deletingPathExtension
        } else {
            let safe = RecordingName.sanitize(trimmed)
            guard !safe.isEmpty else { throw LibraryStoreError.emptyTitle }
            baseName = safe
        }
        let target = try availableURL(baseName: baseName, pathExtension: url.pathExtension, replacing: url)
        let oldSidecar = Self.sidecarURL(for: url)
        if target.lastPathComponent != url.lastPathComponent {
            try fileManager.moveItem(at: url, to: target)
        }
        do {
            if let metadata {
                try save(metadata, for: target)
                if target.lastPathComponent != url.lastPathComponent {
                    try? fileManager.removeItem(at: oldSidecar)
                }
            } else if target.lastPathComponent != url.lastPathComponent,
                fileManager.fileExists(atPath: oldSidecar.path)
            {
                // An unreadable sidecar still belongs to the file; keep it with it.
                try? fileManager.moveItem(at: oldSidecar, to: Self.sidecarURL(for: target))
            }
        } catch {
            if target.lastPathComponent != url.lastPathComponent {
                try? fileManager.moveItem(at: target, to: url)
            }
            throw error
        }
        return target
    }

    /// Deletes the recording at `url`: on macOS the audio goes to the Trash, elsewhere it is removed. The sidecar is
    /// removed. Returns where the audio went in the Trash, when known.
    @discardableResult
    public func delete(_ url: URL) throws -> URL? {
        var trashed: URL?
        #if os(macOS)
            var resulting: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resulting)
            trashed = resulting as URL?
        #else
            try fileManager.removeItem(at: url)
        #endif
        let sidecar = Self.sidecarURL(for: url)
        if fileManager.fileExists(atPath: sidecar.path) {
            try fileManager.removeItem(at: sidecar)
        }
        return trashed
    }

    /// A free URL in the same folder as `original`: `<baseName>.<ext>`, else `<baseName> 2.<ext>`, `… 3`, ….
    /// `original` itself counts as free, including a different-case spelling of its own name.
    private func availableURL(baseName: String, pathExtension: String, replacing original: URL) throws -> URL {
        let directory = original.deletingLastPathComponent()
        let ext = pathExtension.isEmpty ? "m4a" : pathExtension
        for n in 1...999 {
            let name = n == 1 ? "\(baseName).\(ext)" : "\(baseName) \(n).\(ext)"
            if name == original.lastPathComponent { return original }
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if name.lowercased() == original.lastPathComponent.lowercased() { return candidate }
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        throw LibraryStoreError.nameUnavailable("\(baseName).\(ext)")
    }

    // MARK: - Grouping and search

    /// Splits `items` (kept in their order) into days: "Today", "Yesterday", else for example "Friday, 13 November",
    /// with the year added when it is not the year of `now`.
    public static func groupedByDay(
        _ items: [LibraryRecording], now: Date = Date(), calendar: Calendar = .current
    ) -> [(title: String, items: [LibraryRecording])] {
        var groups: [(day: Date, title: String, items: [LibraryRecording])] = []
        var indexByDay: [Date: Int] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.start)
            if let index = indexByDay[day] {
                groups[index].items.append(item)
            } else {
                indexByDay[day] = groups.count
                groups.append((day, dayTitle(for: day, now: now, calendar: calendar), [item]))
            }
        }
        return groups.map { ($0.title, $0.items) }
    }

    /// The heading for the day that contains `date`.
    public static func dayTitle(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "EEEE, d MMMM" : "EEEE, d MMMM yyyy"
        return formatter.string(from: date)
    }

    /// Whether `item` matches a search: every word of `query` must appear (ignoring case and accents) in the title,
    /// the file name, the meeting's app or calendar title, a bookmark label or the transcript. An empty query
    /// matches everything.
    public static func matches(_ item: LibraryRecording, query: String) -> Bool {
        let words = fold(query).split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return true }
        var fields = [item.title, item.url.deletingPathExtension().lastPathComponent]
        if let m = item.metadata {
            if let meeting = m.meeting {
                fields.append(meeting.appName)
                if let calendarTitle = meeting.calendarTitle { fields.append(calendarTitle) }
            }
            fields += m.bookmarks.compactMap(\.label)
            if let transcript = m.transcript { fields.append(transcript.text) }
        }
        let haystack = fold(fields.joined(separator: "\n"))
        return words.allSatisfy { haystack.contains($0) }
    }

    /// `text` without case and accents, for comparisons.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: - JSON

    /// The sidecar encoder: pretty-printed, sorted keys, ISO-8601 dates (with milliseconds only when needed).
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.string(from: date))
        }
        return encoder
    }

    /// The sidecar decoder: accepts ISO-8601 dates with or without fractional seconds.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = ISO8601.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Expected an ISO-8601 date, found “\(string)”.")
            }
            return date
        }
        return decoder
    }
}

/// ISO-8601 date strings in UTC.
enum ISO8601 {
    static func string(from date: Date) -> String {
        let whole = date.timeIntervalSince1970.rounded(.down)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions =
            date.timeIntervalSince1970 == whole
            ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
