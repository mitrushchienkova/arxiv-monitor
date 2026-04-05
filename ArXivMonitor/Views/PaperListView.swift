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
        case .trash:
            return appState.trashedPapers
        }
    }

    private var title: String {
        switch selection {
        case .allPapers:
            return "All Papers"
        case .search(let id):
            return appState.savedSearches.first(where: { $0.id == id })?.name ?? "Search"
        case .trash:
            return "Trash"
        }
    }

    private var isTrashView: Bool {
        if case .trash = selection { return true }
        return false
    }

    private var hasNewPapers: Bool {
        papers.contains(where: \.isNew)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if papers.isEmpty {
                ContentUnavailableView {
                    Label(isTrashView ? "Trash is Empty" : "No Papers",
                          systemImage: isTrashView ? "trash" : "doc.text")
                } description: {
                    Text(isTrashView
                         ? "Trashed papers will appear here."
                         : "Papers matching this search will appear here.")
                }
            } else if isTrashView {
                List {
                    ForEach(papers) { paper in
                        HStack(alignment: .top, spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(paper.title)
                                    .font(.system(size: 12))
                                    .lineLimit(2)
                                HStack(spacing: 4) {
                                    Text(paper.primaryCategory)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    Text("·")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    Text(paper.authors)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button("Restore") {
                                appState.restorePaper(paper.id)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                List {
                    ForEach(papers) { paper in
                        PaperRowView(
                            paper: paper,
                            savedSearches: appState.savedSearches,
                            onOpen: { appState.openPaper(paper) },
                            onDismiss: { appState.dismissPaper(paper.id) },
                            onToggleRead: { appState.toggleRead(paperID: paper.id) }
                        )
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !isTrashView {
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
            }
            ToolbarItem(placement: .primaryAction) {
                if isTrashView && !papers.isEmpty {
                    Button("Empty Trash") {
                        appState.emptyTrash()
                    }
                    .help("Permanently delete all trashed papers")
                } else if hasNewPapers {
                    Button("Mark All as Read") {
                        switch selection {
                        case .allPapers:
                            appState.markAllRead()
                        case .search(let id):
                            appState.markAllRead(for: id)
                        case .trash:
                            break
                        }
                    }
                    .help("Mark all papers in this view as read")
                }
            }
        }
    }
}
