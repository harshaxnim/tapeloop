// Draws Tapeloop's app icon (the white cassette, notch on top, on a flat graphite tile) and writes an .iconset.
// The design matches Resources/Icons/app-icon.svg; the cassette geometry matches CassetteGeometry in
// Sources/TapeloopUI/Theme.swift (keep them in sync). No gradients, no status dot.
// Usage: swift scripts/make-icon.swift <out.iconset>   then: iconutil -c icns <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The cassette (design units, y down, body top-left at `origin`, `s` points per unit) as one even-odd path.
func cassette(origin: CGPoint, scale s: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let (x0, y0, w, h, c) = (origin.x, origin.y, 20.8 * s, 13.2 * s, 0.9 * s)
    p.move(to: CGPoint(x: x0 + c, y: y0))
    p.addLine(to: CGPoint(x: x0 + 4.56875 * s, y: y0))
    p.addLine(to: CGPoint(x: x0 + 5.6 * s, y: y0 + 2.2 * s))
    p.addLine(to: CGPoint(x: x0 + 15.2 * s, y: y0 + 2.2 * s))
    p.addLine(to: CGPoint(x: x0 + 16.23125 * s, y: y0))
    p.addLine(to: CGPoint(x: x0 + w - c, y: y0))
    p.addArc(tangent1End: CGPoint(x: x0 + w, y: y0), tangent2End: CGPoint(x: x0 + w, y: y0 + c), radius: c)
    p.addLine(to: CGPoint(x: x0 + w, y: y0 + h - c))
    p.addArc(tangent1End: CGPoint(x: x0 + w, y: y0 + h), tangent2End: CGPoint(x: x0 + w - c, y: y0 + h), radius: c)
    p.addLine(to: CGPoint(x: x0 + c, y: y0 + h))
    p.addArc(tangent1End: CGPoint(x: x0, y: y0 + h), tangent2End: CGPoint(x: x0, y: y0 + h - c), radius: c)
    p.addLine(to: CGPoint(x: x0, y: y0 + c))
    p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + c, y: y0), radius: c)
    p.closeSubpath()
    for rx in [5.85, 14.95] as [CGFloat] {
        for r in [3.25, 1.2] as [CGFloat] {
            p.addEllipse(in: CGRect(x: x0 + (rx - r) * s, y: y0 + (7.7 - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
    }
    return p
}

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    // Work in a 1024-point, y-down space.
    cg.scaleBy(x: size / 1024, y: size / 1024)
    cg.translateBy(x: 0, y: 1024)
    cg.scaleBy(x: 1, y: -1)

    // The tile: Apple's standard icon area (824 points, corner 185), flat graphite, a faint light edge.
    let tile = CGPath(
        roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185,
        transform: nil)
    cg.addPath(tile)
    cg.setFillColor(color(0x1C1C1E))
    cg.fillPath()
    if size >= 64 {
        cg.addPath(
            CGPath(
                roundedRect: CGRect(x: 102, y: 102, width: 820, height: 820), cornerWidth: 183, cornerHeight: 183,
                transform: nil))
        cg.setStrokeColor(color(0xFFFFFF, alpha: 0.1))
        cg.setLineWidth(4)
        cg.strokePath()
    }

    // The cassette: body 20.8 x 13.2 units, 30.8 points per unit, centred.
    let s: CGFloat = 30.8
    cg.addPath(cassette(origin: CGPoint(x: 512 - 10.4 * s, y: 512 - 6.6 * s), scale: s))
    cg.setFillColor(color(0xF4F4F5))
    cg.fillPath(using: .evenOdd)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: CGFloat(base * scale)).write(to: out.appendingPathComponent(name))
    }
}
try draw(size: 1024).write(to: out.deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png"))
print("Wrote \(out.path)")
