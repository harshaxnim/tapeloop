#if os(macOS)
    @preconcurrency import AVFoundation
    import Foundation
    import TapeloopCore

    /// Plays a span of the buffer without saving it: the sources are decoded and mixed one second at a time (the same
    /// reader a save uses) and queued on an audio player a few seconds ahead, so a preview of hours starts at once and
    /// needs a few hundred kilobytes. Nothing is written to disk.
    ///
    /// Thread-safe. `onFinish` is called on the main queue when playback reaches the end (not after ``stop()``).
    public final class PreviewPlayer: @unchecked Sendable {
        /// The length of the span being played, in seconds.
        public let duration: TimeInterval

        private let engine = AVAudioEngine()
        private let player = AVAudioPlayerNode()
        private let format: AVAudioFormat
        private let readers: [SourceReader]
        private let totalFrames: Int
        private let queue = DispatchQueue(
            label: "io.github.harshaxnim.tapeloop.preview", qos: .userInitiated, autoreleaseFrequency: .workItem)
        private let lock = NSLock()
        private var position = 0
        private var inFlight = 0
        private var stopped = false
        private var completed = false
        private var onFinish: (@Sendable () -> Void)?

        /// How many one-second blocks are queued ahead of what is heard.
        private static let lookahead = 3

        /// Prepares a preview of `range` from `sources`. Throws when a source cannot be decoded.
        public init(sources: [ExportSource], range: TimeRange) throws {
            guard
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: Mixer.sampleRate, channels: 1, interleaved: false)
            else { throw Exporter.ExportError.write("PCM format") }
            self.format = format
            readers = try sources.map { try SourceReader(source: $0, rangeStart: range.start, pcm: format) }
            duration = range.duration
            totalFrames = Int((range.duration * Mixer.sampleRate).rounded())
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }

        deinit { stop() }

        /// Starts playing from the beginning of the span.
        public func start(onFinish: @escaping @Sendable () -> Void) throws {
            lock.withLock { self.onFinish = onFinish }
            try engine.start()
            player.play()
            queue.async { [self] in
                for _ in 0..<Self.lookahead { scheduleNext() }
            }
        }

        /// Stops playback at once. Safe to call more than once.
        public func stop() {
            let wasPlaying = lock.withLock { () -> Bool in
                defer { stopped = true }
                return !stopped
            }
            guard wasPlaying else { return }
            player.stop()
            engine.stop()
        }

        /// The playback volume, 0 to 1.
        public var volume: Float {
            get { engine.mainMixerNode.outputVolume }
            set { engine.mainMixerNode.outputVolume = newValue }
        }

        /// The seconds heard so far.
        public var elapsed: TimeInterval {
            if lock.withLock({ completed }) { return duration }
            guard let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else {
                return 0
            }
            return min(duration, max(0, Double(time.sampleTime) / time.sampleRate))
        }

        /// Call on `queue`: mixes the next block and queues it, or finishes when everything has been played.
        private func scheduleNext() {
            let (start, done) = lock.withLock { () -> (Int, Bool) in
                if stopped { return (0, true) }
                return (position, position >= totalFrames)
            }
            if done {
                finishIfIdle()
                return
            }
            let count = min(Mixer.blockFrames, totalFrames - start)
            guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                return
            }
            let out = block.floatChannelData![0]
            for index in 0..<count { out[index] = 0 }
            for reader in readers {
                let samples = reader.take(count, at: start)
                for index in 0..<count { out[index] += samples[index] }
            }
            for index in 0..<count { out[index] = max(-1, min(1, out[index])) }
            block.frameLength = AVAudioFrameCount(count)
            lock.withLock {
                position = start + count
                inFlight += 1
            }
            player.scheduleBuffer(block, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.lock.withLock { self.inFlight -= 1 }
                    self.scheduleNext()
                }
            }
        }

        /// Call on `queue`: reports the end once the last block has been heard.
        private func finishIfIdle() {
            let handler = lock.withLock { () -> (@Sendable () -> Void)? in
                guard inFlight == 0, !stopped else { return nil }
                stopped = true
                completed = true
                defer { onFinish = nil }
                return onFinish
            }
            guard let handler else { return }
            player.stop()
            engine.stop()
            DispatchQueue.main.async { handler() }
        }
    }
#endif
