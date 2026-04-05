import SwiftUI

enum SidebarSelection: Hashable {
    case allPapers
    case search(UUID)
    case trash
}

struct MainWindowView: View {
    @ObservedObject var appState: AppState
    @State private var selection: SidebarSelection? = .allPapers

    var body: some View {
        NavigationSplitView {
            SearchListView(appState: appState, selection: $selection)
                .frame(minWidth: 200)
        } detail: {
            PaperListView(appState: appState, selection: selection ?? .allPapers)
                .frame(minWidth: 400)
        }
        .frame(minWidth: 650, minHeight: 400)
    }
}
