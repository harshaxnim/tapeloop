#if os(macOS)
    import AVFoundation
    import Accelerate
    import SwiftUI
    import TapeloopCore

    /// A flag on the waveform.
    public struct WaveformMarker: Hashable, Sendable {
        /// Where it sits, as a fraction of the length (0 to 1).
        public var fraction: Double
        /// Its label, if any.
        public var label: String?

        /// Creates a marker.
        public init(fraction: Double, label: String? = nil) {
            self.fraction = fraction
            self.label = label
        }
    }

    /// A recording's waveform as bars: the played part amber, the rest grey; bookmarks as flags. Clicking or dragging
    /// moves the playhead.
    public struct WaveformView: View {
        let peaks: [Float]?
        let progress: Double
        let markers: [WaveformMarker]
        let onSeek: (Double) -> Void

        /// Creates the view. `peaks` are levels from 0 to 1 (`nil` while they load); `progress` is the playhead, 0 to
        /// 1; `onSeek` receives the clicked fraction.
        public init(
            peaks: [Float]?, progress: Double, markers: [WaveformMarker] = [], onSeek: @escaping (Double) -> Void
        ) {
            self.peaks = peaks
            self.progress = progress
            self.markers = markers
            self.onSeek = onSeek
        }

        /// Bar pitch and width in points.
        private let pitch: CGFloat = 4
        private let barWidth: CGFloat = 2.6

        public var body: some View {
            GeometryReader { geometry in
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard geometry.size.width > 0 else { return }
                            onSeek(min(1, max(0, value.location.x / geometry.size.width)))
                        }
                )
            }
            .frame(height: 46)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(Int((progress * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onSeek(min(1, progress + 0.05))
                case .decrement: onSeek(max(0, progress - 0.05))
                @unknown default: break
                }
            }
        }

        private func draw(in context: inout GraphicsContext, size: CGSize) {
            let mid = size.height / 2
            let playedX = size.width * progress
            let rest = GraphicsContext.Shading.color(Color.primary.opacity(0.35))
            let played = GraphicsContext.Shading.color(Tape.amber)
            let count = max(1, Int(size.width / pitch))
            let levels = peaks.map { Self.resample($0, to: count) }
            for i in 0..<count {
                let x = CGFloat(i) * pitch
                let level = CGFloat(levels?[i] ?? 0)
                let height = max(1, level * (size.height - 4))
                let bar = Path(CGRect(x: x, y: mid - height / 2, width: barWidth, height: height))
                context.fill(bar, with: x + barWidth / 2 <= playedX ? played : rest)
            }
            for marker in markers {
                let x = min(size.width - 1.5, max(0, size.width * marker.fraction))
                context.fill(
                    Path(CGRect(x: x, y: 0, width: 1.5, height: size.height)),
                    with: .color(Color.primary.opacity(0.55)))
                var flag = Path()
                flag.move(to: CGPoint(x: x, y: 0))
                flag.addLine(to: CGPoint(x: x + 8, y: 0))
                flag.addLine(to: CGPoint(x: x + 5.8, y: 3))
                flag.addLine(to: CGPoint(x: x + 8, y: 6))
                flag.addLine(to: CGPoint(x: x, y: 6))
                flag.closeSubpath()
                context.fill(flag, with: .color(.primary))
            }
            if peaks != nil || progress > 0 {
                context.fill(
                    Path(CGRect(x: min(size.width - 2, max(0, playedX - 1)), y: 0, width: 2, height: size.height)),
                    with: played)
            }
        }

        /// `peaks` reduced or stretched to `count` values (each the maximum of the peaks it covers).
        static func resample(_ peaks: [Float], to count: Int) -> [Float] {
            guard !peaks.isEmpty, count > 0 else { return [Float](repeating: 0, count: max(0, count)) }
            return (0..<count).map { i in
                let lower = i * peaks.count / count
                let upper = max(lower + 1, (i + 1) * peaks.count / count)
                return peaks[lower..<min(upper, peaks.count)].max() ?? 0
            }
        }
    }

    // MARK: - Peaks

    /// Computes and remembers waveform peaks per file. Files are decoded off the main thread, one request per file
    /// at a time.
    public actor WaveformCache {
        /// The shared cache.
        public static let shared = WaveformCache()

        private var cache: [URL: [Float]] = [:]
        private var running: [URL: Task<[Float]?, Never>] = [:]

        /// The file's peaks (levels 0 to 1), computed on first use; `nil` when the file cannot be read.
        public func peaks(for url: URL, count: Int = 600) async -> [Float]? {
            if let cached = cache[url] { return cached }
            if let task = running[url] { return await task.value }
            let task = Task.detached(priority: .utility) { try? WaveformCache.computePeaks(url: url, count: count) }
            running[url] = task
            let result = await task.value
            running[url] = nil
            if let result { cache[url] = result }
            return result
        }

        /// Keeps the peaks of a renamed file.
        public func move(from old: URL, to new: URL) {
            cache[new] = cache.removeValue(forKey: old)
        }

        /// Forgets a file's peaks.
        public func remove(_ url: URL) {
            cache[url] = nil
        }

        /// Reads the whole file in blocks and returns `count` peak levels, scaled so the loudest is 1.
        nonisolated static func computePeaks(url: URL, count: Int) throws -> [Float] {
            let file = try AVAudioFile(forReading: url)
            let total = file.length
            guard total > 0, count > 0 else { return [] }
            let format = file.processingFormat
            let blockSize: AVAudioFrameCount = 1 << 16
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else { return [] }
            var peaks = [Float](repeating: 0, count: count)
            var position: Int64 = 0
            while position < total {
                try file.read(into: buffer, frameCount: blockSize)
                let frames = Int(buffer.frameLength)
                guard frames > 0, let channels = buffer.floatChannelData else { break }
                // Walk the block bin by bin, taking the largest magnitude of each run with vDSP.
                var offset = 0
                while offset < frames {
                    let bin = min(count - 1, Int((position + Int64(offset)) * Int64(count) / total))
                    let binEnd = (Int64(bin) + 1) * total / Int64(count)
                    let run = max(1, min(frames - offset, Int(binEnd - position) - offset))
                    for channel in 0..<Int(format.channelCount) {
                        var level: Float = 0
                        vDSP_maxmgv(channels[channel] + offset, 1, &level, vDSP_Length(run))
                        peaks[bin] = max(peaks[bin], level)
                    }
                    offset += run
                }
                position += Int64(frames)
            }
            let loudest = peaks.max() ?? 0
            guard loudest > 0 else { return peaks }
            // A gentle curve so quiet speech is still visible next to loud parts.
            return peaks.map { pow($0 / loudest, 0.7) }
        }
    }
#endif
