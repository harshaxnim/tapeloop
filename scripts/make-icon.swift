// Draws Rearview's app icon (a rounded rear-view mirror with a rewind arrow) and writes an .iconset.
// Usage: swift scripts/make-icon.swift <out.iconset>   then: iconutil -c icns <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // Background squircle: deep teal to indigo.
    let bg = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                          xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.60, alpha: 1),
               ending: NSColor(calibratedRed: 0.20, green: 0.18, blue: 0.50, alpha: 1))!.draw(in: bg, angle: -90)
    // Mirror: a wide rounded rectangle with a light glass fill.
    let mirror = NSBezierPath(roundedRect: NSRect(x: 190 * s, y: 380 * s, width: 644 * s, height: 300 * s),
                              xRadius: 150 * s, yRadius: 150 * s)
    NSColor(white: 0.12, alpha: 1).setFill(); mirror.fill()
    let glass = NSBezierPath(roundedRect: NSRect(x: 220 * s, y: 410 * s, width: 584 * s, height: 240 * s),
                             xRadius: 120 * s, yRadius: 120 * s)
    NSGradient(starting: NSColor(white: 0.95, alpha: 1), ending: NSColor(calibratedRed: 0.70, green: 0.85, blue: 0.95, alpha: 1))!
        .draw(in: glass, angle: -90)
    // Stem.
    NSColor(white: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 482 * s, y: 250 * s, width: 60 * s, height: 140 * s), xRadius: 20 * s, yRadius: 20 * s).fill()
    // Rewind arrow inside the glass: two left-pointing triangles.
    NSColor(calibratedRed: 0.90, green: 0.25, blue: 0.25, alpha: 1).setFill()
    for dx in [0.0, 120.0] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: (380 + dx) * s, y: 530 * s))
        p.line(to: NSPoint(x: (500 + dx) * s, y: 600 * s))
        p.line(to: NSPoint(x: (500 + dx) * s, y: 460 * s))
        p.close(); p.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: CGFloat(base * scale)).write(to: out.appendingPathComponent(name))
    }
}
print("Wrote \(out.path)")
