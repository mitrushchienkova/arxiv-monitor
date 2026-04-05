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
                    Text("Default").tag("default")
                    Text("None").tag("none")
                }
            }

            Section("Appearance") {
                Picker("Badge style", selection: $appState.badgeStyle) {
                    Text("Count").tag("count")
                    Text("Dot").tag("dot")
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
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 300)
    }
}
