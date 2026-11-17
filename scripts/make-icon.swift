// Draws Tapeloop's app icon (a warm full-colour cassette with a red record dot) and writes an .iconset.
// The design matches Resources/Icons/app-icon.svg (SVG y grows down; here y grows up, so y' = 1024 - y - h).
// Usage: swift scripts/make-icon.swift <out.iconset>   then: iconutil -c icns <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: (1024 - y - h) * s, width: w * s, height: h * s)
    }
    func rounded(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: r, xRadius: radius * s, yRadius: radius * s)
    }
    NSGradient(starting: color(0xD9572B), ending: color(0xF2A541))!
        .draw(in: rounded(box(100, 100, 824, 824), 185), angle: 90)
    color(0x26221F).setFill()
    rounded(box(170, 270, 684, 460), 56).fill()
    color(0xF4ECDD).setFill()
    rounded(box(230, 320, 564, 200), 28).fill()
    color(0x3A332D).setFill()
    rounded(box(300, 370, 424, 100), 50).fill()
    for cx in [370.0, 654.0] {
        color(0xF4ECDD).setFill()
        NSBezierPath(ovalIn: box(cx - 40, 380, 80, 80)).fill()
        color(0x26221F).setFill()
        NSBezierPath(ovalIn: box(cx - 14, 406, 28, 28)).fill()
    }
    let guide = NSBezierPath()
    guide.move(to: NSPoint(x: 330 * s, y: (1024 - 730) * s))
    guide.line(to: NSPoint(x: 370 * s, y: (1024 - 620) * s))
    guide.line(to: NSPoint(x: 654 * s, y: (1024 - 620) * s))
    guide.line(to: NSPoint(x: 694 * s, y: (1024 - 730) * s))
    guide.close()
    color(0x3A332D).setFill()
    guide.fill()
    let dot = NSBezierPath(ovalIn: box(744, 254, 92, 92))
    color(0xE53935).setFill()
    dot.fill()
    color(0x26221F).setStroke()
    dot.lineWidth = 16 * s
    dot.stroke()
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
