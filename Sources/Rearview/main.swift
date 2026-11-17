#if os(macOS)
import AppKit
import RearviewCore

if CommandLine.arguments.contains("--version") {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    print("\(RearviewInfo.name) \(version ?? "dev")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#else
print("Rearview runs on macOS only.")
#endif
