#if os(macOS)
import AppKit
import SwiftUI
import TapeloopCore
import TapeloopUI
import os

/// Owns the status item: left click opens the popover, right click opens the menu.
///
/// Step s1 ships the shell. The engine (s2) drives `status`; the menu items it cannot serve yet are disabled.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "app")
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let menu = NSMenu()
    private var pauseItem: NSMenuItem?
    private var status: RecorderStatus = .paused {
        didSet { refresh() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        popover.behavior = .transient
        buildMenu()
        refresh()
        log.info("Tapeloop started")
    }

    private func buildMenu() {
        func add(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
            return entry
        }
        _ = add("Save Last 5 Minutes", nil)
        _ = add("Bookmark Moment", nil)
        menu.addItem(.separator())
        pauseItem = add("Resume Recording", #selector(togglePause))
        menu.addItem(.separator())
        _ = add("Library…", nil)
        _ = add("Settings…", nil, key: ",")
        menu.addItem(.separator())
        _ = add("Quit Tapeloop", #selector(quit), key: "q")
        menu.autoenablesItems = true
    }

    private func refresh() {
        statusItem?.button?.image = CassetteIcon.image(for: status)
        statusItem?.button?.setAccessibilityLabel("Tapeloop: \(status.label)")
        pauseItem?.title = status == .recording ? "Pause Recording" : "Resume Recording"
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                status: status, bytesInMemory: 0, onTogglePause: { [weak self] in self?.togglePause() },
                onQuit: { NSApp.terminate(nil) }))
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(sender)
            statusItem?.menu = menu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func togglePause() {
        status = status == .recording ? .paused : .recording
        log.info("Status: \(self.status.rawValue, privacy: .public)")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
#endif
