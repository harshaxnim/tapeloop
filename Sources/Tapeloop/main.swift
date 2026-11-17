#if os(macOS)
import AppKit
import Foundation
import TapeloopCore

let arguments = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--version") {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    print("\(TapeloopInfo.name) \(version ?? "dev")")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if arguments.contains("--probe") {
    let seconds = value(after: "--seconds").flatMap(Double.init) ?? 10
    let folder = URL(
        fileURLWithPath: value(after: "--out") ?? NSString("~/Desktop/Tapeloop-probe").expandingTildeInPath)
    Task {
        let report = await Probe.run(seconds: seconds, folder: folder)
        print(report, terminator: "")
        exit(report.contains("RESULT: OK") ? 0 : 1)
    }
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
#else
print("Tapeloop runs on macOS only.")
#endif
