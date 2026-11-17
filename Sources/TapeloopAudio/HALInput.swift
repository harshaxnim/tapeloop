#if os(macOS)
    @preconcurrency import AVFoundation
    import CoreAudio
    import Foundation

    /// Reads an input device straight from Core Audio with one IO callback, at about 85 ms per callback.
    ///
    /// It replaces `AVAudioEngine` for the microphone where it can: the engine runs extra threads and a parameter
    /// refresher that a recorder does not need. It handles devices with one input stream of float samples (nearly all
    /// microphones); for anything else ``format(of:)`` returns `nil` and the caller uses `AVAudioEngine`.
    final class HALInput: @unchecked Sendable {
        let device: AudioObjectID
        let format: AVAudioFormat
        private var procID: AudioDeviceIOProcID?
        private let queue = DispatchQueue(
            label: "io.github.harshaxnim.tapeloop.microphone", qos: .userInitiated, autoreleaseFrequency: .workItem)

        init(device: AudioObjectID, format: AVAudioFormat) {
            self.device = device
            self.format = format
        }

        /// The format the device delivers on its input, or `nil` when it is not one stream of float samples.
        static func format(of device: AudioObjectID) -> AVAudioFormat? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
                size == UInt32(MemoryLayout<AudioObjectID>.size)
            else { return nil }
            var stream = AudioObjectID(kAudioObjectUnknown)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &stream) == noErr else { return nil }
            address = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var description = AudioStreamBasicDescription()
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &description) == noErr,
                description.mFormatID == kAudioFormatLinearPCM,
                description.mFormatFlags & kAudioFormatFlagIsFloat != 0, description.mBitsPerChannel == 32,
                description.mChannelsPerFrame > 0, description.mSampleRate > 0
            else { return nil }
            return AVAudioFormat(streamDescription: &description)
        }

        /// Starts delivering buffers.
        func start(_ onBuffer: @escaping AudioBufferHandler) throws {
            let format = self.format
            IOBufferSize.preferLarge(device)
            try AudioError.check(
                AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, inputData, inputTime, _, _ in
                    autoreleasepool {
                        guard inputData.pointee.mNumberBuffers > 0, inputData.pointee.mBuffers.mDataByteSize > 0,
                            let buffer = AVAudioPCMBuffer(
                                pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
                        else { return }
                        let valid = inputTime.pointee.mFlags.contains(.hostTimeValid)
                        onBuffer(buffer, HostClock.date(forHostTime: valid ? inputTime.pointee.mHostTime : 0))
                    }
                }, "AudioDeviceCreateIOProcIDWithBlock (microphone)")
            do {
                try AudioError.check(AudioDeviceStart(device, procID), "AudioDeviceStart (microphone)")
            } catch {
                stop()
                throw error
            }
        }

        func stop() {
            guard let procID else { return }
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
            self.procID = nil
        }

        deinit { stop() }
    }

    enum IOBufferSize {
        /// Asks for about 85 ms per IO callback (4096 frames at 48 kHz) instead of the default of about 11 ms: the
        /// recording does not need low latency, and fewer callbacks mean fewer wake-ups. The buffer size is a
        /// per-process setting, so other apps' audio is not affected.
        static func preferLarge(_ device: AudioObjectID, frames: UInt32 = 4096) {
            var rangeAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSizeRange, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var range = AudioValueRange()
            var size = UInt32(MemoryLayout<AudioValueRange>.size)
            let maximum =
                AudioObjectGetPropertyData(device, &rangeAddress, 0, nil, &size, &range) == noErr
                ? UInt32(range.mMaximum) : frames
            var value = min(frames, maximum)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            Log.engine.info("IO buffer of device \(device): \(value) frames (status \(status))")
        }
    }

    /// Listens to Core Audio properties and calls back on a private queue; removes its listeners when released.
    final class AudioPropertyWatcher: @unchecked Sendable {
        private let queue = DispatchQueue(
            label: "io.github.harshaxnim.tapeloop.device-watch", autoreleaseFrequency: .workItem)
        private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

        /// Calls `handler` when `selector` of `object` changes.
        func watch(
            _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping @Sendable () -> Void
        ) {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
                registrations.append((object, address, block))
            }
        }

        func removeAll() {
            for (object, address, block) in registrations {
                var address = address
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            }
            registrations = []
        }

        deinit { removeAll() }
    }
#endif
