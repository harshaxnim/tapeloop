#if os(macOS)
    @preconcurrency import AVFoundation
    import Foundation

    /// Captures the default microphone with `AVAudioEngine` and hands each PCM buffer to a callback.
    public final class MicrophoneSource: @unchecked Sendable {
        private let engine = AVAudioEngine()

        /// Creates the source; nothing runs until `start`.
        public init() {}

        /// Asks for microphone permission when needed. Returns whether it is granted.
        public static func requestPermission() async -> Bool {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            default: return false
            }
        }

        /// Starts capture. `onBuffer` runs on an audio thread.
        public func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInputDevice }
            Log.mic.info("Mic format: \(format.description, privacy: .public)")
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in onBuffer(buffer) }
            engine.prepare()
            try engine.start()
        }

        /// Stops capture.
        public func stop() {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
#endif
