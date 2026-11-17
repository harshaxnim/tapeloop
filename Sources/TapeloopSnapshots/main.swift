#if os(macOS)
import AppKit
import SwiftUI
import TapeloopUI

/// Renders every key view to PNG, in light and dark, for CI to upload.
/// Usage: TapeloopSnapshots <output-folder>
@MainActor
func renderAll(to folder: URL) throws -> Int {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var count = 0
    for scheme in [ColorScheme.light, .dark] {
        let suffix = scheme == .dark ? "dark" : "light"
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        for status in RecorderStatus.allCases {
            let view = PopoverView(status: status, bytesInMemory: 12_345_678)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.95))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            var rendered: CGImage?
            appearance?.performAsCurrentDrawingAppearance { rendered = renderer.cgImage }
            guard let image = rendered else { throw SnapshotError.renderFailed("popover-\(status.rawValue)") }
            try write(image, to: folder.appendingPathComponent("popover-\(status.rawValue)-\(suffix).png"))
            count += 1
        }
        try write(menuBarStrip(dark: scheme == .dark), to: folder.appendingPathComponent("menubar-icons-\(suffix).png"))
        count += 1
    }
    return count
}

/// The three icon states on a menu-bar-coloured strip, at 16, 18 and 22 pt, drawn at 4x.
@MainActor
func menuBarStrip(dark: Bool) throws -> CGImage {
    let sizes: [CGFloat] = [16, 18, 22]
    let scale: CGFloat = 4
    let width = 12 + CGFloat(RecorderStatus.allCases.count) * sizes.reduce(0) { $0 + $1 + 10 }
    let height: CGFloat = 32
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
    else { throw SnapshotError.renderFailed("menubar") }
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    var x: CGFloat = 8
    for status in RecorderStatus.allCases {
        for size in sizes {
            let icon = CassetteIcon.image(for: status, size: size)
            // Template images are black; tint them like the menu bar does.
            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                (dark ? NSColor.white : NSColor.black).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: x, y: (height - size) / 2, width: size, height: size))
            x += size + 10
        }
        x += 4
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let image = rep.cgImage else { throw SnapshotError.renderFailed("menubar") }
    return image
}

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw SnapshotError.renderFailed(url.lastPathComponent)
    }
    try data.write(to: url)
}

enum SnapshotError: Error {
    case renderFailed(String)
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/snapshots")
let count = try MainActor.assumeIsolated { try renderAll(to: output) }
print("Rendered \(count) snapshots to \(output.path)")
#else
print("Snapshots render on macOS only.")
#endif
