#if os(macOS)
    import CoreAudio
    import Foundation

    /// Audio hardware queries: the input devices for the microphone picker, and process objects for excluding apps'
    /// sound from the system audio.
    public enum AudioDevices {
        /// An input device.
        public struct Input: Identifiable, Hashable, Sendable {
            /// Core Audio's device ID (changes between boots).
            public var deviceID: AudioObjectID
            /// The stable unique ID (stored in Settings).
            public var uid: String
            /// The name shown to the user.
            public var name: String
            /// `id` is the UID.
            public var id: String { uid }
        }

        /// The devices that can record (have input channels), sorted by name.
        public static func inputs() -> [Input] {
            deviceIDs().compactMap { device in
                guard inputChannelCount(device) > 0, let uid = string(device, kAudioDevicePropertyDeviceUID),
                    let name = string(device, kAudioObjectPropertyName)
                else { return nil }
                return Input(deviceID: device, uid: uid, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        /// The system's default input device, if any.
        public static func defaultInput() -> Input? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var device = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            guard
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
                    == noErr
            else { return nil }
            return inputs().first { $0.deviceID == device }
        }

        /// The device with this UID, if it is connected.
        public static func device(forUID uid: String) -> AudioObjectID? {
            inputs().first { $0.uid == uid }?.deviceID
        }

        /// The Core Audio process objects whose bundle ID equals one of `bundleIDs` or starts with it followed by a
        /// dot (helper processes such as `com.google.Chrome.helper`). macOS 14.2 and later.
        @available(macOS 14.2, *)
        public static func processObjects(matching bundleIDs: [String]) -> [AudioObjectID] {
            guard !bundleIDs.isEmpty else { return [] }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            let system = AudioObjectID(kAudioObjectSystemObject)
            guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
            var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
            return objects.filter { object in
                guard let bundle = string(object, kAudioProcessPropertyBundleID) else { return false }
                return bundleIDs.contains { bundle == $0 || bundle.hasPrefix($0 + ".") }
            }
        }

        // MARK: - Helpers

        private static func deviceIDs() -> [AudioObjectID] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            let system = AudioObjectID(kAudioObjectSystemObject)
            guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
            var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
            return devices
        }

        private static func inputChannelCount(_ device: AudioObjectID) -> Int {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
            let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            return list.reduce(0) { $0 + Int($1.mNumberChannels) }
        }

        static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
                let text = value?.takeRetainedValue() as String?, !text.isEmpty
            else { return nil }
            return text
        }
    }
#endif
