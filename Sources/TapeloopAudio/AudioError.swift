#if os(macOS)
import Foundation

/// Errors from capture and encoding, with plain messages for logs and the UI.
public enum AudioError: Error, CustomStringConvertible, Sendable {
    /// A Core Audio call failed with an `OSStatus`.
    case coreAudio(String, OSStatus)
    /// No usable input device (no microphone, or its format is empty).
    case noInputDevice
    /// The encoder could not be created for the format.
    case encoderUnavailable(String)
    /// The system is older than the API needs.
    case unsupportedSystem(String)

    public var description: String {
        switch self {
        case .coreAudio(let call, let status): "\(call) failed (OSStatus \(status))"
        case .noInputDevice: "No microphone is available"
        case .encoderUnavailable(let detail): "The AAC encoder is unavailable: \(detail)"
        case .unsupportedSystem(let detail): detail
        }
    }

    /// Throws `.coreAudio` when `status` is not `noErr`.
    static func check(_ status: OSStatus, _ call: String) throws {
        guard status == noErr else { throw AudioError.coreAudio(call, status) }
    }
}
#endif
