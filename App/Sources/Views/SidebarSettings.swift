import SwiftUI
import SwiftwardenCore

struct SidebarSettings: View {
    @Environment(AppModel.self) private var model
    private var layout: SidebarLayout { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section {
                    ForEach(layout.state.sections) { s in
                        check(s.title, symbol: s.symbol, tint: .secondary,
                              isOn: Binding(get: { layout.isVisible(s) }, set: { layout.setVisible(s, $0) }))
                    }
                    .onMove { layout.moveSections($0, $1) }
                } header: {
                    Text("Sections")
                }

                ForEach(layout.state.sections) { s in
                    let items = itemsFor(s)
                    if !items.isEmpty {
                        Section {
                            if s.reorderable {
                                ForEach(items, id: \.0) { itemRow($0.0, $0.1) }
                                    .onMove { layout.moveItems(s, $0, $1, visibleOnly: false) }
                            } else {
                                ForEach(items, id: \.0) { itemRow($0.0, $0.1) }
                            }
                        } header: {
                            Text(s.title)
                        }
                        .disabled(!layout.isVisible(s))
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))

            HStack {
                Text("Drag to reorder here, or hold ⌘ and drag in the sidebar. Right-click the sidebar to hide items.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { layout.reset() }
            }
            .padding(12)
        }
    }

    func itemsFor(_ s: SidebarSection) -> [(SidebarItem, String)] {
        switch s {
        case .library, .types, .tools:
            return layout.items(s).map { ($0, $0.label) }
        case .vaults:
            guard !model.organizations.isEmpty else { return [] }
            var out: [(SidebarItem, String)] = [(.personal, "My Vault")]
            for org in model.organizations {
                out.append((.organization(org.id), org.name ?? "Organization"))
                for c in model.collections where c.organizationId == org.id {
                    out.append((.collection(c.id), "\(org.name ?? "Organization") \u{203A} \(c.name ?? "")"))
                }
            }
            return out
        case .folders:
            return model.folders.map { (.folder($0.id), $0.name ?? "") } + [(.folder(nil), "No Folder")]
        }
    }

    func itemRow(_ i: SidebarItem, _ title: String) -> some View {
        check(title, symbol: i.symbol, tint: i.section == .library ? i.tint : .secondary,
              isOn: Binding(get: { layout.isVisible(i) }, set: { layout.setVisible(i, $0) }))
    }

    func check(_ title: String, symbol: String, tint: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
    }
}
