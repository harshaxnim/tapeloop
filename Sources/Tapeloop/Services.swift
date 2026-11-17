#if os(macOS)
    import AVFoundation
    import AppKit
    import EventKit
    import ServiceManagement
    import SwiftUI
    import TapeloopAudio
    import TapeloopCore
    import TapeloopIntelligence
    import TapeloopUI
    import os

    /// Permissions, launch at login and other system facts, gathered for Settings and the first-run guide.
    @MainActor
    enum Services {
        private static let log = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "services")
        private static let systemAudioAskedKey = "systemAudioAsked"
        /// Languages that can be transcribed on device, filled in the background at launch (the query is slow).
        static var languages: [(id: String, name: String)] = []

        static func make(controller: AppController) -> SettingsServices {
            var services = SettingsServices()
            services.inputDevices = { AudioDevices.inputs().map { ($0.uid, $0.name) } }
            services.defaultInputName = { AudioDevices.defaultInput()?.name }
            services.levels = { controller.engine.status().levels }
            services.bytesInRAM = { controller.engine.status().bytesInRAM }
            services.permission = { permission($0, controller: controller) }
            services.request = { await request($0) }
            services.openSystemSettings = { openSystemSettings($0) }
            services.launchAtLogin = { SMAppService.mainApp.status == .enabled }
            services.setLaunchAtLogin = { setLaunchAtLogin($0) }
            services.calendars = {
                CalendarProvider().calendars().map { ($0.id, $0.title, Color(hex: $0.colorHex)) }
            }
            services.transcriptionLanguages = { languages }
            services.appInfo = { appInfo($0) }
            services.takenShortcuts = {
                Set(
                    HotKeys.shared.failed.map { action -> ShortcutAction in
                        switch action {
                        case .save: .save
                        case .bookmark: .bookmark
                        case .pause: .pause
                        case .openPopover: .openPopover
                        }
                    })
            }
            services.eraseBuffer = {
                controller.engine.wipe()
                controller.refresh()
            }
            services.suspendShortcuts = { HotKeys.shared.setSuspended($0) }
            let intelligence = controller.intelligence
            services.speechModelName = intelligence.models.model.name
            services.speechModelSize = intelligence.models.model.sizeText
            services.speechModelStatus = {
                switch intelligence.models.state {
                case .notInstalled: .notInstalled
                case .downloading(let fraction): .downloading(fraction)
                case .verifying: .verifying
                case .installed: .installed
                case .failed(let message): .failed(message)
                }
            }
            services.downloadSpeechModel = { intelligence.downloadModel() }
            services.cancelSpeechModelDownload = { intelligence.models.cancel() }
            services.deleteSpeechModel = { intelligence.models.delete() }
            services.importSpeechModel = {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.data]
                panel.allowsOtherFileTypes = true
                panel.prompt = "Import"
                panel.message = "Choose the file \(intelligence.models.model.fileName)."
                NSApp.activate(ignoringOtherApps: true)
                if panel.runModal() == .OK, let url = panel.url { intelligence.importModel(at: url) }
            }
            return services
        }

        private static var languagesRequested = false

        /// Fills `languages` off the main thread, once.
        static func loadLanguages() {
            guard !languagesRequested else { return }
            languagesRequested = true
            Task.detached(priority: .utility) {
                let list = AppleSpeechTranscriber.onDeviceLocales().map { locale in
                    (
                        id: locale.identifier,
                        name: Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
                    )
                }
                await MainActor.run { languages = list }
            }
        }

        // MARK: - Permissions

        static func permission(_ kind: PermissionKind, controller: AppController?) -> PermissionState {
            switch kind {
            case .microphone:
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: return .allowed
                case .notDetermined: return .notAsked
                default: return .denied
                }
            case .systemAudio:
                guard #available(macOS 14.2, *) else { return .unavailable }
                switch SystemAudioPermission.status {
                case .authorized: return .allowed
                case .denied: return .denied
                case .notDetermined: return .notAsked
                case .unknown: break
                }
                // The state cannot be read: a tap without the permission delivers silence, so "allowed" is shown
                // once system audio has carried sound; after the prompt was shown it is "asked".
                if UserDefaults.standard.bool(forKey: "systemAudioHeard") { return .allowed }
                return UserDefaults.standard.bool(forKey: systemAudioAskedKey) ? .asked : .notAsked
            case .calendar:
                switch EKEventStore.authorizationStatus(for: .event) {
                case .fullAccess: return .allowed
                case .notDetermined: return .notAsked
                default: return .denied
                }
            case .speech:
                switch SpeechPermission.status {
                case .authorized: return .allowed
                case .notDetermined: return .notAsked
                case .denied, .restricted: return .denied
                }
            }
        }

        static func request(_ kind: PermissionKind) async {
            NSApp.activate(ignoringOtherApps: true)
            switch kind {
            case .microphone: _ = await MicrophoneSource.requestPermission()
            case .systemAudio:
                guard #available(macOS 14.2, *) else { return }
                UserDefaults.standard.set(true, forKey: systemAudioAskedKey)
                if let granted = await SystemAudioPermission.request() {
                    log.info("System audio permission: \(granted ? "allowed" : "denied", privacy: .public)")
                    return
                }
                // Fallback: starting a tap is what makes macOS ask. Run one briefly; the recorder starts its own later.
                let tap = SystemAudioTap()
                do {
                    try tap.start(
                        onBuffer: { buffer, _ in
                            if SystemAudioProbe.hasSound(buffer) {
                                UserDefaults.standard.set(true, forKey: "systemAudioHeard")
                            }
                        }, onEvent: { _ in })
                    try? await Task.sleep(for: .seconds(2))
                } catch {
                    log.error("System audio permission probe failed: \(String(describing: error), privacy: .public)")
                }
                tap.stop()
            case .calendar: _ = await CalendarProvider().requestAccess()
            case .speech: _ = await SpeechPermission.request()
            }
        }

        static func openSystemSettings(_ kind: PermissionKind) {
            let anchor =
                switch kind {
                case .microphone: "Privacy_Microphone"
                // On macOS 14 and 15 this page holds both screen and "System Audio Recording Only".
                case .systemAudio: "Privacy_ScreenCapture"
                case .calendar: "Privacy_Calendars"
                case .speech: "Privacy_SpeechRecognition"
                }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
                NSWorkspace.shared.open(url)
            }
        }

        // MARK: - Launch at login and apps

        static func setLaunchAtLogin(_ on: Bool) -> String? {
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                return nil
            } catch {
                log.error("Launch at login: \(String(describing: error), privacy: .public)")
                return on
                    ? "Tapeloop could not add itself to your login items. Move it to the Applications folder and try again."
                    : "Tapeloop could not remove itself from your login items. Remove it in System Settings › General › Login Items."
            }
        }

        static func appInfo(_ bundleID: String) -> (name: String, icon: NSImage?)? {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return (name, NSWorkspace.shared.icon(forFile: url.path))
        }
    }

    /// Detects whether a buffer carries any sound (used to learn that the system audio permission is granted).
    enum SystemAudioProbe {
        static func hasSound(_ buffer: AVAudioPCMBuffer) -> Bool {
            guard let data = buffer.floatChannelData else { return false }
            // An interleaved buffer has one pointer holding every channel; a planar one has one per channel.
            let interleaved = buffer.format.isInterleaved
            let pointers = interleaved ? 1 : Int(buffer.format.channelCount)
            let samples = Int(buffer.frameLength) * (interleaved ? Int(buffer.format.channelCount) : 1)
            for channel in 0..<pointers {
                for index in stride(from: 0, to: samples, by: 8) where abs(data[channel][index]) > 0.0005 {
                    return true
                }
            }
            return false
        }
    }

    extension Color {
        /// A colour from "#RRGGBB" (grey when it cannot be read).
        init(hex: String) {
            let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
                self = .gray
                return
            }
            self = Color(
                red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255)
        }
    }
#endif
