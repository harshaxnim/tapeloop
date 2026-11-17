#if os(macOS)
import AppKit

/// The menu bar icon: an original cassette tape, drawn in code as a template image (it follows the menu bar's
/// light or dark look). The SVG source is `Resources/Icons/cassette-template.svg`.
///
/// States: recording shows a filled dot in the top-right corner; paused shows pause bars between the reels; needs
/// attention shows an exclamation badge.
public enum CassetteIcon {
    /// The icon for `status`, 18 x 18 points, drawn crisply at any scale.
    @MainActor
    public static func image(for status: RecorderStatus, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(status: status, in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tapeloop: \(status.label)"
        return image
    }

    /// Draws the cassette in a square `rect` using a top-left origin (`flipped`).
    static func draw(status: RecorderStatus, in rect: NSRect) {
        let s = rect.width / 18
        NSColor.black.setStroke()
        NSColor.black.setFill()

        // Shell.
        let shell = NSBezierPath(
            roundedRect: NSRect(x: 1 * s, y: 3.5 * s, width: 16 * s, height: 11 * s), xRadius: 2 * s, yRadius: 2 * s)
        shell.lineWidth = 1.3 * s
        shell.stroke()
        // Tape-head notch at the bottom.
        let notch = NSBezierPath()
        notch.move(to: NSPoint(x: 5 * s, y: 14.5 * s))
        notch.line(to: NSPoint(x: 6.2 * s, y: 12 * s))
        notch.line(to: NSPoint(x: 11.8 * s, y: 12 * s))
        notch.line(to: NSPoint(x: 13 * s, y: 14.5 * s))
        notch.lineWidth = 1.1 * s
        notch.stroke()

        // Reels.
        for x in [6.0, 12.0] {
            let reel = NSBezierPath(ovalIn: NSRect(x: (x - 2) * s, y: 6.2 * s, width: 4 * s, height: 4 * s))
            reel.lineWidth = 1.1 * s
            reel.stroke()
            NSBezierPath(ovalIn: NSRect(x: (x - 0.7) * s, y: 7.5 * s, width: 1.4 * s, height: 1.4 * s)).fill()
        }

        switch status {
        case .recording:
            // A solid dot, cut out of the shell so it reads at 16 pt.
            clearCircle(center: NSPoint(x: 15 * s, y: 3.5 * s), radius: 3.2 * s)
            NSBezierPath(ovalIn: NSRect(x: 12.6 * s, y: 1.1 * s, width: 4.8 * s, height: 4.8 * s)).fill()
        case .paused:
            NSBezierPath(rect: NSRect(x: 8.2 * s, y: 6.6 * s, width: 0.6 * s, height: 3.4 * s)).fill()
            NSBezierPath(rect: NSRect(x: 9.2 * s, y: 6.6 * s, width: 0.6 * s, height: 3.4 * s)).fill()
        case .needsAttention:
            clearCircle(center: NSPoint(x: 15 * s, y: 3.5 * s), radius: 3.4 * s)
            let badge = NSBezierPath(ovalIn: NSRect(x: 12.4 * s, y: 0.9 * s, width: 5.2 * s, height: 5.2 * s))
            badge.lineWidth = 1 * s
            badge.stroke()
            NSBezierPath(rect: NSRect(x: 14.55 * s, y: 1.9 * s, width: 0.9 * s, height: 2.1 * s)).fill()
            NSBezierPath(rect: NSRect(x: 14.55 * s, y: 4.4 * s, width: 0.9 * s, height: 0.8 * s)).fill()
        }
    }

    private static func clearCircle(center: NSPoint, radius: CGFloat) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .clear
        NSBezierPath(
            ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ).fill()
        context.restoreGraphicsState()
    }
}
#endif
