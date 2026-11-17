#if os(macOS)
    import TapeloopCore
    import os

    /// Loggers under the app's subsystem. Read them with
    /// `log show --predicate 'subsystem == "io.github.harshaxnim.tapeloop"' --last 10m`.
    enum Log {
        static let encoder = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "encoder")
        static let mic = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "mic")
        static let tap = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "system-audio")
        static let probe = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "probe")
        static let engine = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "engine")
    }
#endif
