#if os(macOS)
    import AppKit
    import TapeloopCore
    @preconcurrency import UserNotifications

    /// Posts Tapeloop's notifications and routes their buttons back to the app.
    @MainActor
    final class Notifier: NSObject, UNUserNotificationCenterDelegate {
        static let shared = Notifier()

        /// What to tell the user.
        enum Message {
            case saved(length: String, names: String, file: URL)
            case saveFailed(reason: String)
            case nothingToSave
            case bookmarked(time: String)
            case meetingEnded(id: UUID, app: String, title: String?, span: String, length: String)
            case meetingSaved(name: String, file: URL)
            case permissionLost(source: SourceKind)
            case transcriptReady(title: String, detail: String, file: URL)
            case transcriptFailed(reason: String)
        }

        /// A button the user pressed (or a click on the notification itself).
        enum Response {
            case play(URL)
            case reveal(URL)
            case saveMeeting(UUID)
            case openPrivacySettings(SourceKind)
            case openLibrary(URL?)
        }

        /// Handles a response, on the main actor.
        var onResponse: (Response) -> Void = { _ in }

        private enum Category: String {
            case saved, meeting, permission, transcript, plain
        }

        private enum ActionID: String {
            case play, reveal, saveMeeting, notNow, openSettings, open
        }

        /// Registers the categories and becomes the notification centre's delegate. Call once at launch.
        func install() {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            func action(_ id: ActionID, _ title: String) -> UNNotificationAction {
                UNNotificationAction(identifier: id.rawValue, title: title, options: [.foreground])
            }
            center.setNotificationCategories([
                UNNotificationCategory(
                    identifier: Category.saved.rawValue,
                    actions: [action(.play, "Play"), action(.reveal, "Show in Finder")],
                    intentIdentifiers: []),
                UNNotificationCategory(
                    identifier: Category.meeting.rawValue,
                    actions: [
                        action(.saveMeeting, "Save meeting"),
                        UNNotificationAction(identifier: ActionID.notNow.rawValue, title: "Not now"),
                    ],
                    intentIdentifiers: []),
                UNNotificationCategory(
                    identifier: Category.permission.rawValue, actions: [action(.openSettings, "Open System Settings")],
                    intentIdentifiers: []),
                UNNotificationCategory(
                    identifier: Category.transcript.rawValue, actions: [action(.open, "Open")], intentIdentifiers: []),
            ])
        }

        func post(_ message: Message) {
            let content = UNMutableNotificationContent()
            var category = Category.plain
            switch message {
            case .saved(let length, let names, let file):
                content.title = "Saved \(length)"
                content.body = names
                content.userInfo = ["file": file.path]
                category = .saved
            case .saveFailed(let reason):
                content.title = "Could not save"
                content.body = reason
            case .nothingToSave:
                content.title = "Nothing to save yet"
                content.body = "Tapeloop has no audio in that span. It starts keeping audio once recording runs."
            case .bookmarked(let time):
                content.title = "Bookmarked \(time)"
                content.body = "The moment is marked on the timeline. Saves that include it keep the bookmark."
                content.sound = nil
            case .meetingEnded(let id, let app, let title, let span, let length):
                content.title = "The \(app) meeting ended"
                content.body = "\(title.map { "\($0) · " } ?? "")\(span) (\(length)). Save it?"
                content.userInfo = ["meeting": id.uuidString]
                category = .meeting
            case .meetingSaved(let name, let file):
                content.title = "Meeting saved"
                content.body = name
                content.userInfo = ["file": file.path]
                category = .saved
            case .permissionLost(let source):
                content.title =
                    source == .microphone ? "Tapeloop cannot hear your microphone" : "Tapeloop cannot hear system audio"
                content.body =
                    source == .microphone
                    ? "Allow the Microphone permission so your side of conversations is recorded."
                    : "Allow System Audio Recording so calls are recorded on both sides."
                content.userInfo = ["source": source.rawValue]
                category = .permission
            case .transcriptReady(let title, let detail, let file):
                content.title = "Transcript ready"
                content.body = "\(title) · \(detail)"
                content.userInfo = ["file": file.path]
                category = .transcript
            case .transcriptFailed(let reason):
                content.title = "Could not transcribe"
                content.body = reason
            }
            content.categoryIdentifier = category.rawValue
            let center = UNUserNotificationCenter.current()
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { center.add(request) }
            }
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter, willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .list]
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
        ) async {
            let info = response.notification.request.content.userInfo
            let file = (info["file"] as? String).map { URL(fileURLWithPath: $0) }
            let meeting = (info["meeting"] as? String).flatMap(UUID.init(uuidString:))
            let source = (info["source"] as? String).flatMap(SourceKind.init(rawValue:))
            let action = ActionID(rawValue: response.actionIdentifier)
            let resolved: Response? =
                switch action {
                case .play: file.map(Response.play)
                case .reveal: file.map(Response.reveal)
                case .saveMeeting: meeting.map(Response.saveMeeting)
                case .openSettings: source.map(Response.openPrivacySettings)
                case .open: .openLibrary(file)
                case .notNow: nil
                case nil: source.map(Response.openPrivacySettings) ?? .openLibrary(file)
                }
            guard let resolved else { return }
            await MainActor.run { Notifier.shared.onResponse(resolved) }
        }
    }
#endif
