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
                Text(
                    "Tapeloop keeps the last minutes of your microphone and system audio, compressed, in memory only. "
                        + "Nothing touches the disk until you save."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(status == .recording ? "Pause" : "Resume", action: onTogglePause)
                        .buttonStyle(TapeButtonStyle(prominent: true))
                    Spacer()
                    Button("Quit Tapeloop", action: onQuit)
                        .buttonStyle(TapeButtonStyle())
                }
            }
            .padding(16)
            .frame(width: 360)
        }
    }

    /// Tapeloop's button look: a rounded pill drawn in SwiftUI (so snapshots render it too).
    public struct TapeButtonStyle: ButtonStyle {
        var prominent = false

        /// Creates the style; `prominent` fills it with the accent colour.
        public init(prominent: Bool = false) {
            self.prominent = prominent
        }

        public func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(prominent ? Color.accentColor : Color.primary.opacity(0.08))
                )
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
#endif
