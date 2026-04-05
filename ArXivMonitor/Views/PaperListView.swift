import SwiftUI

struct PaperListView: View {
    @ObservedObject var appState: AppState
    let searchID: UUID?

    private var papers: [MatchedPaper] {
        if let searchID = searchID {
            return appState.papers(for: searchID)
        } else {
            return appState.allPapersSorted
        }
    }

    private var title: String {
        if let searchID = searchID,
           let search = appState.savedSearches.first(where: { $0.id == searchID }) {
            return search.name
        }
        return "All Papers"
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
                            onOpen: { appState.openPaper(paper) },
                            onDismiss: { appState.dismissPaper(paper.id) }
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
        }
    }
}
