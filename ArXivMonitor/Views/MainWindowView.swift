import SwiftUI

struct MainWindowView: View {
    @ObservedObject var appState: AppState
    @State private var selectedSearchID: UUID?

    var body: some View {
        NavigationSplitView {
            SearchListView(appState: appState, selectedSearchID: $selectedSearchID)
                .frame(minWidth: 200)
        } detail: {
            PaperListView(appState: appState, searchID: selectedSearchID)
                .frame(minWidth: 400)
        }
        .frame(minWidth: 650, minHeight: 400)
    }
}
