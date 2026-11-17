import Foundation
import TapeloopCore
import XCTest

final class LibraryStoreTests: XCTestCase {
    private var folder: URL!
    private var store: LibraryStore!
    /// 2026-11-17 10:48:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_794_912_480)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = LibraryStore(folder: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func makeFile(_ name: String, bytes: Int = 10, modified: Date? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func metadata(
        start: Date, duration: TimeInterval = 2170, title: String? = nil, meeting: MeetingInfo? = nil,
        bookmarks: [RecordingBookmark] = [], transcript: Transcript? = nil
    ) -> RecordingMetadata {
        RecordingMetadata(
            title: title, start: start, duration: duration, sources: [.microphone, .system], mixed: true,
            meeting: meeting, bookmarks: bookmarks, transcript: transcript)
    }

    // MARK: - Listing

    func testMissingFolderHasNoRecordings() throws {
        let missing = LibraryStore(folder: folder.appendingPathComponent("nope"))
        XCTAssertEqual(try missing.recordings(), [])
    }

    func testListingIgnoresHiddenAndOtherFiles() throws {
        try makeFile("A.m4a", bytes: 1234)
        try makeFile("B.M4A")
        try makeFile(".tapeloop-temp.m4a")
        try makeFile("notes.txt")
        try makeFile("C.m4a.json")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Folder.m4a"), withIntermediateDirectories: true)
        try store.save(metadata(start: t0), for: folder.appendingPathComponent("A.m4a"))

        let items = try store.recordings()
        XCTAssertEqual(Set(items.map(\.url.lastPathComponent)), ["A.m4a", "B.M4A"])
        let a = try XCTUnwrap(items.first { $0.url.lastPathComponent == "A.m4a" })
        XCTAssertEqual(a.fileSize, 1234)
        XCTAssertEqual(a.metadata?.start, t0)
        XCTAssertEqual(a.id, a.url)
    }

    func testSortsNewestFirstByStart() throws {
        // Metadata start wins over the modification date; without metadata, start = modification date.
        let old = try makeFile("old.m4a", modified: t0.addingTimeInterval(9000))
        try store.save(metadata(start: t0.addingTimeInterval(-86_400), duration: 60), for: old)
        try makeFile("middle.m4a", modified: t0)
        let new = try makeFile("new.m4a", modified: t0.addingTimeInterval(-90_000))
        try store.save(metadata(start: t0.addingTimeInterval(3600)), for: new)

        XCTAssertEqual(try store.recordings().map(\.url.lastPathComponent), ["new.m4a", "middle.m4a", "old.m4a"])
    }

    func testDerivedProperties() throws {
        let url = folder.appendingPathComponent("Tapeloop 2026-11-17 10.48 (36 min).m4a")
        var item = LibraryRecording(url: url, metadata: nil, fileSize: 1, modified: t0)
        XCTAssertEqual(item.title, "Tapeloop 2026-11-17 10.48 (36 min)")
        XCTAssertEqual(item.start, t0)
        XCTAssertNil(item.duration)
        XCTAssertNil(item.end)

        item.metadata = metadata(start: t0, meeting: MeetingInfo(appName: "Zoom", calendarTitle: "Weekly sync"))
        XCTAssertEqual(item.title, "Weekly sync")
        XCTAssertEqual(item.duration, 2170)
        XCTAssertEqual(item.end, t0.addingTimeInterval(2170))
        item.metadata?.title = "  My title "
        XCTAssertEqual(item.title, "My title")
        item.metadata?.title = " "
        XCTAssertEqual(item.title, "Weekly sync")
    }

    // MARK: - Sidecars

    func testSidecarURL() {
        let url = URL(fileURLWithPath: "/x/Tapeloop 2026-11-17 10.48 (36 min).m4a")
        XCTAssertEqual(
            LibraryStore.sidecarURL(for: url).path, "/x/.tapeloop/Tapeloop 2026-11-17 10.48 (36 min).m4a.json")
    }

    func testSidecarRoundTrip() throws {
        let url = try makeFile("A.m4a")
        let m = metadata(
            start: t0.addingTimeInterval(0.25), title: "Weekly sync",
            meeting: MeetingInfo(appName: "Zoom", bundleID: "us.zoom.xos", calendarTitle: "Sync"),
            bookmarks: [RecordingBookmark(offset: 1420, label: "decision")],
            transcript: Transcript(
                locale: "en-US", createdAt: t0,
                segments: [TranscriptSegment(start: 1, end: 2, speaker: .microphone, text: "Hello")]))
        XCTAssertNil(store.metadata(for: url))
        try store.save(m, for: url)
        XCTAssertEqual(store.metadata(for: url), m)

        let json = try String(contentsOf: LibraryStore.sidecarURL(for: url), encoding: .utf8)
        XCTAssertTrue(json.contains("\"createdAt\" : \"2026-11-17T10:48:00Z\""), json)
        XCTAssertTrue(json.contains("\"start\" : \"2026-11-17T10:48:00.250Z\""), json)
        XCTAssertLessThan(
            try XCTUnwrap(json.range(of: "\"bookmarks\"")).lowerBound,
            try XCTUnwrap(json.range(of: "\"duration\"")).lowerBound,
            "keys are sorted")
    }

    func testOldAndPartialJSONLoads() throws {
        let url = try makeFile("A.m4a")
        let sidecar = LibraryStore.sidecarURL(for: url)
        try FileManager.default.createDirectory(
            at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"start": "2026-11-17T10:48:00Z", "duration": 60, "futureField": [1, 2]}"#.utf8).write(to: sidecar)
        let m = try XCTUnwrap(store.metadata(for: url))
        XCTAssertEqual(m.start, t0)
        XCTAssertEqual(m.duration, 60)
        XCTAssertEqual(m.version, 1)
        XCTAssertEqual(m.sources, [])
        XCTAssertEqual(m.bookmarks, [])
        XCTAssertNil(m.transcript)

        try Data("not json".utf8).write(to: sidecar)
        XCTAssertNil(store.metadata(for: url))
        XCTAssertEqual(try store.recordings().count, 1, "a broken sidecar does not hide the recording")
    }

    // MARK: - Rename

    func testRenameWithMetadataMovesBothFiles() throws {
        let start = Date(timeIntervalSince1970: 1_794_924_300)  // 2026-11-17 14:05 UTC
        let originalName = RecordingName.make(start: start, duration: 900)
        let url = try makeFile(originalName)
        try store.save(metadata(start: start, duration: 900), for: url)

        let renamed = try store.rename(url, to: "Standup: team/a")
        XCTAssertEqual(
            renamed.lastPathComponent, RecordingName.make(start: start, duration: 900, title: "Standup- team-a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: LibraryStore.sidecarURL(for: url).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(store.metadata(for: renamed)?.title, "Standup: team/a")

        // An empty title clears the stored one and goes back to the plain name.
        let cleared = try store.rename(renamed, to: "  ")
        XCTAssertEqual(cleared.lastPathComponent, originalName)
        XCTAssertNil(store.metadata(for: cleared)?.title)
        XCTAssertNotNil(store.metadata(for: cleared))
    }

    func testRenameAvoidsCollisions() throws {
        try makeFile("Idea.m4a")
        try makeFile("Idea 2.m4a")
        let url = try makeFile("Other.m4a", bytes: 77)
        let renamed = try store.rename(url, to: "Idea")
        XCTAssertEqual(renamed.lastPathComponent, "Idea 3.m4a")
        XCTAssertEqual(try Data(contentsOf: renamed).count, 77)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Idea.m4a")).count, 10, "untouched")
        XCTAssertEqual(store.metadata(for: renamed), nil)
    }

    func testRenameToSameNameKeepsFile() throws {
        let url = try makeFile("Idea.m4a")
        XCTAssertEqual(try store.rename(url, to: "Idea").lastPathComponent, "Idea.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRenameWithoutMetadataRejectsEmptyTitle() throws {
        let url = try makeFile("Idea.m4a")
        XCTAssertThrowsError(try store.rename(url, to: " ")) { error in
            XCTAssertEqual(error as? LibraryStoreError, .emptyTitle)
        }
    }

    // MARK: - Delete

    func testDeleteRemovesFileAndSidecar() throws {
        let url = try makeFile("Delete me \(UUID().uuidString).m4a")
        try store.save(metadata(start: t0), for: url)
        do {
            if let trashed = try store.delete(url) {
                XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
                try? FileManager.default.removeItem(at: trashed)  // keep the user's Trash clean
            }
        } catch {
            #if os(macOS)
                // Some test sandboxes have no Trash; that is not what this test checks.
                throw XCTSkip("Trash unavailable: \(error)")
            #else
                throw error
            #endif
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: LibraryStore.sidecarURL(for: url).path))
        XCTAssertEqual(try store.recordings(), [])
    }

    // MARK: - Grouping

    func testGroupingLabels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        // Tuesday 2026-11-17 11:40 in Berlin.
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 11, minute: 40)))
        func at(_ day: Int, _ hour: Int, year: Int = 2026, month: Int = 11) -> LibraryRecording {
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
            return LibraryRecording(
                url: folder.appendingPathComponent("\(year)-\(month)-\(day)-\(hour).m4a"),
                metadata: metadata(start: date, duration: 60), fileSize: 1, modified: date)
        }
        let items = [
            at(17, 10), at(17, 0), at(16, 23), at(16, 9), at(13, 15), at(13, 9), at(31, 12, year: 2025, month: 12),
        ]
        let groups = LibraryStore.groupedByDay(items, now: now, calendar: calendar)
        XCTAssertEqual(
            groups.map(\.title), ["Today", "Yesterday", "Friday, 13 November", "Wednesday, 31 December 2025"])
        XCTAssertEqual(groups.map(\.items.count), [2, 2, 2, 1])
        XCTAssertEqual(groups[0].items, Array(items[0..<2]))
        XCTAssertTrue(LibraryStore.groupedByDay([], now: now, calendar: calendar).isEmpty)
    }

    // MARK: - Search

    func testSearchMatching() {
        let item = LibraryRecording(
            url: folder.appendingPathComponent("Tapeloop 2026-11-17 10.48 (36 min) Weekly sync.m4a"),
            metadata: metadata(
                start: t0, title: "Weekly sync",
                meeting: MeetingInfo(appName: "Zoom", calendarTitle: "Équipe produit"),
                bookmarks: [RecordingBookmark(offset: 1, label: "decision"), RecordingBookmark(offset: 2)],
                transcript: Transcript(
                    locale: "en", segments: [TranscriptSegment(start: 0, end: 1, text: "I will send the Déck tonight")])
            ),
            fileSize: 1, modified: t0)
        for query in [
            "", "  ", "weekly", "WEEKLY SYNC", "zoom", "equipe", "PRODUIT", "Decision", "deck", "deck zoom",
            "2026-11-17", "send   tonight",
        ] {
            XCTAssertTrue(LibraryStore.matches(item, query: query), query)
        }
        for query in ["teams", "deck teams", "monthly"] {
            XCTAssertFalse(LibraryStore.matches(item, query: query), query)
        }
        let bare = LibraryRecording(
            url: folder.appendingPathComponent("Café.m4a"), metadata: nil, fileSize: 1, modified: t0)
        XCTAssertTrue(LibraryStore.matches(bare, query: "cafe"))
        XCTAssertFalse(LibraryStore.matches(bare, query: "deck"))
    }
}
