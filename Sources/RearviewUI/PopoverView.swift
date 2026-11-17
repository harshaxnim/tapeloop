#if os(macOS)
import RearviewCore
import SwiftUI

/// What the recorder is doing, as the UI shows it.
public enum RecorderStatus: String, CaseIterable, Sendable {
    case recording
    case paused
    case needsPermission

    /// A short label for the status line.
    public var label: String {
        switch self {
        case .recording: "Recording"
        case .paused: "Paused"
        case .needsPermission: "Needs permission"
        }
    }

    /// The SF Symbol used for this status.
    public var symbolName: String {
        switch self {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle"
        case .needsPermission: "exclamationmark.triangle"
        }
    }
}

/// The menu bar popover. Step s1 ships a placeholder; step s3 builds the rewind timeline here.
public struct PopoverView: View {
    let status: RecorderStatus
    let onQuit: () -> Void

    /// Creates the popover content.
    public init(status: RecorderStatus, onQuit: @escaping () -> Void = {}) {
        self.status = status
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: status.symbolName)
                    .foregroundStyle(status == .recording ? Color.red : Color.secondary)
                Text(status.label).font(.headline)
                Spacer()
            }
            Text("Rearview keeps a short, private buffer of your screen and sound on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Quit Rearview", action: onQuit)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
#endif
