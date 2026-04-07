import SwiftUI

struct PaperListView: View {
    @ObservedObject var appState: AppState
    let selection: SidebarSelection

    /// In-list filter driven by Cmd+F. When the bar is visible and the
    /// query is non-empty, `filteredPapers` narrows the list by
    /// title/authors/primaryCategory (case-insensitive).
    @State private var isSearchBarVisible: Bool = false
    @State private var filterQuery: String = ""
    @FocusState private var searchFieldFocused: Bool

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

    /// Apply the in-list filter. Case-insensitive substring match against
    /// title, authors, and primaryCategory. When the filter is inactive or
    /// the query is empty, returns the full list unchanged.
    private var filteredPapers: [MatchedPaper] {
        let query = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSearchBarVisible, !query.isEmpty else { return papers }
        let lowered = query.lowercased()
        return papers.filter { paper in
            paper.title.lowercased().contains(lowered)
                || paper.authors.lowercased().contains(lowered)
                || paper.primaryCategory.lowercased().contains(lowered)
        }
    }

    private var isFilterActive: Bool {
        isSearchBarVisible && !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        filteredPapers.contains(where: \.isNew)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isSearchBarVisible {
                searchBar
            }

            if papers.isEmpty {
                ContentUnavailableView {
                    Label(isTrashView ? "Trash is Empty" : "No Papers",
                          systemImage: isTrashView ? "trash" : "doc.text")
                } description: {
                    Text(isTrashView
                         ? "Trashed papers will appear here."
                         : "Papers matching this search will appear here.")
                }
            } else if filteredPapers.isEmpty {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "magnifyingglass")
                } description: {
                    Text("No papers match \u{201C}\(filterQuery)\u{201D}.")
                }
            } else if isTrashView {
                List {
                    ForEach(filteredPapers) { paper in
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
                    ForEach(filteredPapers) { paper in
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
        .background(
            // Hidden Cmd+F trigger: shows the search bar and focuses the field.
            // A real Button is used so the shortcut is picked up even when the
            // sidebar or another control has first responder.
            Button(action: openSearchBar) { EmptyView() }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        )
        .onChange(of: selection) { _, _ in
            // Clear filter state when switching sidebar items — the filter
            // only makes sense for the currently-visible list.
            isSearchBarVisible = false
            filterQuery = ""
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

    /// Find bar that appears above the List when Cmd+F is pressed. Esc or
    /// the × button dismisses it and clears the filter.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            TextField("Filter by title, authors, or category", text: $filterQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFieldFocused)
                .onSubmit { /* keep bar open — Enter is a no-op */ }
                .onExitCommand { closeSearchBar() }  // Esc dismisses the bar

            if isFilterActive {
                Text("\(filteredPapers.count) of \(papers.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button(action: closeSearchBar) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func openSearchBar() {
        isSearchBarVisible = true
        // Defer focus to the next runloop tick so the TextField is mounted.
        DispatchQueue.main.async {
            searchFieldFocused = true
        }
    }

    private func closeSearchBar() {
        isSearchBarVisible = false
        filterQuery = ""
        searchFieldFocused = false
    }
}
