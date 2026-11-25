import AppKit
import UserNotifications

/// Sons discrets et notifications macOS.
@MainActor
final class Feedback {
    /// Les notifications exigent un vrai bundle (lancement via Aura.app, pas `swift run`).
    private var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    func requestNotificationPermission() {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func play(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }

    func notify(title: String, body: String) {
        guard hasBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
