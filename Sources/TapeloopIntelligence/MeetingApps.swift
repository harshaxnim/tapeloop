#if os(macOS)
    import Foundation

    /// An app whose use of the microphone means "the user is in a call".
    ///
    /// Apps often use the microphone from a helper process rather than the main one (Chromium-based browsers and
    /// Electron apps use `<bundle id>.helper…`, Safari uses WebKit's `com.apple.WebKit.GPU` process), so an app matches
    /// its own bundle IDs, any bundle ID that starts with one of them followed by a dot, and any extra prefix it lists.
    /// Matching ignores case (Arc's helper is `company.thebrowser.browser.helper`, lower case).
    ///
    /// To support another app, add an entry to ``known``.
    public struct MeetingApp: Hashable, Identifiable, Sendable {
        /// What sort of app it is.
        public enum Kind: String, Hashable, Sendable {
            /// A dedicated call or chat app.
            case app
            /// A web browser; a call in it is usually Google Meet or another web call.
            case browser
        }

        /// The name shown for a meeting in this app, for example "Zoom", "Slack huddle" or "Chrome call".
        public let name: String
        /// The app's bundle identifiers; the first one is the main one and is used as the ``id``.
        public let bundleIDs: [String]
        /// Extra bundle-ID prefixes whose processes count as this app (for example `com.apple.WebKit.` for Safari).
        public let extraPrefixes: [String]
        /// Whether it is a call app or a browser.
        public let kind: Kind

        /// The main bundle identifier.
        public var id: String { bundleIDs[0] }

        /// Creates an entry. `bundleIDs` must not be empty.
        public init(name: String, bundleIDs: [String], extraPrefixes: [String] = [], kind: Kind = .app) {
            precondition(!bundleIDs.isEmpty, "A meeting app needs at least one bundle ID")
            self.name = name
            self.bundleIDs = bundleIDs
            self.extraPrefixes = extraPrefixes
            self.kind = kind
        }

        /// Whether `bundleID` is exactly one of this app's bundle IDs (ignoring case).
        public func matchesExactly(_ bundleID: String) -> Bool {
            bundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
        }

        /// Whether `bundleID` is this app or one of its helper processes.
        public func matches(_ bundleID: String) -> Bool {
            if matchesExactly(bundleID) { return true }
            let lower = bundleID.lowercased()
            if bundleIDs.contains(where: { lower.hasPrefix($0.lowercased() + ".") }) { return true }
            return extraPrefixes.contains { lower.hasPrefix($0.lowercased()) }
        }

        /// The app in `apps` that `bundleID` belongs to. Exact bundle-ID matches win over helper-prefix matches.
        public static func app(forBundleID bundleID: String, in apps: [MeetingApp] = known) -> MeetingApp? {
            apps.first { $0.matchesExactly(bundleID) } ?? apps.first { $0.matches(bundleID) }
        }

        /// The apps Tapeloop recognises, in the order the Settings window lists them.
        public static let known: [MeetingApp] = [
            MeetingApp(name: "Zoom", bundleIDs: ["us.zoom.xos"]),
            MeetingApp(name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
            // FaceTime's audio runs in the `avconferenced` daemon, not in the FaceTime app itself.
            MeetingApp(name: "FaceTime", bundleIDs: ["com.apple.FaceTime", "com.apple.avconferenced"]),
            MeetingApp(name: "Slack huddle", bundleIDs: ["com.tinyspeck.slackmacgap"]),
            MeetingApp(name: "Webex", bundleIDs: ["com.cisco.webexmeetingsapp", "Cisco-Systems.Spark"]),
            MeetingApp(name: "Discord", bundleIDs: ["com.hnc.Discord"]),
            MeetingApp(name: "Skype", bundleIDs: ["com.skype.skype"]),
            // The native app (`net.whatsapp.WhatsApp`) and the older Electron one (`desktop.WhatsApp`).
            MeetingApp(name: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
            // Telegram for macOS (`ru.keepcoder.Telegram`) and Telegram Desktop (`org.telegram.desktop`).
            MeetingApp(name: "Telegram", bundleIDs: ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
            MeetingApp(name: "Signal", bundleIDs: ["org.whispersystems.signal-desktop"]),
            MeetingApp(name: "Chrome call", bundleIDs: ["com.google.Chrome"], kind: .browser),
            // Safari (and any app showing web content) uses the microphone from WebKit's GPU or WebContent process.
            MeetingApp(
                name: "Safari call", bundleIDs: ["com.apple.Safari"], extraPrefixes: ["com.apple.WebKit."],
                kind: .browser),
            MeetingApp(name: "Arc call", bundleIDs: ["company.thebrowser.Browser"], kind: .browser),
            // Firefox's child processes run from `plugin-container.app`.
            MeetingApp(
                name: "Firefox call", bundleIDs: ["org.mozilla.firefox"],
                extraPrefixes: ["org.mozilla.plugincontainer"],
                kind: .browser),
            MeetingApp(name: "Edge call", bundleIDs: ["com.microsoft.edgemac"], kind: .browser),
            MeetingApp(name: "Brave call", bundleIDs: ["com.brave.Browser"], kind: .browser),
        ]
    }
#endif
