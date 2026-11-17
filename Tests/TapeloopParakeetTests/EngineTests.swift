#if os(macOS)
    import CryptoKit
    import Foundation
    import TapeloopCore
    import XCTest

    @testable import TapeloopParakeet

    final class EngineTests: XCTestCase {
        func testEngineLoads() {
            XCTAssertFalse(TapeloopParakeetModule.engineVersion.isEmpty)
        }

        /// Speaks a sentence with the system voice and transcribes it with the installed model. Skipped when the
        /// model is not installed (as on CI).
        func testTranscribesSpeech() async throws {
            let store = ModelStore()
            try XCTSkipUnless(store.isInstalled, "The Parakeet model is not installed in \(store.folder.path)")
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let speech = folder.appendingPathComponent("speech.aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = [
                "-o", speech.path,
                "Okay, so the release is on Friday. Does anyone have blockers? I will send the updated deck tonight.",
            ]
            try say.run()
            say.waitUntilExit()
            try XCTSkipUnless(say.terminationStatus == 0, "The say command failed")

            let engine = ParakeetEngine(modelPath: store.fileURL)
            let started = Date()
            let lines = try await ParakeetTranscriber(engine: engine).transcribe(
                fileURL: speech, locale: Locale(identifier: "en_US"))
            let text = lines.map(\.text).joined(separator: " ").lowercased()
            print("Parakeet: \(Date().timeIntervalSince(started)) s, \(lines.count) lines: \(text)")
            XCTAssertTrue(text.contains("release"), text)
            XCTAssertTrue(text.contains("friday"), text)
            XCTAssertTrue(text.contains("deck"), text)
            XCTAssertTrue(lines.allSatisfy { $0.end >= $0.start && $0.start >= 0 })
            XCTAssertFalse(engine.isLoaded, "The after-save transcriber releases the model")
        }
    }

    final class ModelStoreTests: XCTestCase {
        private var folder: URL!

        override func setUpWithError() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        override func tearDownWithError() throws {
            try? FileManager.default.removeItem(at: folder)
        }

        /// A small fake catalog entry whose "release asset" is a local file.
        private func fakeModel(bytes: Data) throws -> (TranscriptionModel, URL) {
            let source = folder.appendingPathComponent("source.gguf")
            try bytes.write(to: source)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let model = TranscriptionModel(
                id: "fake", name: "Fake", fileName: "fake.gguf", size: Int64(bytes.count), sha256: hash, url: source,
                languages: ["en"], licence: "none")
            return (model, source)
        }

        private func wait(for store: ModelStore, until done: @escaping (ModelStore.State) -> Bool) {
            let expectation = expectation(description: "state")
            let deadline = Date().addingTimeInterval(10)
            DispatchQueue.global().async {
                while Date() < deadline {
                    if done(store.state) { break }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 11)
        }

        func testSHA256MatchesCryptoKit() throws {
            let data = Data((0..<5_000_000).map { UInt8($0 % 251) })
            let url = folder.appendingPathComponent("blob")
            try data.write(to: url)
            XCTAssertEqual(
                try ModelStore.sha256(of: url), SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }

        func testImportAcceptsTheExactFile() throws {
            let (model, source) = try fakeModel(bytes: Data(repeating: 7, count: 4096))
            let store = ModelStore(model: model, folder: folder.appendingPathComponent("Models"))
            XCTAssertEqual(store.state, .notInstalled)
            store.importFile(at: source)
            wait(for: store) { $0 == .installed }
            XCTAssertEqual(store.state, .installed)
            XCTAssertTrue(store.isInstalled)
            store.delete()
            XCTAssertEqual(store.state, .notInstalled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        }

        func testImportRejectsADifferentFile() throws {
            let (model, _) = try fakeModel(bytes: Data(repeating: 7, count: 4096))
            let other = folder.appendingPathComponent("other.gguf")
            try Data(repeating: 8, count: 4096).write(to: other)
            let store = ModelStore(model: model, folder: folder.appendingPathComponent("Models"))
            store.importFile(at: other)
            wait(for: store) { if case .failed = $0 { return true } else { return false } }
            guard case .failed(let message) = store.state else { return XCTFail("\(store.state)") }
            XCTAssertTrue(message.contains("not the expected model"), message)
            XCTAssertFalse(store.isInstalled)
        }

        func testDownloadVerifiesAndInstalls() throws {
            // URLSession downloads file URLs too, so this runs without a network.
            let (model, _) = try fakeModel(bytes: Data((0..<200_000).map { UInt8($0 % 13) }))
            let store = ModelStore(model: model, folder: folder.appendingPathComponent("Models"))
            store.download()
            wait(for: store) { state in
                if case .failed = state { return true }
                return state == .installed
            }
            XCTAssertEqual(store.state, .installed)
        }
    }
#endif

#if os(macOS)
    final class TokenWordTests: XCTestCase {
        func testTokensJoinIntoWords() {
            let words = ParakeetEngine.words(fromTokens: [
                (" O", 720, 800), ("kay", 720, 800), (",", 1040, 1120), (" so", 1200, 1280), (" re", 1440, 1520),
                ("le", 1440, 1520), ("ase", 1520, 1600),
            ])
            XCTAssertEqual(words.map(\.text), ["Okay,", "so", "release"])
            XCTAssertEqual(words[0].start, 0.72, accuracy: 0.001)
            XCTAssertEqual(words[0].end, 1.12, accuracy: 0.001)
            XCTAssertEqual(words[2].end, 1.6, accuracy: 0.001)
        }

        func testFirstPieceWithoutSpaceStartsAWord() {
            XCTAssertEqual(
                ParakeetEngine.words(fromTokens: [("Hi", 0, 100), (" there", 200, 300)]).map(\.text), ["Hi", "there"])
        }
    }
#endif

#if os(macOS)
    import AVFoundation

    final class LiveTranscriberTests: XCTestCase {
        func testLiveLinesCoverASavedSpan() throws {
            let store = ModelStore()
            try XCTSkipUnless(store.isInstalled, "The Parakeet model is not installed")
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let speech = folder.appendingPathComponent("speech.aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", speech.path, "The release is on Friday. I will send the deck tonight."]
            try say.run()
            say.waitUntilExit()

            let engine = ParakeetEngine(modelPath: store.fileURL)
            let live = LiveTranscriber(engine: engine)
            let file = try AVAudioFile(forReading: speech)
            let format = file.processingFormat
            let step = AVAudioFrameCount(format.sampleRate / 10)
            var time = Date()
            let start = time
            // The speech in 100 ms buffers, then 2 s of silence (which ends the piece).
            while file.framePosition < file.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: step)!
                try file.read(into: buffer, frameCount: min(step, AVAudioFrameCount(file.length - file.framePosition)))
                live.consume(.microphone, buffer: buffer, at: time)
                time = time.addingTimeInterval(Double(buffer.frameLength) / format.sampleRate)
            }
            for _ in 0..<20 {
                let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: step)!
                silence.frameLength = step
                live.consume(.microphone, buffer: silence, at: time)
                time = time.addingTimeInterval(0.1)
            }
            live.flush()
            let segments = live.segments(in: TimeRange(start: start, end: time), labelSpeakers: true)
            let text = segments.map(\.text).joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains("friday"), text)
            XCTAssertTrue(text.contains("deck"), text)
            XCTAssertTrue(segments.allSatisfy { $0.speaker == .microphone })
            XCTAssertTrue(
                live.segments(in: TimeRange(start: time, end: time.addingTimeInterval(5)), labelSpeakers: true).isEmpty)
            live.trim(before: time.addingTimeInterval(1))
            XCTAssertEqual(live.lineCount, 0)
        }

        func testSilenceIsMeasured() {
            var state = LiveTranscriber.Pending()
            LiveTranscriber.measure([Float](repeating: 0, count: 16000), into: &state)
            XCTAssertFalse(state.voiced)
            XCTAssertEqual(state.trailingSilence, 1, accuracy: 0.01)
            LiveTranscriber.measure((0..<1600).map { sin(Float($0) * 0.1) * 0.2 }, into: &state)
            XCTAssertTrue(state.voiced)
            XCTAssertEqual(state.trailingSilence, 0)
        }
    }
#endif
