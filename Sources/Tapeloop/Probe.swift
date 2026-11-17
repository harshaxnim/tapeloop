#if os(macOS)
    import Foundation
    import TapeloopAudio
    import TapeloopCore
    import TapeloopExport
    import os

    /// `Tapeloop --probe`: records the microphone and the system audio at the same time for a few seconds, keeps
    /// them encoded in RAM, prints the byte counts and writes each source to an `.m4a` file.
    ///
    /// It proves the riskiest assumption (the process tap works on the user's Mac) before the full engine exists.
    enum Probe {
        private static let log = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "probe")

        static func run(seconds: Double, folder: URL) async -> String {
            var lines = ["Tapeloop probe: \(Int(seconds)) s of microphone and system audio"]
            func say(_ line: String) {
                lines.append(line)
                log.info("\(line, privacy: .public)")
            }
            let info = ProcessInfo.processInfo
            say("macOS \(info.operatingSystemVersionString)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                say("FAIL cannot create \(folder.path): \(error)")
                return finish(lines, folder: folder)
            }

            var sinks: [(SourceKind, CaptureSink)] = []
            let mic = MicrophoneSource()
            var micRunning = false
            if await MicrophoneSource.requestPermission() {
                do {
                    let sink = CaptureSink(encoder: try AACEncoder(source: .microphone), maxDuration: 3600)
                    try mic.start(onBuffer: { buffer, time in sink.consume(buffer, at: time) }, onEvent: { _ in })
                    micRunning = true
                    sinks.append((.microphone, sink))
                    say("microphone: started")
                } catch {
                    say("FAIL microphone: \(error)")
                }
            } else {
                say("FAIL microphone: permission denied (System Settings > Privacy & Security > Microphone)")
            }

            var stopTap: (() -> Void)?
            if #available(macOS 14.2, *) {
                let tap = SystemAudioTap()
                do {
                    let sink = CaptureSink(encoder: try AACEncoder(source: .system), maxDuration: 3600)
                    try tap.start(onBuffer: { buffer, time in sink.consume(buffer, at: time) }, onEvent: { _ in })
                    stopTap = { tap.stop() }
                    sinks.append((.system, sink))
                    say("system audio: started (process tap, format \(tap.format?.description ?? "?"))")
                } catch {
                    say("FAIL system audio: \(error)")
                }
            } else {
                say("FAIL system audio: the process tap needs macOS 14.2 or later")
            }

            try? await Task.sleep(for: .seconds(seconds))
            if micRunning { mic.stop() }
            stopTap?()

            for (kind, sink) in sinks {
                sink.flush()
                let state = sink.snapshot()
                let pcmBytes = Int(state.duration * 48_000 * 4)
                let peakDB = state.peak > 0 ? 20 * log10(Double(state.peak)) : -.infinity
                say(
                    "\(kind.rawValue): \(state.buffersSeen) buffers, \(String(format: "%.1f", state.duration)) s encoded, "
                        + "\(state.bytes) bytes in RAM (raw PCM would be \(pcmBytes)), "
                        + "peak \(String(format: "%.1f", peakDB)) dBFS")
                if state.buffersSeen == 0 { say("FAIL \(kind.rawValue): no audio buffers arrived") }
                if state.peak == 0 && state.buffersSeen > 0 {
                    say("WARN \(kind.rawValue): only silence (permission denied, or nothing was playing / said)")
                }
                let url = folder.appendingPathComponent("probe-\(kind.rawValue).m4a")
                do {
                    try M4AWriter.write(
                        state.chunks, format: state.streamDescription, magicCookie: state.magicCookie, to: url)
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    say("\(kind.rawValue): wrote \(url.path) (\(size) bytes)")
                } catch {
                    say("FAIL \(kind.rawValue): writing \(url.lastPathComponent): \(error)")
                }
            }
            return finish(lines, folder: folder)
        }

        private static func finish(_ lines: [String], folder: URL) -> String {
            let failed = lines.contains { $0.hasPrefix("FAIL") }
            let report = (lines + [failed ? "RESULT: FAIL" : "RESULT: OK"]).joined(separator: "\n") + "\n"
            try? report.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            return report
        }
    }
#endif
