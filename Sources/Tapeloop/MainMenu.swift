#if os(macOS)
    import AppKit

    /// The standard main menu, shown while a Tapeloop window is open (the app is then a regular app, in the Dock and
    /// the app switcher). It gives the windows ⌘W, ⌘Q, ⌘, and the editing shortcuts their text fields need.
    @MainActor
    enum MainMenu {
        static func make(target: AnyObject, about: Selector, settings: Selector, library: Selector) -> NSMenu {
            let main = NSMenu()

            let app = submenu("Tapeloop", in: main)
            app.addItem(item("About Tapeloop", about, target: target))
            app.addItem(.separator())
            app.addItem(item("Settings…", settings, key: ",", target: target))
            app.addItem(.separator())
            app.addItem(item("Hide Tapeloop", #selector(NSApplication.hide(_:)), key: "h"))
            let others = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h")
            others.keyEquivalentModifierMask = [.command, .option]
            app.addItem(others)
            app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
            app.addItem(.separator())
            app.addItem(item("Quit Tapeloop", #selector(NSApplication.terminate(_:)), key: "q"))

            let file = submenu("File", in: main)
            file.addItem(item("Library", library, key: "l", target: target))
            file.addItem(.separator())
            file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), key: "w"))

            let edit = submenu("Edit", in: main)
            edit.addItem(item("Undo", Selector(("undo:")), key: "z"))
            let redo = item("Redo", Selector(("redo:")), key: "z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            edit.addItem(redo)
            edit.addItem(.separator())
            edit.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
            edit.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
            edit.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
            edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))

            let window = submenu("Window", in: main)
            window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
            window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
            window.addItem(.separator())
            window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
            NSApp.windowsMenu = window
            return main
        }

        private static func submenu(_ title: String, in main: NSMenu) -> NSMenu {
            let menu = NSMenu(title: title)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }

        private static func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil)
            -> NSMenuItem
        {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            return item
        }
    }
#endif
