#if os(macOS)
    @preconcurrency import AVFoundation
    import Foundation
    import TapeloopCore
    import XCTest

    @testable import TapeloopIntelligence

    /// Returns canned lines per file name, and records what it was asked.
    struct FakeTranscriber: Transcriber {
        var lines: [String: [TranscriptSegment]]
        var failing: String?

        func transcribe(fileURL: URL, locale: Locale) async throws -> [TranscriptSegment] {
            if fileURL.lastPathComponent == failing { throw IntelligenceError.recognitionFailed(reason: "boom") }
            return lines[fileURL.lastPathComponent] ?? []
        }
    }

    final class TranscriptionTests: XCTestCase {
        private func word(_ text: String, _ start: TimeInterval, _ duration: TimeInterval = 0.3) -> TimedWord {
            TimedWord(text: text, start: start, duration: duration)
        }

        // MARK: Segment building

        func testSplitsAtPausesAndSentences() {
            let words = [
                word("Hello", 0), word("there.", 0.4), word("How", 0.8), word("are", 1.2), word("you", 1.5),
                word("doing", 3.0), word(" ", 3.4), word("today?", 3.5),
            ]
            let segments = SegmentBuilder.segments(from: words)
            XCTAssertEqual(segments.map(\.text), ["Hello there.", "How are you", "doing today?"])
            XCTAssertEqual(segments[0].start, 0)
            XCTAssertEqual(segments[0].end, 0.7, accuracy: 1e-9)
            XCTAssertEqual(segments[1].start, 0.8)
            XCTAssertEqual(segments[2].start, 3.0)
            XCTAssertEqual(segments[2].end, 3.8, accuracy: 1e-9)
            XCTAssertTrue(segments.allSatisfy { $0.speaker == nil })
        }

        func testSplitsLongRunsAtAboutTwelveSeconds() {
            let words = (0..<60).map { word("word", Double($0) * 0.5, 0.4) }
            let segments = SegmentBuilder.segments(from: words)
            XCTAssertGreaterThan(segments.count, 2)
            for segment in segments { XCTAssertLessThanOrEqual(segment.end - segment.start, 12) }
            XCTAssertEqual(segments.map { $0.text.split(separator: " ").count }.reduce(0, +), 60)
        }

        func testDropsEmptyAndTrimsText() {
            XCTAssertEqual(SegmentBuilder.segments(from: []), [])
            XCTAssertEqual(SegmentBuilder.segments(from: [word("  ", 0), word("\n", 2)]), [])
            XCTAssertEqual(SegmentBuilder.segments(from: [word(" ok ", 0)]).map(\.text), ["ok"])
            XCTAssertEqual(
                SegmentBuilder.segments(from: [word("“Stop!”", 0), word("he", 0.4), word("said.", 0.7)]).map(\.text),
                ["“Stop!”", "he said."])
        }

        // MARK: Merging and labelling

        func testMergeShiftsLabelsAndSorts() {
            let mic = [
                TranscriptSegment(start: 0, end: 2, text: "Hi"), TranscriptSegment(start: 5, end: 6, text: "Sure"),
            ]
            let system = [
                TranscriptSegment(start: 0, end: 3, text: "Hello"), TranscriptSegment(start: 4, end: 5, text: "Ok?"),
            ]
            let merged = TranscriptionService.merge(
                [(source: .microphone, segments: mic, offset: 1), (source: .system, segments: system, offset: 1)],
                labelSpeakers: true)
            XCTAssertEqual(
                merged,
                [
                    TranscriptSegment(start: 1, end: 3, speaker: .microphone, text: "Hi"),
                    TranscriptSegment(start: 1, end: 4, speaker: .system, text: "Hello"),
                    TranscriptSegment(start: 5, end: 6, speaker: .system, text: "Ok?"),
                    TranscriptSegment(start: 6, end: 7, speaker: .microphone, text: "Sure"),
                ])

            let unlabelled = TranscriptionService.merge(
                [(source: .microphone, segments: mic, offset: 0), (source: .system, segments: system, offset: 0)],
                labelSpeakers: false)
            XCTAssertTrue(unlabelled.allSatisfy { $0.speaker == nil })
            XCTAssertEqual(unlabelled.map(\.text), ["Hi", "Hello", "Ok?", "Sure"])

            let mixed = TranscriptionService.merge([(source: nil, segments: mic, offset: 0)], labelSpeakers: true)
            XCTAssertTrue(mixed.allSatisfy { $0.speaker == nil })
        }

        func testServiceTranscribesEveryPart() async throws {
            let fake = FakeTranscriber(lines: [
                "mic.m4a": [TranscriptSegment(start: 2, end: 3, text: "Me")],
                "system.m4a": [TranscriptSegment(start: 0, end: 1, text: "Them")],
            ])
            let service = TranscriptionService(transcriber: fake)
            let dir = URL(fileURLWithPath: "/tmp/none")
            let transcript = try await service.transcribe(
                parts: [
                    (source: .microphone, url: dir.appendingPathComponent("mic.m4a"), offset: 0),
                    (source: .system, url: dir.appendingPathComponent("system.m4a"), offset: 10),
                ], locale: Locale(identifier: "en-US"), labelSpeakers: true)
            XCTAssertEqual(transcript.locale, "en-US")
            XCTAssertEqual(
                transcript.segments,
                [
                    TranscriptSegment(start: 2, end: 3, speaker: .microphone, text: "Me"),
                    TranscriptSegment(start: 10, end: 11, speaker: .system, text: "Them"),
                ])
        }

        func testServicePassesErrorsOn() async {
            let service = TranscriptionService(transcriber: FakeTranscriber(lines: [:], failing: "bad.m4a"))
            do {
                _ = try await service.transcribe(
                    parts: [(source: nil, url: URL(fileURLWithPath: "/tmp/bad.m4a"), offset: 0)],
                    locale: Locale(identifier: "en-US"), labelSpeakers: false)
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? IntelligenceError, .recognitionFailed(reason: "boom"))
            }
        }

        // MARK: Apple speech (no permission prompts)

        func testMissingFileIsUnreadable() async {
            do {
                _ = try await AppleSpeechTranscriber().transcribe(
                    fileURL: URL(fileURLWithPath: "/nonexistent/x.m4a"), locale: Locale(identifier: "en-US"))
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? IntelligenceError, .unreadableAudio(fileName: "x.m4a"))
            }
        }

        func testUnknownLocaleCannotRunOnDevice() {
            XCTAssertFalse(AppleSpeechTranscriber.supportsOnDevice(Locale(identifier: "xx-XX")))
            XCTAssertThrowsError(try AppleSpeechTranscriber.checkLocale(Locale(identifier: "xx-XX"))) { error in
                guard case .onDeviceUnavailable = error as? IntelligenceError else {
                    return XCTFail("unexpected \(error)")
                }
                XCTAssertTrue("\(error)".hasPrefix("On-device transcription is not available for "))
            }
        }

        func testOnDeviceLocalesAreSortedAndSupported() {
            let locales = AppleSpeechTranscriber.onDeviceLocales()
            let names = locales.map { Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier }
            XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }

        func testSilentFileNeedsPermissionOrGivesNothing() async throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tapeloop-silence-\(UUID()).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2)!
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 3)!
                buffer.frameLength = buffer.frameCapacity
                try file.write(from: buffer)
            }
            let locale = Locale(identifier: "en-US")
            do {
                let segments = try await AppleSpeechTranscriber().transcribe(fileURL: url, locale: locale)
                XCTAssertEqual(SpeechPermission.status, .authorized)
                XCTAssertEqual(segments, [], "silence is skipped")
            } catch let error as IntelligenceError {
                switch SpeechPermission.status {
                case .notDetermined: XCTAssertEqual(error, .speechNotRequested)
                case .denied, .restricted: XCTAssertEqual(error, .speechNotAllowed)
                case .authorized:
                    guard case .onDeviceUnavailable = error else { return XCTFail("unexpected \(error)") }
                    throw XCTSkip("en-US has no on-device model on this Mac")
                }
            }
        }

        func testErrorMessagesArePlainEnglish() {
            XCTAssertEqual(
                IntelligenceError.speechNotAllowed.description,
                "Speech recognition is not allowed. Turn it on in System Settings › Privacy & Security › Speech Recognition."
            )
            XCTAssertEqual(
                IntelligenceError.onDeviceUnavailable(language: "Klingon").description,
                "On-device transcription is not available for Klingon on this Mac.")
            XCTAssertEqual(
                IntelligenceError.calendarNotAllowed.localizedDescription,
                IntelligenceError.calendarNotAllowed.description)
        }
    }
#endif
