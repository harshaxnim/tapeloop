#if os(macOS)
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Captures everything the Mac plays through a Core Audio process tap (macOS 14.2 and later).
///
/// It creates a global stereo tap, wraps it in a private aggregate device and reads it with an IO block. It needs
/// only the "System Audio Recording" permission (`NSAudioCaptureUsageDescription`); macOS asks the first time the
/// device starts. When the permission is denied, the tap delivers silence rather than an error.
@available(macOS 14.2, *)
public final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "io.github.harshaxnim.tapeloop.system-audio", qos: .userInitiated)

    /// The PCM format the tap delivers, known after `start`.
    public private(set) var format: AVAudioFormat?

    /// Creates the source; nothing runs until `start`.
    public init() {}

    /// Starts capture. `onBuffer` runs on a private queue; the buffer is only valid during the call.
    public func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
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
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDevice, queue) { _, inputData, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
                else { return }
                onBuffer(buffer)
            }, "AudioDeviceCreateIOProcIDWithBlock")
        try AudioError.check(AudioDeviceStart(aggregateDevice, procID), "AudioDeviceStart")
        Log.tap.info("System audio tap started")
    }

    /// Stops capture and destroys the tap and the aggregate device.
    public func stop() {
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

    deinit { stop() }

    static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
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
