#if os(macOS)
/// What the recorder is doing, as the UI shows it.
public enum RecorderStatus: String, CaseIterable, Sendable {
    /// The buffer is filling.
    case recording
    /// The user paused; nothing is captured.
    case paused
    /// A permission is missing or a source failed.
    case needsAttention

    /// A short label for the status line.
    public var label: String {
        switch self {
        case .recording: "Recording to memory"
        case .paused: "Paused"
        case .needsAttention: "Needs permission"
        }
    }
}
#endif
