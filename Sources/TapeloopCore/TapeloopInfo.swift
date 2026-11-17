import Foundation

/// Facts about the app that every module may need.
public enum TapeloopInfo {
    /// The bundle identifier of the app; also the `os.Logger` subsystem.
    public static let bundleIdentifier = "io.github.harshaxnim.tapeloop"

    /// The app's display name.
    public static let name = "Tapeloop"
}

extension TapeloopInfo {
    /// The marketing version (CFBundleShortVersionString), or the source default outside an app bundle.
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    /// The build number (CFBundleVersion).
    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// The project's home page.
    public static let repositoryURL = URL(string: "https://github.com/harshaxnim/tapeloop")!
}
