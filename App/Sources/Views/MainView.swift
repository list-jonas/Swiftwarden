import SwiftUI
import SwiftwardenCore

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 320)
        } content: {
            Group {
                switch model.sidebar {
                case .sends: SendListView()
                case .generator: GeneratorView()
                default: ItemListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 440)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { model.reportContentEdge($0) }
        } detail: {
            Group {
                switch model.sidebar {
                case .sends: SendDetailContainer()
                case .generator: GeneratorHistoryView()
                default: ItemDetailContainer()
                }
            }
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem { Color.clear.frame(width: model.toolbarShim, height: 1) }
                        .sharedBackgroundVisibility(.hidden)
                }
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: Text(model.sidebar == .codes ? "Search Codes" : model.sidebar == .security ? "Search Security" : "Search"))
    }
}


