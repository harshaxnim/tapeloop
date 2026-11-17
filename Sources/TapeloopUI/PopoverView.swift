#if os(macOS)
import SwiftUI
import TapeloopCore

/// The menu bar popover. Step s1 ships the frame: status, RAM use, pause and quit. Step s3 adds the rewind
/// timeline (see docs/PLAN.md, UX section).
public struct PopoverView: View {
    let status: RecorderStatus
    let bytesInMemory: Int
    let onTogglePause: () -> Void
    let onQuit: () -> Void

    /// Creates the popover content.
    public init(
        status: RecorderStatus, bytesInMemory: Int = 0, onTogglePause: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {}
    ) {
        self.status = status
        self.bytesInMemory = bytesInMemory
        self.onTogglePause = onTogglePause
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(status == .recording ? Color.red : status == .paused ? Color.secondary : Color.orange)
                    .frame(width: 9, height: 9)
                Text(status.label).font(.headline)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(bytesInMemory), countStyle: .memory))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Memory used by the compressed buffer")
            }
            Text("Tapeloop keeps the last minutes of your microphone and system audio, compressed, in memory only. "
                + "Nothing touches the disk until you save.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(status == .recording ? "Pause" : "Resume", action: onTogglePause)
                Spacer()
                Button("Quit Tapeloop", action: onQuit)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
#endif
