import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $appState.launchAtLogin)
            }

            Section("Notifications") {
                Picker("Sound", selection: $appState.soundName) {
                    Text("Paper Flip").tag("paperFlip")
                    Text("System Default").tag("default")
                    Text("None").tag("none")
                }

                Text(notificationStatusText)
                    .font(.caption)
                    .foregroundStyle(notificationStatusColor)

                if shouldShowNotificationActions {
                    HStack {
                        if let actionTitle = primaryNotificationActionTitle {
                            Button(actionTitle) {
                                handlePrimaryNotificationAction()
                            }
                        }

                        Button("Refresh Status") {
                            Task {
                                await appState.refreshNotificationAuthorizationStatus()
                            }
                        }
                    }
                }
            }

            Section("Appearance") {
                Picker("Badge style", selection: $appState.badgeStyle) {
                    Text("Count").tag("count")
                    Text("None").tag("none")
                }
            }

            Section("Data") {
                Button("Export Data...") {
                    appState.exportData()
                }
                Text("Exports saved searches and paper history to a JSON file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let exportStatusMessage = appState.exportStatusMessage {
                    Text(exportStatusMessage)
                        .font(.caption)
                        .foregroundStyle(exportStatusMessage.hasPrefix("Export failed") ? .red : .secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 360)
        .task {
            await appState.refreshNotificationAuthorizationStatus()
        }
    }

    private var canSendTestNotification: Bool {
        switch appState.notificationAuthorizationStatus {
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }

    private var shouldShowNotificationActions: Bool {
        !canSendTestNotification
    }

    private var primaryNotificationActionTitle: String? {
        switch appState.notificationAuthorizationStatus {
        case .notDetermined:
            return "Enable Notifications"
        case .denied:
            return "Open System Settings"
        default:
            return nil
        }
    }

    private var notificationStatusText: String {
        switch appState.notificationAuthorizationStatus {
        case .authorized, .provisional:
            return "Notifications are enabled."
        case .notDetermined:
            return "Notifications have not been enabled yet."
        case .denied:
            return "Notifications are turned off for arXiv Monitor. Re-enable them in System Settings > Notifications."
        @unknown default:
            return "Notification status is unavailable."
        }
    }

    private var notificationStatusColor: Color {
        switch appState.notificationAuthorizationStatus {
        case .denied:
            return .red
        default:
            return .secondary
        }
    }

    private func handlePrimaryNotificationAction() {
        switch appState.notificationAuthorizationStatus {
        case .notDetermined:
            appState.enableNotifications()
        case .denied:
            appState.openNotificationSettings()
        default:
            break
        }
    }
}
