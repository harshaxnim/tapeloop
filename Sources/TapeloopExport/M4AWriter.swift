#if os(macOS)
    import AudioToolbox
    import Foundation
    import TapeloopCore

    /// Writes encoded AAC chunks straight into an `.m4a` file: passthrough, no re-encode.
    public enum M4AWriter {
        /// Errors from writing.
        public enum WriteError: Error, CustomStringConvertible {
            /// An AudioToolbox call failed.
            case audioFile(String, OSStatus)

            public var description: String {
                switch self {
                case .audioFile(let call, let status): "\(call) failed (OSStatus \(status))"
                }
            }
        }

        /// Writes `chunks` (one source, in order) to `url`, replacing any file there.
        public static func write(
            _ chunks: [EncodedChunk], format: AudioStreamBasicDescription, magicCookie: Data?, to url: URL
        ) throws {
            var description = format
            var fileID: AudioFileID?
            var status = AudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &description, .eraseFile, &fileID)
            guard status == noErr, let file = fileID else {
                throw WriteError.audioFile("AudioFileCreateWithURL", status)
            }
            defer { AudioFileClose(file) }

            if let cookie = magicCookie, !cookie.isEmpty {
                status = cookie.withUnsafeBytes { raw in
                    AudioFileSetProperty(file, kAudioFilePropertyMagicCookieData, UInt32(raw.count), raw.baseAddress!)
                }
                guard status == noErr else { throw WriteError.audioFile("set magic cookie", status) }
            }

            var packetIndex: Int64 = 0
            for chunk in chunks where !chunk.packetSizes.isEmpty {
                var offset: Int64 = 0
                let descriptions = chunk.packetSizes.map { size in
                    defer { offset += Int64(size) }
                    return AudioStreamPacketDescription(
                        mStartOffset: offset, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
                }
                var count = UInt32(descriptions.count)
                status = chunk.data.withUnsafeBytes { raw in
                    AudioFileWritePackets(
                        file, false, UInt32(raw.count), descriptions, packetIndex, &count, raw.baseAddress!)
                }
                guard status == noErr else { throw WriteError.audioFile("AudioFileWritePackets", status) }
                packetIndex += Int64(count)
            }
        }
    }
#endif
