import SwiftUI

struct PaperListView: View {
    @ObservedObject var appState: AppState
    let selection: SidebarSelection

    private var papers: [MatchedPaper] {
        switch selection {
        case .allPapers:
            return appState.allPapersSorted
        case .search(let id):
            return appState.papers(for: id)
        }
    }

    private var title: String {
        switch selection {
        case .allPapers:
            return "All Papers"
        case .search(let id):
            return appState.savedSearches.first(where: { $0.id == id })?.name ?? "Search"
        }
    }

    private var hasNewPapers: Bool {
        papers.contains(where: \.isNew)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if papers.isEmpty {
                ContentUnavailableView {
                    Label("No Papers", systemImage: "doc.text")
                } description: {
                    Text("Papers matching this search will appear here.")
                }
            } else {
                List {
                    ForEach(papers) { paper in
                        PaperRowView(
                            paper: paper,
                            savedSearches: appState.savedSearches,
                            onOpen: { appState.openPaper(paper) },
                            onDismiss: { appState.dismissPaper(paper.id) },
                            onToggleRead: {
                                if paper.isNew {
                                    appState.markRead(paperID: paper.id)
                                } else {
                                    appState.markUnread(paperID: paper.id)
                                }
                            }
                        )
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { appState.runFetchCycle() }) {
                    if appState.isFetching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(appState.isFetching)
                .help("Refresh now")
            }
            ToolbarItem(placement: .primaryAction) {
                if hasNewPapers {
                    Button("Mark All as Read") {
                        switch selection {
                        case .allPapers:
                            appState.dismissAll()
                        case .search(let id):
                            appState.markAllRead(for: id)
                        }
                    }
                    .help("Mark all papers in this view as read")
                }
            }
        }
    }
}
