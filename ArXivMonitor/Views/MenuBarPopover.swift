import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("arXiv Monitor")
                    .font(.headline)
                Spacer()
                Button(action: { openSettings() }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")

                Button(action: { appState.runFetchCycle() }) {
                    if appState.isFetching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(appState.isFetching)
                .help("Refresh now")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // Status line
            statusLine
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            // Content
            if appState.savedSearches.isEmpty {
                emptySearchesView
            } else if appState.isFetching && appState.matchedPapers.isEmpty {
                fetchingView
            } else if appState.newPapers.isEmpty && appState.matchedPapers.isEmpty {
                noPapersView
            } else {
                paperList
            }

            Divider()

            // Footer
            HStack {
                Button("Search filters & history") {
                    openWindow(id: "main-window")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))

                Spacer()

                if appState.unreadCount > 0 {
                    Button("Dismiss All") {
                        appState.dismissAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
        .onAppear {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let progress = appState.fetchProgress {
            Text(progress)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else if let lastCycle = appState.lastCycleAt {
            HStack(spacing: 2) {
                Text("Last checked: \(formattedTime(lastCycle))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if !appState.failedSearchNames.isEmpty {
                    Text("· \(appState.failedSearchNames.joined(separator: ", ")) failed")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Button("Retry") {
                        appState.runFetchCycle()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.link)
                }
            }
        } else {
            Text("Not yet checked")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var emptySearchesView: some View {
        VStack(spacing: 8) {
            Text("Add a search to start monitoring arXiv")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Add Search") {
                openWindow(id: "main-window")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    @ViewBuilder
    private var fetchingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(appState.fetchProgress ?? "Checking arXiv...")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    @ViewBuilder
    private var noPapersView: some View {
        VStack(spacing: 4) {
            Text("No papers found yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    @ViewBuilder
    private var paperList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let newPapers = appState.newPapers
                if !newPapers.isEmpty {
                    Text("\(newPapers.count) NEW PAPER\(newPapers.count == 1 ? "" : "S")")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ForEach(newPapers) { paper in
                        PaperRowView(
                            paper: paper,
                            savedSearches: appState.savedSearches,
                            onOpen: { appState.openPaper(paper) },
                            onDismiss: { appState.dismissPaper(paper.id) }
                        )
                        .padding(.horizontal, 12)
                        Divider().padding(.leading, 12)
                    }
                }

                // Show a few recent history papers too
                let historyPapers = appState.allPapersSorted.filter { !$0.isNew }.prefix(5)
                if !historyPapers.isEmpty && newPapers.isEmpty {
                    Text("RECENT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ForEach(Array(historyPapers)) { paper in
                        PaperRowView(
                            paper: paper,
                            savedSearches: appState.savedSearches,
                            onOpen: { appState.openPaper(paper) },
                            onDismiss: { appState.dismissPaper(paper.id) }
                        )
                        .padding(.horizontal, 12)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .frame(idealHeight: 300, maxHeight: 400)
    }

    private func formattedTime(_ iso8601: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso8601) else { return iso8601 }
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        return timeFormatter.string(from: date)
    }
}
