import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()

    private init() {}

    /// Request notification permission. Call on first saved search creation.
    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[ArXivMonitor] Notification permission error: \(error)")
            }
            print("[ArXivMonitor] Notification permission granted: \(granted)")
        }
    }

    /// Register notification action categories.
    func registerActions() {
        let openAction = UNNotificationAction(
            identifier: "OPEN_ACTION",
            title: "Open",
            options: [.foreground]
        )
        let dismissAllAction = UNNotificationAction(
            identifier: "DISMISS_ALL_ACTION",
            title: "Mark All as Read",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: "NEW_PAPERS",
            actions: [openAction, dismissAllAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Post a notification about new papers discovered in this fetch cycle.
    func notifyNewPapers(_ papers: [MatchedPaper], soundName: String) {
        guard !papers.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "arXiv Monitor"
        content.subtitle = "\(papers.count) New Paper\(papers.count == 1 ? "" : "s")"
        content.body = papers.first?.title ?? ""
        content.threadIdentifier = "arxiv-monitor"
        content.categoryIdentifier = "NEW_PAPERS"

        switch soundName {
        case "default":
            content.sound = .default
        case "none":
            content.sound = nil
        default:
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: "arxiv-new-papers-\(UUID().uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )

        center.add(request) { error in
            if let error = error {
                print("[ArXivMonitor] Failed to post notification: \(error)")
            }
        }
    }
}
