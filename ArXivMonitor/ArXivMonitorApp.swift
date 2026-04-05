import SwiftUI
import UserNotifications

@main
struct ArXivMonitorApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(appState: appState)
        } label: {
            MenuBarLabel(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState)
        }

        Window("arXiv Monitor", id: "main-window") {
            MainWindowView(appState: appState)
        }
    }
}

/// Menu bar label with badge overlay.
struct MenuBarLabel: View {
    @ObservedObject var appState: AppState
    @State private var scheduler: PollScheduler?
    @State private var didSetup = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "doc.text.magnifyingglass")

            if appState.unreadCount > 0 && appState.badgeStyle != "none" {
                badgeView
                    .offset(x: 6, y: -4)
            }
        }
        .onAppear {
            guard !didSetup else { return }
            didSetup = true
            setupScheduler()
            setupNotificationDelegate()
            handleDebugFlags()
        }
    }

    @ViewBuilder
    private var badgeView: some View {
        switch appState.badgeStyle {
        case "dot":
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
        case "count":
            Text("\(appState.unreadCount)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(.red, in: Capsule())
        default:
            EmptyView()
        }
    }

    private func setupScheduler() {
        let s = PollScheduler(appState: appState)
        s.start()
        scheduler = s
    }

    private func setupNotificationDelegate() {
        let delegate = NotificationDelegate(appState: appState)
        appState.notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    private func handleDebugFlags() {
        if CommandLine.arguments.contains("--sample-data") {
            appState.loadSampleData()
        }
        if CommandLine.arguments.contains("--open-window") {
            showMainWindowDirectly()
        }
    }

    private func showMainWindowDirectly() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "arXiv Monitor"
        window.contentView = NSHostingView(rootView: MainWindowView(appState: appState))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.isReleasedWhenClosed = false
    }
}

/// Handle notification actions.
@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            switch response.actionIdentifier {
            case "DISMISS_ALL_ACTION":
                appState.markAllRead()
            case "OPEN_ACTION", UNNotificationDefaultActionIdentifier:
                NSApplication.shared.activate(ignoringOtherApps: true)
            default:
                break
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
