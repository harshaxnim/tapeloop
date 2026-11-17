#if os(macOS)
    @preconcurrency import AVFoundation
    import TapeloopAudio
    import TapeloopCore
    import TapeloopExport
    import XCTest

    /// Feeds synthetic PCM through the encoder, the in-memory sink and the passthrough writer, then reads the file back.
    final class EncodeAndWriteTests: XCTestCase {
        private func sine(seconds: Double, rate: Double = 44_100, channels: AVAudioChannelCount = 2)
            -> [AVAudioPCMBuffer]
        {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
            let frames = 4096
            let total = Int(seconds * rate)
            var buffers: [AVAudioPCMBuffer] = []
            var written = 0
            while written < total {
                let count = min(frames, total - written)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                for channel in 0..<Int(channels) {
                    let data = buffer.floatChannelData![channel]
                    for i in 0..<count { data[i] = 0.5 * sin(2 * .pi * 440 * Double(written + i) / rate).float }
                }
                buffers.append(buffer)
                written += count
            }
            return buffers
        }

        func testTenSecondsEncodeSmallAndWriteM4A() throws {
            let sink = CaptureSink(encoder: try AACEncoder(source: .microphone, chunkSeconds: 2), maxDuration: 3600)
            let start = Date()
            var time = start
            for buffer in sine(seconds: 10) {
                sink.consume(buffer, at: time)
                time = time.addingTimeInterval(Double(buffer.frameLength) / 44_100)
            }
            sink.flush()
            let state = sink.snapshot()

            XCTAssertEqual(state.duration, 10, accuracy: 0.2)
            XCTAssertGreaterThanOrEqual(state.chunks.count, 5)
            XCTAssertEqual(Double(state.peak), 0.5, accuracy: 0.05)
            // 48 kbps for 10 s is 60 KB; raw float PCM would be 1.9 MB.
            XCTAssertLessThan(state.bytes, 120_000)
            XCTAssertGreaterThan(state.bytes, 20_000)
            print("encoded 10 s in \(state.bytes) bytes")

            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tapeloop-test-\(UUID()).m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            try M4AWriter.write(state.chunks, format: state.streamDescription, magicCookie: state.magicCookie, to: url)

            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
            XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            XCTAssertEqual(seconds, 10, accuracy: 0.2)

            // The decoded audio is the tone, not silence.
            let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
            file.framePosition = 48_000
            try file.read(into: decoded)
            let samples = UnsafeBufferPointer(start: decoded.floatChannelData![0], count: Int(decoded.frameLength))
            XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.3)
        }
    }

    extension Double {
        fileprivate var float: Float { Float(self) }
    }
#endif
