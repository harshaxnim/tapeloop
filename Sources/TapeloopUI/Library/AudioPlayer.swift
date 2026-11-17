#if os(macOS)
    import AVFoundation
    import Foundation
    import Observation
    import TapeloopCore
    import os

    /// Plays one audio file for the Library, with a variable speed and a position that updates about ten times a
    /// second while playing.
    @MainActor
    @Observable
    public final class AudioPlayer {
        /// The speeds the Library offers.
        public static let rates: [Float] = [1, 1.25, 1.5, 2]

        /// The loaded file.
        public private(set) var url: URL?
        /// The position in seconds.
        public private(set) var currentTime: TimeInterval = 0
        /// The file's length in seconds (the expected length until the file is loaded).
        public private(set) var duration: TimeInterval = 0
        /// Whether audio is playing.
        public private(set) var isPlaying = false
        /// Why the file cannot be played, when it cannot.
        public private(set) var loadError: String?
        /// The playback speed, 1 being normal. It is kept when another file is loaded.
        public var rate: Float = 1 {
            didSet { player?.rate = rate }
        }

        @ObservationIgnored private var player: AVAudioPlayer?
        @ObservationIgnored private var timer: Timer?

        /// Creates a player with nothing loaded.
        public init() {}

        /// The position as a fraction of the length, 0 to 1.
        public var progress: Double { duration > 0 ? min(1, max(0, currentTime / duration)) : 0 }

        /// Stops playback and loads `url` (or nothing). `expectedDuration` is shown until the file reports its own.
        public func load(_ url: URL?, expectedDuration: TimeInterval? = nil) {
            stop()
            player = nil
            self.url = url
            currentTime = 0
            duration = expectedDuration ?? 0
            loadError = nil
            guard let url else { return }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.enableRate = true
                player.rate = rate
                player.prepareToPlay()
                self.player = player
                duration = player.duration
            } catch {
                loadError = "This file cannot be played."
                LibraryLog.player.error(
                    "Cannot open \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        /// Starts or resumes playback; from the start when the end was reached.
        public func play() {
            guard let player else { return }
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            player.rate = rate
            guard player.play() else { return }
            isPlaying = true
            currentTime = player.currentTime
            startTimer()
        }

        /// Pauses playback, keeping the position.
        public func pause() {
            player?.pause()
            isPlaying = false
            stopTimer()
            if let player { currentTime = player.currentTime }
        }

        /// Plays when paused, pauses when playing.
        public func togglePlayPause() {
            isPlaying ? pause() : play()
        }

        /// Moves to `time` seconds (clamped to the file).
        public func seek(to time: TimeInterval) {
            let clamped = min(max(0, time), duration)
            player?.currentTime = clamped
            currentTime = clamped
        }

        /// Stops playback and goes back to the start.
        public func stop() {
            player?.stop()
            player?.currentTime = 0
            isPlaying = false
            currentTime = 0
            stopTimer()
        }

        /// Records that the loaded file was renamed; playback continues from the open file.
        func fileMoved(to url: URL) {
            self.url = url
        }

        /// Shows a position without a playable file (for sample data and previews).
        func preview(url: URL?, currentTime: TimeInterval, duration: TimeInterval) {
            load(nil)
            self.url = url
            self.duration = duration
            self.currentTime = min(max(0, currentTime), duration)
        }

        private func startTimer() {
            stopTimer()
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                MainActor.assumeIsolated { self.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func stopTimer() {
            timer?.invalidate()
            timer = nil
        }

        private func tick() {
            guard let player else { return stopTimer() }
            currentTime = player.currentTime
            if !player.isPlaying {
                // Reached the end.
                isPlaying = false
                currentTime = duration
                stopTimer()
            }
        }
    }

    /// Loggers for the Library. Read them with
    /// `log show --predicate 'subsystem == "io.github.harshaxnim.tapeloop" && category BEGINSWITH "library"'`.
    enum LibraryLog {
        static let library = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "library")
        static let player = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "library-player")
    }
#endif
