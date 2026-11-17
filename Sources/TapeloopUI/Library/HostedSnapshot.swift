#if os(macOS)
    import AppKit
    import SwiftUI

    /// Draws a SwiftUI view through a real `NSHostingView` in an off-screen window.
    ///
    /// Use it for snapshots of views with scroll views, text fields or lists (such as `LibraryView`): `ImageRenderer`
    /// leaves scroll view content blank and draws AppKit-backed controls as placeholders.
    public enum HostedSnapshot {
        /// The view drawn at `size` points in the light or dark appearance, at the window's backing scale (2× on a
        /// Retina Mac); `nil` if drawing failed.
        @MainActor
        public static func image(of view: some View, size: CGSize, dark: Bool) -> NSBitmapImageRep? {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(
                rootView: view.frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.appearance = appearance
            host.appearance = appearance
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            // Let SwiftUI finish layout and any first-pass updates.
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            window.contentView = nil
            return rep
        }
    }
#endif
