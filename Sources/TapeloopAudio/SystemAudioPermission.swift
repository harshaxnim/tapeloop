#if os(macOS)
    import Foundation

    /// The "System Audio Recording" permission (TCC service `kTCCServiceAudioCapture`).
    ///
    /// macOS has no public API to read or request it: a process tap without it simply delivers silence. This uses the
    /// private TCC functions `TCCAccessPreflight` and `TCCAccessRequest`, loaded at run time (the approach of the
    /// open-source AudioCap sample). If they are missing on some macOS version, `status` is `.unknown` and callers
    /// fall back to their own heuristics.
    public enum SystemAudioPermission {
        /// The permission's state.
        public enum Status: Sendable, Equatable {
            /// The user allowed it.
            case authorized
            /// The user denied it (only System Settings can change it).
            case denied
            /// Not asked yet.
            case notDetermined
            /// The state cannot be read on this Mac.
            case unknown
        }

        private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

        private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
        private typealias RequestFunction =
            @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

        /// dlopen returns the same handle for an already-loaded library, so opening it on each use is cheap.
        private static var framework: UnsafeMutableRawPointer? {
            dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
        }

        private static var preflight: PreflightFunction? {
            guard let framework, let symbol = dlsym(framework, "TCCAccessPreflight") else { return nil }
            return unsafeBitCast(symbol, to: PreflightFunction.self)
        }

        private static var requestFunction: RequestFunction? {
            guard let framework, let symbol = dlsym(framework, "TCCAccessRequest") else { return nil }
            return unsafeBitCast(symbol, to: RequestFunction.self)
        }

        /// The current state, read without prompting.
        public static var status: Status {
            guard let preflight else { return .unknown }
            switch preflight(service, nil) {
            case 0: return .authorized
            case 1: return .denied
            case 2: return .notDetermined
            default: return .unknown
            }
        }

        /// Shows macOS's prompt when the permission was not asked yet; returns whether it is allowed. Returns `nil`
        /// when the private function is unavailable (the caller should start a tap instead, which also prompts).
        public static func request() async -> Bool? {
            guard let requestFunction else { return nil }
            return await withCheckedContinuation { continuation in
                requestFunction(service, nil) { granted in continuation.resume(returning: granted) }
            }
        }
    }
#endif
