#if os(macOS)
    @preconcurrency import AVFoundation
    import CoreAudio
    import Foundation
    import TapeloopCore

    /// Captures everything the Mac plays through a Core Audio process tap (macOS 14.2 and later).
    ///
    /// It creates a global stereo tap, wraps it in a private aggregate device and reads it with an IO block. It needs
    /// only the "System Audio Recording" permission (`NSAudioCaptureUsageDescription`); macOS asks the first time the
    /// device starts. When the permission is denied, the tap delivers silence rather than an error. When the default
    /// output device changes (headphones, AirPods), the tap and its aggregate device are rebuilt.
    @available(macOS 14.2, *)
    public final class SystemAudioTap: AudioSource, @unchecked Sendable {
        public let kind = SourceKind.system
        private let lock = NSLock()
        private var tapID = AudioObjectID(kAudioObjectUnknown)
        private var aggregateID = AudioObjectID(kAudioObjectUnknown)
        private var procID: AudioDeviceIOProcID?
        /// Runs the IO block. `.workItem` drains an autorelease pool after every callback: without it, the
        /// Objective-C objects each callback creates (about 94 a second) are never freed.
        private let queue = DispatchQueue(
            label: "io.github.harshaxnim.tapeloop.system-audio", qos: .userInitiated, autoreleaseFrequency: .workItem)
        private let listenerQueue = DispatchQueue(
            label: "io.github.harshaxnim.tapeloop.system-audio.devices", autoreleaseFrequency: .workItem)
        private var listener: AudioObjectPropertyListenerBlock?
        private var onBuffer: AudioBufferHandler?
        private var onEvent: (@Sendable (SourceEvent) -> Void)?
        private var excluded: [String]

        /// The PCM format the tap delivers, known after `start`.
        public private(set) var format: AVAudioFormat?

        /// Creates the source. `excludingBundleIDs` lists apps whose sound is left out (for example, a music player
        /// the user does not want in recordings); their helper processes are left out too.
        public init(excludingBundleIDs: [String] = []) {
            excluded = excludingBundleIDs
        }

        public func start(
            onBuffer: @escaping AudioBufferHandler, onEvent: @escaping @Sendable (SourceEvent) -> Void
        ) throws {
            lock.lock()
            defer { lock.unlock() }
            self.onBuffer = onBuffer
            self.onEvent = onEvent
            try startTap()
            watchDefaultOutput()
        }

        public func stop() {
            lock.lock()
            defer { lock.unlock() }
            unwatchDefaultOutput()
            stopTap()
            onBuffer = nil
            onEvent = nil
        }

        deinit { stopTap() }

        /// Call with the lock held.
        private func startTap() throws {
            guard let onBuffer else { return }
            // Excluded apps, and Tapeloop itself: a preview or the Library's player must not record itself.
            let objects =
                AudioDevices.processObjects(matching: excluded) + [AudioDevices.ownProcessObject()].compactMap { $0 }
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: objects)
            description.name = "Tapeloop"
            description.muteBehavior = .unmuted
            var tap = AudioObjectID(kAudioObjectUnknown)
            try AudioError.check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
            tapID = tap

            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var streamDescription = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try AudioError.check(
                AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &streamDescription), "kAudioTapPropertyFormat")
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw AudioError.encoderUnavailable("tap format")
            }
            self.format = format
            Log.tap.info("Tap format: \(format.description, privacy: .public)")

            let outputUID = try Self.defaultOutputDeviceUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Tapeloop System Audio",
                kAudioAggregateDeviceUIDKey: "io.github.harshaxnim.tapeloop.aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
                ],
            ]
            var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
            try AudioError.check(
                AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice),
                "AudioHardwareCreateAggregateDevice")
            aggregateID = aggregateDevice

            try AudioError.check(
                AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDevice, queue) { _, inputData, inputTime, _, _ in
                    autoreleasepool {
                        guard
                            let buffer = AVAudioPCMBuffer(
                                pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
                        else { return }
                        let valid = inputTime.pointee.mFlags.contains(.hostTimeValid)
                        onBuffer(buffer, HostClock.date(forHostTime: valid ? inputTime.pointee.mHostTime : 0))
                    }
                }, "AudioDeviceCreateIOProcIDWithBlock")
            IOBufferSize.preferLarge(aggregateDevice)
            try AudioError.check(AudioDeviceStart(aggregateDevice, procID), "AudioDeviceStart")
            Log.tap.info("System audio tap started")
        }

        /// Call with the lock held (or from deinit).
        private func stopTap() {
            if aggregateID != kAudioObjectUnknown {
                if let procID {
                    AudioDeviceStop(aggregateID, procID)
                    AudioDeviceDestroyIOProcID(aggregateID, procID)
                }
                AudioHardwareDestroyAggregateDevice(aggregateID)
            }
            if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
            procID = nil
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        private static var defaultOutputAddress: AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
        }

        private func watchDefaultOutput() {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restartAfterOutputChange() }
            var address = Self.defaultOutputAddress
            if AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
                == noErr
            {
                listener = block
            }
        }

        private func unwatchDefaultOutput() {
            guard let listener else { return }
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, listener)
            self.listener = nil
        }

        private func restartAfterOutputChange() {
            lock.lock()
            defer { lock.unlock() }
            guard onBuffer != nil else { return }
            Log.tap.info("Default output changed; rebuilding the system audio tap")
            stopTap()
            do {
                try startTap()
                onEvent?(.restarted("The sound output changed, so system audio recording restarted."))
            } catch {
                Log.tap.error("System audio restart failed: \(String(describing: error), privacy: .public)")
                onEvent?(.failed("System audio could not be recorded after the sound output changed."))
            }
        }

        /// Changes the excluded apps, or re-reads which processes they run (after an app launches); takes effect at
        /// once when running.
        public func setExcludedBundleIDs(_ bundleIDs: [String]) {
            lock.lock()
            defer { lock.unlock() }
            excluded = bundleIDs
            guard onBuffer != nil else { return }
            stopTap()
            do {
                try startTap()
            } catch {
                onEvent?(.failed("System audio could not be recorded with the new exclusions."))
            }
        }

        static func defaultOutputDeviceUID() throws -> String {
            var address = defaultOutputAddress
            var device = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try AudioError.check(
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device),
                "default output device")
            address.mSelector = kAudioDevicePropertyDeviceUID
            var uid: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            try AudioError.check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "device UID")
            guard let value = uid?.takeRetainedValue() else { throw AudioError.coreAudio("device UID", -1) }
            return value as String
        }
    }
#endif
