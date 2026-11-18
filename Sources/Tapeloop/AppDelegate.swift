#if os(macOS)
    import AppKit
    import SwiftUI
    import TapeloopAudio
    import TapeloopCore
    import TapeloopUI
    import os

    /// Owns the status item: left click opens the popover, right click opens the menu. Opens the windows and handles
    /// quitting.
    @MainActor
    final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
        private let log = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "app")
        let controller = AppController()
        lazy var windows = Windows(controller: controller)
        private var statusItem: NSStatusItem?
        private let popover = NSPopover()
        private let menu = NSMenu()
        private var lastIcon: RecorderStatus?

        func applicationDidFinishLaunching(_ notification: Notification) {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.imagePosition = .imageOnly
            statusItem = item

            popover.behavior = .transient
            popover.animates = false  // appears and disappears at once
            popover.delegate = self
            menu.delegate = self

            NSApp.mainMenu = MainMenu.make(
                target: self, about: #selector(openAbout), settings: #selector(openSettings),
                library: #selector(openLibrary))
            Notifier.shared.install()
            Notifier.shared.onResponse = { [weak self] response in self?.handle(response) }
            controller.onChange = { [weak self] in self?.refreshIcon() }
            controller.openLibrary = { [weak self] url in
                self?.closePopover(); self?.windows.showLibrary(selecting: url)
            }
            controller.openSettings = { [weak self] tab in
                self?.closePopover(); self?.windows.showSettings(tab: tab)
            }
            controller.didSave = { [weak self] result, metadata in
                self?.windows.recordingSaved(result, metadata: metadata)
            }
            NotificationCenter.default.addObserver(forName: .tapeloopOpenPopover, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.togglePopover() }
            }

            if controller.settings.onboardingDone {
                controller.start()
            } else {
                // Permissions are asked from the first-run window, so the prompts appear in front of the user.
                windows.showOnboarding { [weak self] in self?.controller.start() }
            }
            refreshIcon()
            log.info("Tapeloop started")
            // Logged so a rebuild or update can be checked for keeping the permissions (docs/TESTING.md).
            log.info(
                "Microphone permission at launch: \(MicrophoneSource.isAuthorized ? "authorized" : MicrophoneSource.isDetermined ? "denied" : "notDetermined", privacy: .public)"
            )
            if #available(macOS 14.2, *) {
                log.info(
                    "System audio permission at launch: \(String(describing: SystemAudioPermission.status), privacy: .public)"
                )
            }
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            let held = controller.held
            guard controller.settings.warnOnQuit, held > 60 else { return .terminateNow }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Quit Tapeloop?"
            alert.informativeText =
                "The last \(DurationText.long(held)) in memory will be erased. Save anything you want to keep first."
            let saveSeconds = min(held, 30 * 60)
            alert.addButton(withTitle: "Save Last \(DurationText.long(saveSeconds)) and Quit")
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do not ask again"
            let answer = alert.runModal()
            if alert.suppressionButton?.state == .on { controller.update { $0.warnOnQuit = false } }
            switch answer {
            case .alertFirstButtonReturn:
                let now = Date()
                controller.save(range: TimeRange(start: now.addingTimeInterval(-saveSeconds), end: now)) { _ in
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            case .alertSecondButtonReturn: return .terminateNow
            default: return .terminateCancel
            }
        }

        func applicationWillTerminate(_ notification: Notification) {
            controller.shutdown()
        }

        // MARK: - Status item and popover

        private func refreshIcon() {
            let icon = controller.iconStatus
            guard icon != lastIcon else { return }
            lastIcon = icon
            statusItem?.button?.image = CassetteIcon.image(for: icon)
            statusItem?.button?.setAccessibilityLabel("Tapeloop: \(icon.label)")
            statusItem?.button?.toolTip = "Tapeloop: \(icon.label)"
        }

        @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
            if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true
            {
                closePopover()
                statusItem?.menu = menu
                sender.performClick(nil)
                statusItem?.menu = nil
            } else if (NSApp.currentEvent?.clickCount ?? 1) >= 3 {
                // A triple click offers Quit, which is otherwise only in the right-click menu.
                closePopover()
                statusItem?.menu = quitMenu
                sender.performClick(nil)
                statusItem?.menu = nil
            } else if NSApp.currentEvent?.clickCount == 2 {
                // The middle click of a triple click: leave the popover as the first click left it.
                return
            } else if !controller.settings.onboardingDone {
                // Setup is not finished (its window may be hidden behind other apps): bring it back.
                windows.showOnboarding { [weak self] in self?.controller.start() }
            } else {
                togglePopover()
            }
        }

        /// The menu a triple click on the icon shows.
        private lazy var quitMenu: NSMenu = {
            let menu = NSMenu()
            let item = NSMenuItem(title: "Quit Tapeloop", action: #selector(quit), keyEquivalent: "q")
            item.target = self
            menu.addItem(item)
            return menu
        }()

        private func togglePopover() {
            if popover.isShown {
                closePopover()
            } else if let button = statusItem?.button {
                if popover.contentViewController == nil {
                    // Built on first use rather than at launch: most of the time the app is only an icon.
                    let hosting = NSHostingController(rootView: PopoverView(model: controller.popover))
                    hosting.sizingOptions = .preferredContentSize
                    popover.contentViewController = hosting
                }
                controller.popoverIsOpen = true
                controller.refresh()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
                popover.contentViewController?.view.window?.makeKey()
            }
        }

        private func closePopover() {
            if popover.isShown { popover.performClose(nil) }
        }

        func popoverDidClose(_ notification: Notification) {
            controller.popoverIsOpen = false
            controller.popover.commitBookmark()
        }

        // MARK: - Menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            controller.refresh()
            menu.removeAllItems()
            menu.autoenablesItems = false
            let header = NSMenuItem(title: controller.menuHeader, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let canSave = controller.held > 0 && !controller.isSaving
            let saveCombo = controller.settings.shortcuts.save
            for minutes in [5, 15, 30, 60] {
                let title = minutes < 60 ? "Save Last \(minutes) Minutes" : "Save Last Hour"
                let item = add(title, #selector(saveFromMenu(_:)), to: menu)
                item.tag = minutes
                item.isEnabled = canSave
                if minutes == controller.settings.shortcutSaveMinutes, let saveCombo { show(saveCombo, on: item) }
            }
            if let meeting = controller.ongoingMeeting ?? controller.meetings.last {
                let minutes = DurationText.long(meeting.range(now: Date()).duration)
                let item = add(
                    "Save \(meeting.isOngoing ? "Current" : "Last") Meeting (\(meeting.info.appName), \(minutes))",
                    #selector(saveMeetingFromMenu), to: menu)
                item.isEnabled = canSave
            }
            menu.addItem(.separator())
            let bookmark = add("Bookmark Moment", #selector(bookmarkFromMenu), to: menu)
            bookmark.isEnabled = controller.status.isRecording
            if let combo = controller.settings.shortcuts.bookmark { show(combo, on: bookmark) }
            let pause = add(
                controller.engine.isPaused ? "Resume Recording" : "Pause Recording", #selector(togglePause), to: menu)
            if let combo = controller.settings.shortcuts.pause { show(combo, on: pause) }
            menu.addItem(.separator())
            let library = add("Library…", #selector(openLibrary), to: menu)
            library.keyEquivalent = "l"
            let settings = add("Settings…", #selector(openSettings), to: menu)
            settings.keyEquivalent = ","
            menu.addItem(.separator())
            _ = add("About Tapeloop", #selector(openAbout), to: menu)
            let quit = add("Quit Tapeloop", #selector(quit), to: menu)
            quit.keyEquivalent = "q"
        }

        private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }

        private func show(_ combo: KeyCombo, on item: NSMenuItem) {
            let equivalent = combo.menuEquivalent
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.mask
        }

        @objc private func saveFromMenu(_ sender: NSMenuItem) { controller.saveLast(seconds: Double(sender.tag) * 60) }
        @objc private func saveMeetingFromMenu() {
            if let meeting = controller.ongoingMeeting ?? controller.meetings.last {
                controller.saveMeeting(id: meeting.id)
            }
        }
        @objc private func bookmarkFromMenu() { controller.addBookmark() }
        @objc private func togglePause() { controller.togglePause() }
        @objc private func openLibrary() { windows.showLibrary(selecting: nil) }
        @objc private func openSettings() { windows.showSettings(tab: nil) }
        @objc private func openAbout() { windows.showSettings(tab: "About") }
        @objc private func quit() { NSApp.terminate(nil) }

        // MARK: - Notifications

        private func handle(_ response: Notifier.Response) {
            switch response {
            case .play(let url): windows.showLibrary(selecting: url, play: true)
            case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
            case .saveMeeting(let id): controller.saveMeeting(id: id)
            case .openPrivacySettings: controller.openPrivacySettings()
            case .openLibrary(let url): windows.showLibrary(selecting: url)
            }
        }
    }
#endif
