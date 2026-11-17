#if os(macOS)
    @preconcurrency import AVFoundation
    import Foundation
    import TapeloopCore

    /// Captures a microphone: the device with `deviceUID`, or the system default input.
    ///
    /// It reads the device directly from Core Audio (``HALInput``: one callback every 85 ms, no extra threads) and
    /// falls back to `AVAudioEngine` for devices that path cannot read. When the input changes (a headset plugged in
    /// or removed, a new default input, a new sample rate), it restarts on the new device or format.
    public final class MicrophoneSource: AudioSource, @unchecked Sendable {
        public let kind = SourceKind.microphone
        private let lock = NSLock()
        private var engine: AVAudioEngine?
        private var observer: NSObjectProtocol?
        private var hal: HALInput?
        private let watcher = AudioPropertyWatcher()
        private var restartToken = 0
        private var onBuffer: AudioBufferHandler?
        private var onEvent: (@Sendable (SourceEvent) -> Void)?

        private let deviceUID: String?

        /// Creates the source; nothing runs until `start`. `deviceUID` picks a specific input device; `nil` (or a
        /// device that is not connected) follows the system default.
        public init(deviceUID: String? = nil) {
            self.deviceUID = deviceUID
        }

        /// Whether the user has granted microphone access.
        public static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

        /// Whether the user has already answered the microphone prompt (granted or denied).
        public static var isDetermined: Bool { AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined }

        /// Asks for microphone permission when needed. Returns whether it is granted.
        public static func requestPermission() async -> Bool {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            default: return false
            }
        }

        public func start(
            onBuffer: @escaping AudioBufferHandler, onEvent: @escaping @Sendable (SourceEvent) -> Void
        ) throws {
            lock.lock()
            defer { lock.unlock() }
            self.onBuffer = onBuffer
            self.onEvent = onEvent
            try startEngine()
        }

        public func stop() {
            lock.lock()
            defer { lock.unlock() }
            stopCapture()
            onBuffer = nil
            onEvent = nil
        }

        /// Call with the lock held.
        private func stopCapture() {
            watcher.removeAll()
            hal?.stop()
            hal = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
        }

        /// The device to record: the chosen one if connected, else the system default.
        private func targetDevice() -> AudioObjectID? {
            if let deviceUID, let device = AudioDevices.device(forUID: deviceUID) { return device }
            return AudioDevices.defaultInput()?.deviceID
        }

        /// Call with the lock held.
        private func startEngine() throws {
            guard let onBuffer else { return }
            // Restart when the default input changes (only matters when following it), or the device goes away or
            // changes its sample rate.
            watcher.watch(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) {
                [weak self] in self?.restartAfterChange()
            }
            if let device = targetDevice(), let format = HALInput.format(of: device) {
                let input = HALInput(device: device, format: format)
                do {
                    try input.start(onBuffer)
                    hal = input
                    watcher.watch(device, kAudioDevicePropertyDeviceIsAlive) { [weak self] in self?.restartAfterChange()
                    }
                    watcher.watch(device, kAudioDevicePropertyNominalSampleRate) { [weak self] in
                        self?.restartAfterChange()
                    }
                    Log.mic.info("Mic (direct): \(format.description, privacy: .public)")
                    return
                } catch {
                    Log.mic.error(
                        "Direct microphone capture failed, using AVAudioEngine: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            try startAVAudioEngine(onBuffer)
        }

        /// Call with the lock held.
        private func startAVAudioEngine(_ onBuffer: @escaping AudioBufferHandler) throws {
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            if let deviceUID, var device = AudioDevices.device(forUID: deviceUID), let unit = input.audioUnit {
                let status = AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                    UInt32(MemoryLayout<AudioObjectID>.size))
                if status != noErr { Log.mic.error("Could not select the chosen microphone (OSStatus \(status))") }
            }
            if let unit = input.audioUnit {
                // About 85 ms per IO cycle instead of about 11 ms: fewer wake-ups; per-process, so other apps are
                // not affected.
                var frames: UInt32 = 4096
                AudioUnitSetProperty(
                    unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames,
                    UInt32(MemoryLayout<UInt32>.size))
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInputDevice }
            Log.mic.info("Mic format: \(format.description, privacy: .public)")
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
                autoreleasepool {
                    onBuffer(buffer, HostClock.date(forHostTime: when.isHostTimeValid ? when.hostTime : 0))
                }
            }
            engine.prepare()
            try engine.start()
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { [weak self] _ in self?.restartAfterChange() }
            }
        }

        private func restartAfterChange() {
            // Device changes arrive in bursts (new default, old device gone, new rate). Wait for the burst to end,
            // and never restart from inside a Core Audio listener callback.
            let token = lock.withLock { () -> Int in
                restartToken += 1
                return restartToken
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.restart(ifLatest: token)
            }
        }

        private func restart(ifLatest token: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard onBuffer != nil, token == restartToken else { return }
            Log.mic.info("Input configuration changed; restarting the microphone")
            stopCapture()
            do {
                try startEngine()
                onEvent?(.restarted("The microphone changed, so recording restarted."))
            } catch {
                Log.mic.error("Microphone restart failed: \(String(describing: error), privacy: .public)")
                onEvent?(.failed("No microphone is available."))
            }
        }
    }
#endif
