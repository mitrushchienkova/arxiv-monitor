import SwiftUI

struct SearchListView: View {
    @ObservedObject var appState: AppState
    @Binding var selectedSearchID: UUID?
    @State private var showAddSheet = false
    @State private var editingSearch: SavedSearch?

    var body: some View {
        List(selection: $selectedSearchID) {
            Section {
                Label("All Papers", systemImage: "doc.text")
                    .tag(nil as UUID?)
            }

            Section("Saved Searches") {
                ForEach(appState.savedSearches) { search in
                    HStack {
                        Text(search.name)
                        Spacer()
                        let count = appState.papers(for: search.id).filter(\.isNew).count
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.purple, in: Capsule())
                        }
                    }
                    .tag(search.id as UUID?)
                    .contextMenu {
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
