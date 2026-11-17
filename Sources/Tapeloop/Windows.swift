#if os(macOS)
    import AppKit
    import SwiftUI
    import TapeloopCore
    import TapeloopExport
    import TapeloopUI

    /// Opens and keeps the app's windows: Settings, the first-run guide and the Library. An accessory app has no
    /// Dock icon, so each window activates the app when it opens.
    @MainActor
    final class Windows: NSObject, NSWindowDelegate {
        private let controller: AppController
        private var settingsWindow: NSWindow?
        private var settingsModel: SettingsModel?
        private var onboardingWindow: NSWindow?
        private var libraryWindow: NSWindow?
        private var library: LibraryModel?
        private var settingsTimer: Timer?

        init(controller: AppController) {
            self.controller = controller
        }

        // MARK: - Settings

        func showSettings(tab: String?) {
            if settingsWindow == nil {
                let model = SettingsModel(
                    settings: controller.settings,
                    services: services(returningTo: { [weak self] in self?.settingsWindow })
                ) { [weak self] settings in
                    guard let self else { return }
                    let oldFolder = self.controller.settings.recorder.saveFolder
                    self.controller.update { $0 = settings }
                    if settings.recorder.saveFolder != oldFolder {
                        self.library?.setStore(LibraryStore(folder: settings.recorder.saveFolder))
                    }
                }
                model.services.showWelcome = { [weak self] in self?.showOnboarding(again: true) {} }
                settingsModel = model
                let window = makeWindow(title: "Tapeloop Settings", content: SettingsView(model: model))
                window.setFrameAutosaveName("TapeloopSettings")
                settingsWindow = window
            }
            if let tab, let value = SettingsModel.Tab(rawValue: tab) { settingsModel?.tab = value }
            settingsModel?.settings = controller.settings
            present(settingsWindow)
            // Listing the speech languages creates one recognizer per language (about 60), so it waits until the
            // language picker can first be seen.
            Services.loadLanguages()
            settingsTimer?.invalidate()
            settingsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.settingsWindow?.isVisible == true else { return }
                    self.settingsModel?.tick += 1
                }
            }
        }

        // MARK: - First-run guide

        /// Shows the guide. `finished` runs once the user presses Done (the first time, it starts recording).
        func showOnboarding(again: Bool = false, finished: @escaping () -> Void) {
            let model = OnboardingModel(
                services: services(returningTo: { [weak self] in self?.onboardingWindow }),
                shortcuts: controller.settings.shortcuts,
                detectMeetings: controller.settings.meetings.detect)
            model.saveMinutes = controller.settings.shortcutSaveMinutes
            model.launchAtLogin = again ? Services.make(controller: controller).launchAtLogin() : true
            model.onFinish = { [weak self] launch, detect in
                guard let self else { return }
                let services = Services.make(controller: self.controller)
                if launch != services.launchAtLogin() { _ = services.setLaunchAtLogin(launch) }
                self.controller.update {
                    $0.onboardingDone = true
                    $0.meetings.detect = detect
                }
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
                finished()
            }
            if let window = onboardingWindow, window.isVisible || !again {
                present(window)
                return
            }
            onboardingWindow?.close()
            let window = makeWindow(title: "Welcome to Tapeloop", content: OnboardingView(model: model))
            window.styleMask.remove(.resizable)
            onboardingWindow = window
            present(window)
        }

        // MARK: - Library

        /// Opens the Library, optionally at a recording (and playing it).
        func showLibrary(selecting url: URL?, play: Bool = false) {
            let folder = controller.settings.recorder.saveFolder
            if library == nil {
                let model = LibraryModel(
                    store: LibraryStore(folder: folder),
                    onOpenSettings: { [weak self] in self?.showSettings(tab: "General") },
                    onTranscribe: { [weak self] url in self?.transcribeFromLibrary(url) })
                library = model
                controller.intelligence.onTranscriptsChanged = { [weak self] in
                    guard let self, let library = self.library else { return }
                    library.transcribing = self.controller.intelligence.transcribing
                }
                let hosting = NSHostingController(rootView: LibraryView(model: model))
                let window = NSWindow(contentViewController: hosting)
                window.title = "Tapeloop Library"
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                window.isReleasedWhenClosed = false
                window.delegate = self
                window.contentMinSize = LibraryView.minimumSize
                window.setContentSize(LibraryView.idealSize)
                window.center()
                window.setFrameAutosaveName("TapeloopLibrary")
                libraryWindow = window
            } else if let library {
                library.setStore(LibraryStore(folder: folder))
            }
            library?.reload()
            library?.startWatching()
            if let url { library?.show(url, play: play) }
            present(libraryWindow)
        }

        /// A save finished: refresh an open Library.
        func recordingSaved(_ result: ExportResult, metadata: RecordingMetadata) {
            // Folder watching sees the new audio file but not the sidecar written just after it.
            library?.reload()
        }

        private func transcribeFromLibrary(_ url: URL) {
            let settings = controller.settings.transcription
            guard settings.enabled else {
                showSettings(tab: "Transcripts")
                return
            }
            if settings.engine == .parakeet {
                guard controller.intelligence.models.isInstalled else {
                    showSettings(tab: "Transcripts")
                    return
                }
                controller.intelligence.transcribe(url)
                return
            }
            Task {
                if Services.permission(.speech, controller: controller) != .allowed { await Services.request(.speech) }
                guard Services.permission(.speech, controller: controller) == .allowed else {
                    Services.openSystemSettings(.speech)
                    return
                }
                controller.intelligence.transcribe(url)
            }
        }

        // MARK: - Helpers

        /// Services whose permission requests bring `window` back to the front afterwards. Tapeloop has no Dock icon,
        /// so when macOS's permission dialog closes, macOS activates the app that was in front before and the
        /// window ends up hidden behind it.
        private func services(returningTo window: @escaping () -> NSWindow?) -> SettingsServices {
            var services = Services.make(controller: controller)
            let request = services.request
            services.request = { [weak self] kind in
                await request(kind)
                self?.present(window())
            }
            return services
        }

        private func makeWindow<Content: View>(title: String, content: Content) -> NSWindow {
            let hosting = NSHostingController(rootView: content)
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.title = title
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            return window
        }

        private func present(_ window: NSWindow?) {
            guard let window else { return }
            updateActivationPolicy(showing: window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }

        /// While any Tapeloop window is open the app is a regular app (in the app switcher and the Dock, with a main
        /// menu); with none open it is a menu bar app again.
        private func updateActivationPolicy(showing shown: NSWindow? = nil, closing closed: NSWindow? = nil) {
            let windows = [settingsWindow, onboardingWindow, libraryWindow].compactMap { $0 }
            let anyOpen = windows.contains { $0 === shown || ($0 !== closed && $0.isVisible) }
            let wanted: NSApplication.ActivationPolicy = anyOpen ? .regular : .accessory
            guard NSApp.activationPolicy() != wanted else { return }
            NSApp.setActivationPolicy(wanted)
            if wanted == .accessory {
                // Hand the focus back to the app the user was in before.
                NSApp.hide(nil)
            }
        }

        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            updateActivationPolicy(closing: window)
            // Closed windows give their memory back; they are built again when next opened.
            if window === libraryWindow {
                library?.player.stop()
                library?.stopWatching()
                DispatchQueue.main.async { [weak self] in
                    self?.libraryWindow = nil
                    self?.library = nil
                }
            }
            if window === settingsWindow {
                settingsTimer?.invalidate()
                settingsTimer = nil
                DispatchQueue.main.async { [weak self] in
                    self?.settingsWindow = nil
                    self?.settingsModel = nil
                }
            }
        }
    }
#endif
