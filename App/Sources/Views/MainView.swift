import SwiftUI
import SwiftwardenCore

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 320)
        } content: {
            Group {
                switch model.sidebar {
                case .sends: SendListView()
                case .generator: GeneratorView()
                default: ItemListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 440)
        } detail: {
            switch model.sidebar {
            case .sends: SendDetailContainer()
            case .generator: GeneratorHistoryView()
            default: ItemDetailContainer()
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search")
    }
}

