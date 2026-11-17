#if os(macOS)
    @preconcurrency import AVFoundation
    import Darwin
    import Foundation
    import TapeloopAudio
    import TapeloopCore
    import TapeloopExport
    import TapeloopIntelligence
    import TapeloopParakeet

    // Stress and sponge tests of the recording pipeline, without microphones or permissions: synthetic audio goes
    // through the real recorder engine, encoder, ring buffer, disk spill and exporter, faster than real time.
    //
    //   TapeloopBench soak [hours] [--spill]   hours of audio (default 4) into a 2-hour buffer; cost per audio hour
    //   TapeloopBench sponge                   hostile inputs and concurrent operations; must not crash or grow
    //   TapeloopBench watch                    meeting detection's Core Audio listeners see a new audio process
    //   add --leaks to any mode to run `leaks` on the process when it is done
    //   TapeloopBench model [cycles]           speech model: load time, memory while loaded, speed, unload
    //

    // MARK: - Measurements

    enum Measure {
        static func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            return user + system
        }

        /// The physical footprint (what Activity Monitor calls Memory), in bytes.
        static func footprint() -> Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
        }

        /// Bytes malloc has handed out and not had back (live objects, without fragmentation).
        static func mallocInUse() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return Int(stats.size_in_use)
        }

        static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }
    }

    // MARK: - Synthetic audio

    /// Speech-like audio: bursts of shaped noise and tones with pauses, deterministic.
    enum Synth {
        /// A planar float format; more than two channels need an explicit (discrete) channel layout.
        static func format(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
            if channels <= 2 {
                return AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
            }
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
        }

        static func buffers(
            rate: Double = 48_000, channels: AVAudioChannelCount = 2, frames: AVAudioFrameCount = 4096, count: Int = 64,
            silent: Bool = false
        ) -> [AVAudioPCMBuffer] {
            let format = Synth.format(rate: rate, channels: channels)
            var seed: UInt64 = 42
            return (0..<count).map { index in
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                buffer.frameLength = frames
                let talking = !silent && index % 8 < 5
                for channel in 0..<Int(channels) {
                    let data = buffer.floatChannelData![channel]
                    for frame in 0..<Int(frames) {
                        seed = seed &* 6_364_136_223_846_793_005 &+ 1
                        let noise = Float(Int64(bitPattern: seed >> 11) % 1000) / 4000
                        let t = Float(index * Int(frames) + frame) / Float(rate)
                        data[frame] = talking ? (sin(2 * .pi * 180 * t) * 0.3 + noise) * (0.5 + 0.5 * sin(t * 9)) : 0
                    }
                }
                return buffer
            }
        }
    }

    /// A source the bench drives by hand.
    final class ManualSource: AudioSource, @unchecked Sendable {
        let kind: SourceKind
        private let lock = NSLock()
        private var handler: AudioBufferHandler?
        init(kind: SourceKind) { self.kind = kind }
        func start(onBuffer: @escaping AudioBufferHandler, onEvent: @escaping @Sendable (SourceEvent) -> Void) throws {
            lock.withLock { handler = onBuffer }
        }
        func stop() { lock.withLock { handler = nil } }
        func push(_ buffer: AVAudioPCMBuffer, at time: Date) {
            let handler = lock.withLock { self.handler }
            handler?(buffer, time)
        }
    }

    final class SourceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var sources: [SourceKind: ManualSource] = [:]
        func set(_ source: ManualSource) { lock.withLock { sources[source.kind] = source } }
        func get(_ kind: SourceKind) -> ManualSource? { lock.withLock { sources[kind] } }
    }

    func makeEngine(_ settings: RecorderSettings, folder: URL) -> (RecorderEngine, SourceBox) {
        let box = SourceBox()
        let engine = RecorderEngine(
            settings: settings, spillFolder: folder.appendingPathComponent("spill"),
            makeSource: { kind, _ in
                let source = ManualSource(kind: kind)
                box.set(source)
                return source
            })
        return (engine, box)
    }

    func check(_ condition: Bool, _ message: String) {
        print(condition ? "  ok    \(message)" : "  FAIL  \(message)")
        if !condition { failures += 1 }
    }

    nonisolated(unsafe) var failures = 0

    func exportAndCheck(_ engine: RecorderEngine, range: TimeRange, folder: URL, mix: Bool = true) -> (
        TimeInterval, Int
    )? {
        let pieces = engine.exportPieces(for: range)
        guard !pieces.isEmpty else { return nil }
        let request = ExportRequest(
            range: range,
            sources: pieces.map {
                ExportSource(
                    source: $0.source, chunks: $0.loadChunks(), streamDescription: $0.streamDescription,
                    magicCookie: $0.magicCookie)
            }, folder: folder, title: "bench", mix: mix)
        guard let result = try? Exporter.save(request, progress: { _ in }) else { return nil }
        var bytes = 0
        var duration: TimeInterval = 0
        for file in result.files {
            bytes += (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            if let audio = try? AVAudioFile(forReading: file) {
                duration = max(duration, Double(audio.length) / audio.processingFormat.sampleRate)
            }
            try? FileManager.default.removeItem(at: file)
        }
        return (duration, bytes)
    }

    // MARK: - Soak

    func soak(hours: Double, spill: Bool) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tapeloop-bench-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let buffer: TimeInterval = spill ? 5 * 3600 : 2 * 3600
        var settings = RecorderSettings(sources: [.system])
        settings.bufferDuration = buffer
        settings.allowDisk = spill
        if spill { settings.ramLimitBytes = 50_000_000 }
        print(
            "Soak: \(hours) h of audio into a \(buffer / 3600) h buffer\(spill ? " (50 MB memory limit, disk beyond)" : "")"
        )

        let (engine, box) = makeEngine(settings, folder: folder)
        // The microphone path runs through its own sink (the engine only starts the microphone with permission).
        let micEncoder = try! AACEncoder(
            source: .microphone, sampleRate: 48_000, channels: 1, bitRate: settings.bitRate)
        let mic = CaptureSink(encoder: micEncoder, maxDuration: buffer)
        await engine.start()
        // The stand-in microphone buffer follows the same memory and disk plan as the engine's buffers.
        mic.apply(engine.status().plan, spillFolder: spill ? folder.appendingPathComponent("mic-spill") : nil)
        guard let system = box.get(.system) else {
            print("  FAIL  system source did not start")
            failures += 1
            return
        }
        let stereo = Synth.buffers(channels: 2)
        let mono = Synth.buffers(channels: 1, frames: 4800)
        let startFootprint = Measure.footprint()
        let startCPU = Measure.cpuSeconds()
        var peak = startFootprint
        var time = Date(timeIntervalSince1970: 2_000_000_000)
        let start = time
        let stereoStep = 4096.0 / 48_000
        let totalSystem = Int(hours * 3600 / stereoStep)
        var micTime = time
        var micIndex = 0
        for index in 0..<totalSystem {
            autoreleasepool {
                system.push(stereo[index % stereo.count], at: time)
                time = time.addingTimeInterval(stereoStep)
                while micTime < time {
                    mic.consume(mono[micIndex % mono.count], at: micTime)
                    micTime = micTime.addingTimeInterval(0.1)
                    micIndex += 1
                }
            }
            if index % 20_000 == 0 {
                peak = max(peak, Measure.footprint())
                let status = engine.status()
                let audio = time.timeIntervalSince(start)
                print(
                    String(
                        format: "  %5.2f h of audio  memory %@ (malloc in use %@)  buffer %@ in RAM, %@ on disk",
                        audio / 3600, Measure.mb(Measure.footprint()), Measure.mb(Measure.mallocInUse()),
                        Measure.mb(status.bytesInRAM + mic.snapshot().bytes),
                        Measure.mb(status.bytesOnDisk)))
            }
        }
        mic.flush()
        let cpu = Measure.cpuSeconds() - startCPU
        let status = engine.status()
        let audioHours = time.timeIntervalSince(start) / 3600
        print(
            String(
                format: "  CPU: %.1f s for %.2f h of two-source audio = %.2f s per hour (%.3f %% of one core)", cpu,
                audioHours, cpu / audioHours, cpu / audioHours / 36))
        print(
            "  memory: start \(Measure.mb(startFootprint)), peak \(Measure.mb(peak)), end \(Measure.mb(Measure.footprint()))"
        )
        let held = status.range.map { $0.duration } ?? 0
        check(
            abs(held - min(buffer, hours * 3600)) < 30,
            String(format: "the buffer holds %.2f h (expected %.2f h)", held / 3600, min(buffer, hours * 3600) / 3600))
        let budget = MemoryBudget(bitRates: [settings.bitRate])
        let expectedRAM = spill ? settings.ramLimitBytes : budget.bytes(for: min(buffer, hours * 3600))
        check(
            status.bytesInRAM <= Int(Double(expectedRAM) * 1.15) + 2_000_000,
            "system audio in memory \(Measure.mb(status.bytesInRAM)) stays within its budget \(Measure.mb(expectedRAM))"
        )
        if spill { check(status.bytesOnDisk > 0, "the older part is on disk (\(Measure.mb(status.bytesOnDisk)))") }
        let buffers = status.bytesInRAM + mic.snapshot().bytes
        check(
            peak - startFootprint < Int(Double(buffers) * 1.3) + 40_000_000,
            "memory growth \(Measure.mb(peak - startFootprint)) is within 30 % + 40 MB of the audio held in memory (\(Measure.mb(buffers)))"
        )

        let end = time
        for minutes in [5.0, 60, min(buffer, hours * 3600) / 60] {
            let range = TimeRange(start: end.addingTimeInterval(-minutes * 60), end: end)
            let t0 = Date()
            let result = exportAndCheck(engine, range: range, folder: folder, mix: true)
            let seconds = Date().timeIntervalSince(t0)
            check(
                (result?.0 ?? 0) > minutes * 60 - 10,
                String(
                    format: "save of the last %.0f min: %.1f s of work, file %.0f s long, %@", minutes, seconds,
                    result?.0 ?? 0, Measure.mb(result?.1 ?? 0)))
        }
        engine.wipe()
        check(engine.status().bytesInRAM == 0 && engine.status().bytesOnDisk == 0, "wipe empties memory and disk")
    }

    // MARK: - Sponge

    func sponge() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tapeloop-sponge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        print("Sponge: hostile inputs")
        let footprintStart = Measure.footprint()

        // Odd formats into one sink, back to back (a device change mid-stream).
        do {
            let encoder = try AACEncoder(source: .system, sampleRate: 48_000, channels: 1, bitRate: 48_000)
            let sink = CaptureSink(encoder: encoder, maxDuration: 600)
            var time = Date(timeIntervalSince1970: 2_000_000_000)
            for rate in [8_000.0, 16_000, 22_050, 44_100, 48_000, 96_000, 192_000] {
                for channels: AVAudioChannelCount in [1, 2, 6] {
                    for buffer in Synth.buffers(rate: rate, channels: channels, frames: 2048, count: 8) {
                        sink.consume(buffer, at: time)
                        time = time.addingTimeInterval(2048 / rate)
                    }
                }
            }
            sink.flush()
            let snapshot = sink.snapshot()
            check(
                snapshot.range != nil && snapshot.bytes > 0,
                "21 formats (8 to 192 kHz, 1, 2 and 6 channels) encode into one buffer")
        } catch {
            check(false, "encoder: \(error)")
        }

        // Degenerate buffers and values.
        let encoder = try! AACEncoder(source: .system, sampleRate: 48_000, channels: 1, bitRate: 48_000)
        let sink = CaptureSink(encoder: encoder, maxDuration: 120)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        var time = Date(timeIntervalSince1970: 2_000_000_000)
        func make(_ frames: AVAudioFrameCount, _ value: (Int) -> Float) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, frames))!
            buffer.frameLength = frames
            for channel in 0..<2 {
                for index in 0..<Int(frames) { buffer.floatChannelData![channel][index] = value(index) }
            }
            return buffer
        }
        let cases: [(String, AVAudioPCMBuffer)] = [
            ("empty buffer", make(0) { _ in 0 }),
            ("one frame", make(1) { _ in 0.5 }),
            ("65,536 frames", make(65_536) { sin(Float($0) * 0.05) }),
            ("NaN samples", make(4096) { $0 % 3 == 0 ? .nan : 0.1 }),
            ("infinite samples", make(4096) { $0 % 2 == 0 ? .infinity : -.infinity }),
            ("full-scale square wave", make(4096) { $0 % 64 < 32 ? 1 : -1 }),
            ("values far beyond full scale", make(4096) { _ in 1e9 }),
            ("DC offset", make(4096) { _ in 0.9 }),
            ("digital silence", make(4096) { _ in 0 }),
        ]
        for (name, buffer) in cases {
            sink.consume(buffer, at: time)
            time = time.addingTimeInterval(Double(buffer.frameLength) / 48_000)
            check(true, "survives \(name)")
        }
        // Timestamps: backwards, duplicate, a 3-hour jump, far future, distant past.
        let normal = make(4096) { sin(Float($0) * 0.1) * 0.2 }
        for (name, date) in [
            ("a timestamp 10 s in the past", time.addingTimeInterval(-10)), ("a duplicate timestamp", time),
            ("a 3-hour jump", time.addingTimeInterval(3 * 3600)), ("a far-future timestamp", Date.distantFuture),
            ("a distant-past timestamp", Date.distantPast),
        ] {
            sink.consume(normal, at: date)
            check(true, "survives \(name)")
        }
        sink.flush()
        let span = sink.snapshot().range?.duration ?? 0
        check(
            span <= 125,
            String(format: "the 2-minute buffer still spans at most 2 minutes (%.0f s) after the jumps", span))

        // Concurrency: feeding, settings changes, pauses, memory pressure, exports and wipes at the same time.
        var settings = RecorderSettings(sources: [.system])
        settings.bufferDuration = 600
        let (engine, box) = makeEngine(settings, folder: folder)
        await engine.start()
        let system = box.get(.system)!
        let buffers = Synth.buffers(channels: 2)
        let feedStart = Date(timeIntervalSince1970: 2_100_000_000)
        let group = DispatchGroup()
        let stop = ManagedFlag()
        DispatchQueue.global().async(group: group) {
            var t = feedStart
            var index = 0
            while !stop.value {
                autoreleasepool { system.push(buffers[index % buffers.count], at: t) }
                t = t.addingTimeInterval(4096.0 / 48_000)
                index += 1
            }
        }
        let rates = RecorderSettings.presetBitRates
        for round in 0..<200 {
            switch round % 6 {
            case 0:
                var changed = settings
                changed.bitRate = rates[round % rates.count]
                changed.bufferDuration = [300, 600, 1200][round % 3]
                engine.apply(changed)
            case 1: engine.setPaused(round % 12 == 1)
            case 2: engine.relieveMemoryPressure(critical: round % 4 == 2)
            case 3:
                let now = engine.status().range?.end ?? feedStart
                _ = exportAndCheck(
                    engine, range: TimeRange(start: now.addingTimeInterval(-30), end: now), folder: folder)
            case 4: _ = engine.status()
            default: if round % 30 == 5 { engine.wipe() }
            }
        }
        engine.setPaused(false)
        stop.value = true
        await withCheckedContinuation { continuation in group.notify(queue: .global()) { continuation.resume() } }
        check(true, "200 rounds of settings changes, pauses, memory warnings, saves and wipes while audio flows")
        let final = engine.status()
        check(final.bytesInRAM < 30_000_000, "the 10-minute buffer stays small (\(Measure.mb(final.bytesInRAM)))")
        engine.stop()
        check(
            Measure.footprint() - footprintStart < 150_000_000,
            "memory after the sponge: \(Measure.mb(Measure.footprint() - footprintStart)) above the start")
    }

    final class ManagedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    // MARK: - Speech model

    func model(cycles: Int) {
        let path = ModelStore().fileURL
        guard FileManager.default.fileExists(atPath: path.path) else {
            print("Model: not installed at \(path.path); skipped")
            return
        }
        print("Model: \(path.lastPathComponent), \(cycles) load-transcribe-unload cycles")
        // 60 s of speech, spoken by the system voice.
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tapeloop-bench-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: wav) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-o", wav.path,
            String(
                repeating:
                    "The quarterly review moved to Thursday. We agreed to ship the smaller version first and measure how people use it. ",
                count: 7),
        ]
        try? say.run()
        say.waitUntilExit()
        guard let pcm = try? ParakeetEngine.readPCM(wav), !pcm.isEmpty else {
            check(false, "could not make test speech")
            return
        }
        let seconds = Double(pcm.count) / 16_000
        let base = Measure.footprint()
        var afterUnload: [Int] = []
        for cycle in 1...cycles {
            let engine = ParakeetEngine(modelPath: path)
            let t0 = Date()
            do { try engine.load() } catch {
                check(false, "load: \(error)")
                return
            }
            let loadTime = Date().timeIntervalSince(t0)
            let loaded = Measure.footprint()
            let cpu0 = Measure.cpuSeconds()
            let t1 = Date()
            let lines = (try? engine.transcribe(pcm)) ?? []
            let work = Date().timeIntervalSince(t1)
            let cpu = Measure.cpuSeconds() - cpu0
            let peak = Measure.footprint()
            engine.unload()
            afterUnload.append(Measure.footprint())
            print(
                String(
                    format:
                        "  cycle %d: load %.2f s; %.0f s of speech in %.1f s (%.0fx real time, %.1f s CPU); %d lines; memory loaded %@, peak %@, after unload %@",
                    cycle, loadTime, seconds, work, seconds / max(work, 0.001), cpu, lines.count,
                    Measure.mb(loaded - base), Measure.mb(peak - base), Measure.mb(afterUnload.last! - base)))
            if cycle == 1 { check(lines.count > 0, "the model transcribes the test speech") }
        }
        let growth = (afterUnload.last ?? 0) - (afterUnload.first ?? 0)
        check(growth < 30_000_000, "memory after unload does not grow across cycles (\(Measure.mb(growth)))")
    }

    // MARK: - Process watching

    /// Starts the meeting detector's Core Audio listeners, plays a sound with `afplay` (a new audio process), and
    /// checks that the listeners reported the change. Real hardware; not for CI.
    func watch() {
        print("Watch: Core Audio process listeners")
        let provider = CoreAudioProcessProvider()
        let queue = DispatchQueue(label: "bench.watch")
        let count = ManagedCounter()
        let watching = provider.startWatching(on: queue) { count.add() }
        check(watching, "the listeners start (macOS 14.2 or later)")
        guard watching else { return }
        Thread.sleep(forTimeInterval: 0.5)
        let quiet = count.value
        let play = Process()
        play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        play.arguments = ["-v", "0", "/System/Library/Sounds/Tink.aiff"]
        try? play.run()
        play.waitUntilExit()
        Thread.sleep(forTimeInterval: 1)
        provider.stopWatching()
        check(quiet == 0, "no calls while nothing changes (\(quiet))")
        check(count.value > quiet, "a new audio process is reported (\(count.value - quiet) calls)")
    }

    final class ManagedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    // MARK: - Leaks

    /// Runs `leaks` on this process after the work is done (`leaks --atExit` can leave the process suspended).
    func checkLeaks() {
        let leaks = Process()
        leaks.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
        leaks.arguments = [String(getpid())]
        let pipe = Pipe()
        leaks.standardOutput = pipe
        leaks.standardError = pipe
        do { try leaks.run() } catch {
            check(false, "could not run leaks: \(error)")
            return
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        leaks.waitUntilExit()
        let summary = output.split(separator: "\n").first { $0.contains("leaks for") }.map(String.init) ?? "no summary"
        check(summary.contains(": 0 leaks"), "leaks: \(summary.trimmingCharacters(in: .whitespaces))")
    }

    // MARK: - Main

    // Line-buffered output, so a crash cannot swallow the lines printed before it.
    setvbuf(stdout, nil, _IOLBF, 0)
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first ?? "soak" {
    case "soak":
        let hours = arguments.dropFirst().first.flatMap(Double.init) ?? 4
        await soak(hours: hours, spill: arguments.contains("--spill"))
    case "sponge":
        await sponge()
    case "watch":
        watch()
    case "model":
        model(cycles: arguments.dropFirst().first.flatMap(Int.init) ?? 3)
    default:
        print("Usage: TapeloopBench soak [hours] [--spill] | sponge | model [cycles] | watch")
        exit(2)
    }
    if arguments.contains("--leaks") { checkLeaks() }
    print(failures == 0 ? "PASS" : "FAILED: \(failures)")
    exit(failures == 0 ? 0 : 1)
#else
    print("TapeloopBench runs on macOS only.")
#endif
