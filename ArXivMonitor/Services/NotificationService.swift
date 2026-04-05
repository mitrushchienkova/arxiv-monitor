import AppKit
import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()
    private let authorizationOptions: UNAuthorizationOptions = [.alert, .sound, .badge]
    private let paperFlipSoundName = UNNotificationSoundName(rawValue: "paper-flip.aiff")

    private init() {}

    /// Request notification permission. Call on first saved search creation.
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: authorizationOptions) { granted, error in
                if let error = error {
                    print("[ArXivMonitor] Notification permission error: \(error)")
                }
                print("[ArXivMonitor] Notification permission granted: \(granted)")
                continuation.resume(returning: granted)
            }
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
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

    func openSystemNotificationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
            "x-apple.systempreferences:"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func sendTestNotification(soundName: String) {
        let content = UNMutableNotificationContent()
        content.title = "arXiv Monitor"
        content.subtitle = "Test Notification"
        content.body = "Notifications are enabled and ready for new papers."
        content.threadIdentifier = "arxiv-monitor"
        content.sound = notificationSound(named: soundName)

        postNotification(content, identifierPrefix: "arxiv-test")
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
        content.sound = notificationSound(named: soundName)

        postNotification(content, identifierPrefix: "arxiv-new-papers")
    }

    private func postNotification(_ content: UNMutableNotificationContent, identifierPrefix: String) {
        Task {
            let initialStatus = await authorizationStatus()
            let resolvedStatus: UNAuthorizationStatus

            if initialStatus == .notDetermined {
                _ = await requestPermission()
                resolvedStatus = await authorizationStatus()
            } else {
                resolvedStatus = initialStatus
            }

            guard Self.canDeliverNotifications(for: resolvedStatus) else {
                print("[ArXivMonitor] Notification skipped. Authorization status: \(resolvedStatus.rawValue)")
                return
            }

            let request = UNNotificationRequest(
                identifier: "\(identifierPrefix)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            await add(request)
        }
    }

    private func add(_ request: UNNotificationRequest) async {
        await withCheckedContinuation { continuation in
            center.add(request) { error in
                if let error = error {
                    print("[ArXivMonitor] Failed to post notification: \(error)")
                }
                continuation.resume()
            }
        }
    }

    private func notificationSound(named soundName: String) -> UNNotificationSound? {
        switch soundName {
        case "paperFlip":
            return .init(named: paperFlipSoundName)
        case "none":
            return nil
        default:
            return .default
        }
    }

    private static func canDeliverNotifications(for status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }
}
