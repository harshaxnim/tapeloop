import Foundation

/// Facts about the app that every module may need.
public enum TapeloopInfo {
    /// The bundle identifier of the app; also the `os.Logger` subsystem.
    public static let bundleIdentifier = "io.github.harshaxnim.tapeloop"

    /// The app's display name.
    public static let name = "Tapeloop"
}
