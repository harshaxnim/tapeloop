#if os(macOS)
import AppKit
import RearviewUI
import SwiftUI

/// Renders every key view to PNG, in light and dark, for CI to upload.
/// Usage: RearviewSnapshots <output-folder>
@MainActor
func renderAll(to folder: URL) throws -> Int {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var count = 0
    for scheme in [ColorScheme.light, .dark] {
        for status in RecorderStatus.allCases {
            let view = PopoverView(status: status)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.95))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            var rendered: CGImage?
            appearance?.performAsCurrentDrawingAppearance { rendered = renderer.cgImage }
            guard let image = rendered else {
                throw SnapshotError.renderFailed("popover-\(status.rawValue)")
            }
            let name = "popover-\(status.rawValue)-\(scheme == .dark ? "dark" : "light").png"
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw SnapshotError.renderFailed(name)
            }
            try data.write(to: folder.appendingPathComponent(name))
            count += 1
        }
    }
    return count
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
