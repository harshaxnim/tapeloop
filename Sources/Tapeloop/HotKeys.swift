#if os(macOS)
    import AppKit
    import Carbon.HIToolbox
    import TapeloopCore
    import os

    /// Global keyboard shortcuts, registered with Carbon's hot-key service. It needs no Accessibility permission, and
    /// a shortcut that another app already holds fails to register (reported, so Settings can say so).
    @MainActor
    final class HotKeys {
        /// What a shortcut does.
        enum Action: UInt32, CaseIterable {
            case save = 1
            case bookmark = 2
            case pause = 3
            case openPopover = 4
        }

        static let shared = HotKeys()
        private let log = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "hotkeys")
        private var refs: [Action: EventHotKeyRef] = [:]
        private var handlerInstalled = false
        /// Called on the main actor when a registered shortcut is pressed.
        var onAction: ((Action) -> Void)?
        /// The shortcuts that could not be registered (taken by another app).
        private(set) var failed: Set<Action> = []

        private var lastRegistered = Shortcuts()
        private var suspended = false

        /// Unregisters every shortcut while one is being recorded in Settings (so pressing the current combo does not
        /// trigger it), and registers them again afterwards.
        func setSuspended(_ value: Bool) {
            guard value != suspended else { return }
            suspended = value
            if value {
                for ref in refs.values { UnregisterEventHotKey(ref) }
                refs.removeAll()
            } else {
                register(lastRegistered)
            }
        }

        private static let signature: OSType = 0x5450_4C50  // "TPLP"

        /// Replaces all registrations with `shortcuts`.
        func register(_ shortcuts: Shortcuts) {
            lastRegistered = shortcuts
            guard !suspended else { return }
            installHandler()
            for ref in refs.values { UnregisterEventHotKey(ref) }
            refs.removeAll()
            failed.removeAll()
            let wanted: [(Action, KeyCombo?)] = [
                (.save, shortcuts.save), (.bookmark, shortcuts.bookmark), (.pause, shortcuts.pause),
                (.openPopover, shortcuts.openPopover),
            ]
            for (action, combo) in wanted {
                guard let combo else { continue }
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
                let status = RegisterEventHotKey(
                    combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
                if status == noErr, let ref {
                    refs[action] = ref
                } else {
                    failed.insert(action)
                    log.error("Shortcut \(combo.display, privacy: .public) is taken (OSStatus \(status))")
                }
            }
        }

        private func installHandler() {
            guard !handlerInstalled else { return }
            handlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, _ in
                    var id = EventHotKeyID()
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &id)
                    let raw = id.id
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let action = HotKeys.Action(rawValue: raw) { HotKeys.shared.onAction?(action) }
                        }
                    }
                    return noErr
                }, 1, &spec, nil, nil)
        }
    }

    extension KeyCombo {
        /// The menu key equivalent and modifier mask for showing this combo next to a menu item.
        var menuEquivalent: (key: String, mask: NSEvent.ModifierFlags) {
            var mask: NSEvent.ModifierFlags = []
            if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
            if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
            if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
            if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
            return (key.lowercased(), mask)
        }
    }
#endif
