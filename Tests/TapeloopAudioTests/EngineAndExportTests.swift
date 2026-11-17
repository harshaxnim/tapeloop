#if os(macOS)
    @preconcurrency import AVFoundation
    import TapeloopAudio
    import TapeloopCore
    import TapeloopExport
    import XCTest

    /// Synthetic audio: mono 48 kHz sine buffers of 4096 frames with their capture times.
    enum Tone {
        static let rate = 48_000.0
        static let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!

        static func buffers(
            frequency: Double, amplitude: Float = 0.5, seconds: Double, startingAt start: Date
        ) -> [(AVAudioPCMBuffer, Date)] {
            let total = Int(seconds * rate)
            var result: [(AVAudioPCMBuffer, Date)] = []
            var written = 0
            while written < total {
                let count = min(4096, total - written)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                let data = buffer.floatChannelData![0]
                for i in 0..<count {
                    data[i] = amplitude * Float(sin(2 * .pi * frequency * Double(written + i) / rate))
                }
                result.append((buffer, start.addingTimeInterval(Double(written) / rate)))
                written += count
            }
            return result
        }

        static func feed(
            _ sink: CaptureSink, frequency: Double, seconds: Double, from start: Date, amplitude: Float = 0.5
        ) {
            for (buffer, time) in buffers(
                frequency: frequency, amplitude: amplitude, seconds: seconds, startingAt: start)
            {
                sink.consume(buffer, at: time)
            }
        }
    }

    /// Reads a file and returns its duration and the RMS of `[from, from + length)` seconds.
    private func inspect(_ url: URL, rmsFrom from: Double = 0, length: Double = 0.5) throws -> (Double, Float) {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let frames = AVAudioFrameCount(length * file.processingFormat.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        file.framePosition = AVAudioFramePosition(from * file.processingFormat.sampleRate)
        try file.read(into: buffer, frameCount: frames)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count)))
        return (duration, rms)
    }

    final class ExportTests: XCTestCase {
        private let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        private var folder: URL!

        override func setUp() {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("tapeloop-export-\(UUID())")
        }

        override func tearDown() {
            try? FileManager.default.removeItem(at: folder)
        }

        private func sink(_ kind: SourceKind) throws -> CaptureSink {
            CaptureSink(encoder: try AACEncoder(source: kind), maxDuration: 3600)
        }

        private func source(_ sink: CaptureSink) -> ExportSource {
            sink.flush()
            let state = sink.snapshot()
            return ExportSource(
                source: sink.source, chunks: state.chunks, streamDescription: state.streamDescription,
                magicCookie: state.magicCookie)
        }

        func testGapsBecomeSeparateSegmentsWithExactTimes() throws {
            let mic = try sink(.microphone)
            Tone.feed(mic, frequency: 440, seconds: 3, from: t0)
            Tone.feed(mic, frequency: 440, seconds: 3, from: t0.addingTimeInterval(13))
            mic.flush()
            let chunks = mic.snapshot().chunks
            let gaps = zip(chunks, chunks.dropFirst()).map { $1.start.timeIntervalSince($0.end) }.filter { $0 > 1 }
            XCTAssertEqual(gaps.count, 1)
            XCTAssertEqual(gaps.first ?? 0, 10, accuracy: 0.2)
            XCTAssertEqual(chunks.last!.end.timeIntervalSince(t0), 16, accuracy: 0.2)
            XCTAssertFalse(chunks.flatMap(\.levels).isEmpty, "levels are recorded for the waveform")
        }

        func testPassthroughSaveIsTrimmedToTheRange() throws {
            let mic = try sink(.microphone)
            Tone.feed(mic, frequency: 440, seconds: 30, from: t0)
            let request = ExportRequest(
                range: TimeRange(start: t0.addingTimeInterval(10), end: t0.addingTimeInterval(20)),
                sources: [source(mic)], folder: folder, title: "Stand/up")
            let result = try Exporter.save(request)
            XCTAssertEqual(result.files.count, 1)
            let name = result.files[0].lastPathComponent
            XCTAssertTrue(name.hasPrefix("Tapeloop ") && name.hasSuffix("(10 s) Stand-up.m4a"), name)
            let (duration, rms) = try inspect(result.files[0], rmsFrom: 5)
            XCTAssertEqual(duration, 10, accuracy: 0.1)
            XCTAssertEqual(rms, 0.35, accuracy: 0.05)
            // No temporary files are left behind.
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
                $0.hasPrefix(".")
            }
            XCTAssertEqual(leftovers, [])
        }

        func testMixAlignsSourcesByTimeAndFillsGapsWithSilence() throws {
            let mic = try sink(.microphone)
            let system = try sink(.system)
            Tone.feed(mic, frequency: 440, seconds: 6, from: t0)
            Tone.feed(mic, frequency: 440, seconds: 6, from: t0.addingTimeInterval(14))  // mic gap 6-14 s
            Tone.feed(system, frequency: 880, seconds: 10, from: t0.addingTimeInterval(5))  // system 5-15 s
            let request = ExportRequest(
                range: TimeRange(start: t0, end: t0.addingTimeInterval(20)), sources: [source(mic), source(system)],
                folder: folder)
            let result = try Exporter.save(request)
            XCTAssertEqual(result.files.count, 1)
            XCTAssertEqual(Set(result.sources), [.microphone, .system])

            let (duration, onlyMic) = try inspect(result.files[0], rmsFrom: 2)
            XCTAssertEqual(duration, 20, accuracy: 0.15)
            XCTAssertEqual(onlyMic, 0.35, accuracy: 0.06, "mic alone at 2 s")
            let (_, onlySystem) = try inspect(result.files[0], rmsFrom: 9)
            XCTAssertEqual(onlySystem, 0.35, accuracy: 0.06, "system alone at 9 s (mic gap)")
            let (_, both) = try inspect(result.files[0], rmsFrom: 14.5)
            XCTAssertEqual(both, 0.5, accuracy: 0.08, "both at 14.5 s")
            let (_, silence) = try inspect(result.files[0], rmsFrom: 17)
            XCTAssertEqual(silence, 0.35, accuracy: 0.06, "mic alone again at 17 s")
        }

        func testSilenceWhereNoSourceHasAudio() throws {
            let mic = try sink(.microphone)
            Tone.feed(mic, frequency: 440, seconds: 4, from: t0)
            Tone.feed(mic, frequency: 440, seconds: 4, from: t0.addingTimeInterval(12))
            let system = try sink(.system)
            Tone.feed(system, frequency: 880, seconds: 2, from: t0)
            let result = try Exporter.save(
                ExportRequest(
                    range: TimeRange(start: t0, end: t0.addingTimeInterval(16)),
                    sources: [source(mic), source(system)],
                    folder: folder))
            let (_, gap) = try inspect(result.files[0], rmsFrom: 7, length: 2)
            XCTAssertLessThan(gap, 0.01, "nothing was recorded from 4 s to 12 s")
        }

        func testSeparateFilesWhenNotMixing() throws {
            let mic = try sink(.microphone)
            let system = try sink(.system)
            Tone.feed(mic, frequency: 440, seconds: 5, from: t0)
            Tone.feed(system, frequency: 880, seconds: 5, from: t0)
            let result = try Exporter.save(
                ExportRequest(
                    range: TimeRange(start: t0, end: t0.addingTimeInterval(5)), sources: [source(mic), source(system)],
                    folder: folder, mix: false))
            XCTAssertEqual(result.files.count, 2)
            XCTAssertTrue(result.files.contains { $0.lastPathComponent.hasSuffix(" - Microphone.m4a") })
            XCTAssertTrue(result.files.contains { $0.lastPathComponent.hasSuffix(" - System audio.m4a") })
        }

        func testSavingTwiceDoesNotOverwrite() throws {
            let mic = try sink(.microphone)
            Tone.feed(mic, frequency: 440, seconds: 5, from: t0)
            let request = ExportRequest(
                range: TimeRange(start: t0, end: t0.addingTimeInterval(5)), sources: [source(mic)], folder: folder)
            let first = try Exporter.save(request).files[0]
            let second = try Exporter.save(request).files[0]
            XCTAssertNotEqual(first, second)
            XCTAssertTrue(second.lastPathComponent.hasSuffix(" 2.m4a"), second.lastPathComponent)
        }

        func testNothingToSave() throws {
            let mic = try sink(.microphone)
            Tone.feed(mic, frequency: 440, seconds: 5, from: t0)
            let request = ExportRequest(
                range: TimeRange(start: t0.addingTimeInterval(100), end: t0.addingTimeInterval(200)),
                sources: [source(mic)], folder: folder)
            XCTAssertThrowsError(try Exporter.save(request))
        }

        /// Encodes ten minutes and reports the RAM cost per hour (expected about 22 MB per source at 48 kbps).
        func testRAMUseForTenMinutes() throws {
            let mic = try sink(.microphone)
            let minutes = 10.0
            Tone.feed(mic, frequency: 300, seconds: minutes * 60, from: t0, amplitude: 0.3)
            mic.flush()
            let bytes = mic.snapshot().bytes
            let perHour = Double(bytes) * 60 / minutes
            print(
                String(
                    format: "RAM: %.1f MB per hour per source at 48 kbps (%d bytes for %.0f min)", perHour / 1e6, bytes,
                    minutes))
            // 48 kbps is 21.6 MB/h of payload; allow for VBR and tables.
            XCTAssertLessThan(perHour, 30e6)
            XCTAssertGreaterThan(perHour, 10e6)
        }
    }

    /// A fake system-audio source the test drives by hand.
    final class FakeSource: AudioSource, @unchecked Sendable {
        let kind: SourceKind
        private(set) var handler: AudioBufferHandler?
        private(set) var events: (@Sendable (SourceEvent) -> Void)?
        init(kind: SourceKind) { self.kind = kind }
        func start(onBuffer: @escaping AudioBufferHandler, onEvent: @escaping @Sendable (SourceEvent) -> Void) throws {
            handler = onBuffer
            events = onEvent
        }
        func stop() {
            handler = nil
        }
        func push(seconds: Double, from start: Date) {
            for (buffer, time) in Tone.buffers(frequency: 500, seconds: seconds, startingAt: start) {
                handler?(buffer, time)
            }
        }
    }

    final class RecorderEngineTests: XCTestCase {
        private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

        private func makeEngine(_ settings: RecorderSettings) -> (RecorderEngine, FakeSourceBox) {
            let box = FakeSourceBox()
            let engine = RecorderEngine(
                settings: settings,
                spillFolder: FileManager.default.temporaryDirectory.appendingPathComponent("tapeloop-engine-\(UUID())"),
                makeSource: { kind, _ in
                    let fake = FakeSource(kind: kind)
                    box.set(kind, fake)
                    return fake
                })
            return (engine, box)
        }

        func testRecordsPausesAndTurnsSourcesOff() async throws {
            let (engine, box) = makeEngine(RecorderSettings(sources: [.system]))
            await engine.start()
            XCTAssertEqual(engine.status().sources[.system], .running)
            XCTAssertEqual(engine.status().sources[.microphone], .off)

            box.get(.system)?.push(seconds: 12, from: t0)
            var status = engine.status()
            XCTAssertGreaterThan(status.bytesInRAM, 0)
            XCTAssertTrue(status.isRecording)

            engine.setPaused(true)
            status = engine.status()
            XCTAssertEqual(status.sources[.system], .paused)
            XCTAssertFalse(status.isRecording)
            XCTAssertEqual(status.range?.duration ?? 0, 12, accuracy: 0.2, "pausing keeps the buffer")
            XCTAssertNil(box.get(.system)?.handler, "the source is stopped while paused")

            engine.setPaused(false)
            XCTAssertEqual(engine.status().sources[.system], .running)

            let pieces = engine.exportPieces(for: TimeRange(start: t0, end: t0.addingTimeInterval(12)))
            XCTAssertEqual(pieces.map(\.source), [.system])

            var settings = engine.currentSettings
            settings.sources = []
            engine.apply(settings)
            status = engine.status()
            XCTAssertEqual(status.sources[.system], .off)
            XCTAssertEqual(status.bytesInRAM, 0, "turning a source off deletes its audio")
        }

        func testFailureIsReportedAndMemoryPressureShrinks() async throws {
            let (engine, box) = makeEngine(RecorderSettings(sources: [.system]))
            await engine.start()
            box.get(.system)?.push(seconds: 60, from: t0)
            let before = engine.status().bytesInRAM
            engine.relieveMemoryPressure(critical: false)
            XCTAssertLessThanOrEqual(engine.status().bytesInRAM, before / 2 + 2000)

            box.get(.system)?.events?(.failed("System audio could not be recorded."))
            let status = engine.status()
            XCTAssertEqual(status.sources[.system], .failed("System audio could not be recorded."))
            XCTAssertTrue(status.needsAttention)
            engine.wipe()
            XCTAssertEqual(engine.status().bytesInRAM, 0)
        }
    }

    final class FakeSourceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var sources: [SourceKind: FakeSource] = [:]
        func set(_ kind: SourceKind, _ source: FakeSource) { lock.withLock { sources[kind] = source } }
        func get(_ kind: SourceKind) -> FakeSource? { lock.withLock { sources[kind] } }
    }
#endif
