import SwiftUI

struct SearchListView: View {
    @ObservedObject var appState: AppState
    @Binding var selection: SidebarSelection?
    @State private var showAddSheet = false
    @State private var editingSearch: SavedSearch?

    var body: some View {
        List(selection: $selection) {
            Section {
                HStack {
                    Label("All Papers", systemImage: "doc.text")
                    Spacer()
                    let total = appState.matchedPapers.count
                    let unread = appState.unreadCount
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.purple, in: Capsule())
                    }
                    Text("\(total)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .tag(SidebarSelection.allPapers)
            }

            Section("Saved Searches") {
                ForEach(appState.savedSearches) { search in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(search.color)
                            .frame(width: 4, height: 20)
                            .opacity(search.isPaused ? 0.4 : 1.0)
                        Text(search.name)
                            .foregroundStyle(search.isPaused ? .secondary : .primary)
                        if search.isPaused {
                            Image(systemName: "pause.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        let searchPapers = appState.papers(for: search.id)
                        let total = searchPapers.count
                        let unread = searchPapers.filter(\.isNew).count
                        if unread > 0 {
                            Text("\(unread)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.purple, in: Capsule())
                        }
                        Text("\(total)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .tag(SidebarSelection.search(search.id))
                    .contextMenu {
                        Button(search.isPaused ? "Resume" : "Pause") {
                            appState.togglePause(search.id)
                        }
                        Button("Edit...") {
                            editingSearch = search
                        }
                        Button("Delete", role: .destructive) {
                            appState.deleteSearch(search.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button(action: { showAddSheet = true }) {
                Label("Add Search", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showAddSheet) {
            AddSearchSheet(appState: appState)
        }
        .sheet(item: $editingSearch) { search in
            AddSearchSheet(appState: appState, editingSearch: search)
        }
    }
}
