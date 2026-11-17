#if os(macOS)
    import AppKit
    import SwiftUI

    /// The menu bar icon: the brand cassette (upside down, notch on top) with a status dot in a notch at the
    /// bottom-right. The source is `Resources/Icons/menubar.svg`.
    ///
    /// The cassette follows the menu bar's light or dark look; the dot is coloured, so the image is not a template:
    /// amber while recording (macOS's microphone-indicator colour), grey while paused, a red ring when a permission is
    /// missing or a source failed.
    public enum CassetteIcon {
        /// The design box, in units: 25 × 17 (the cassette body is 20.8 × 13.2 at (0.5, 1.2)).
        static let box = CGSize(width: 25, height: 17)
        static let bodyOrigin = CGPoint(x: 0.5, y: 1.2)
        static let dotCentre = CGPoint(x: 21.6, y: 13.7)

        /// The icon for `status`, `width` points wide (27 by default, the status item's width), drawn crisply at any
        /// scale and in the current appearance.
        @MainActor
        public static func image(for status: RecorderStatus, width: CGFloat = 27) -> NSImage {
            let size = NSSize(width: width, height: (width * box.height / box.width).rounded(.up))
            let image = NSImage(size: size, flipped: true) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                draw(status: status, in: rect, context: context, body: NSColor.labelColor.cgColor)
                return true
            }
            image.isTemplate = false
            image.accessibilityDescription = "Tapeloop: \(status.label)"
            return image
        }

        /// Draws the icon into `rect` (y down) of `context`.
        static func draw(status: RecorderStatus, in rect: CGRect, context: CGContext, body: CGColor) {
            let s = min(rect.width / box.width, rect.height / box.height)
            let origin = CGPoint(
                x: rect.minX + (rect.width - box.width * s) / 2 + bodyOrigin.x * s,
                y: rect.minY + (rect.height - box.height * s) / 2 + bodyOrigin.y * s)
            let dot = CGPoint(
                x: origin.x + (dotCentre.x - bodyOrigin.x) * s, y: origin.y + (dotCentre.y - bodyOrigin.y) * s)

            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.addPath(CassetteGeometry.path(origin: origin, scale: s).cgPath)
            context.setFillColor(body)
            context.fillPath(using: .evenOdd)
            // The notch for the dot, cut out of the body.
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(x: dot.x - 3.55 * s, y: dot.y - 3.55 * s, width: 7.1 * s, height: 7.1 * s))
            context.setBlendMode(.normal)
            switch status {
            case .recording, .paused:
                context.setFillColor(status == .recording ? NSColor(Tape.amber).cgColor : NSColor(Tape.grey).cgColor)
                context.fillEllipse(
                    in: CGRect(x: dot.x - 2.65 * s, y: dot.y - 2.65 * s, width: 5.3 * s, height: 5.3 * s))
            case .needsAttention:
                context.setStrokeColor(NSColor(Tape.red).cgColor)
                context.setLineWidth(1.1 * s)
                context.strokeEllipse(
                    in: CGRect(x: dot.x - 2.2 * s, y: dot.y - 2.2 * s, width: 4.4 * s, height: 4.4 * s))
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }
#endif
