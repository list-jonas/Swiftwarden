import SwiftUI
import SwiftwardenCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Prefs.settingsTab) private var settingsTab = "general"
    @State private var newFolder = false
    @State private var renameFolder: Folder?
    @State private var folderName = ""
    private var layout: SidebarLayout { .shared }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            ForEach(layout.visibleSections) { section in
                content(section)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SyncFooter() }
        .contextMenu { editButton }
        .alert("New Folder", isPresented: $newFolder) {
            TextField("Name", text: $folderName)
            Button("Create") {
                let n = folderName
                model.run("Create folder") { _ = try await model.service?.saveFolder(id: nil, name: n); await model.sync() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Folder", isPresented: Binding(get: { renameFolder != nil }, set: { if !$0 { renameFolder = nil } })) {
            TextField("Name", text: $folderName)
            Button("Save") {
                let n = folderName, id = renameFolder?.id
                model.run("Rename folder") { _ = try await model.service?.saveFolder(id: id, name: n); await model.sync() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    func content(_ section: SidebarSection) -> some View {
        switch section {
        case .library:
            let tiles = layout.visibleItems(.library)
            if !tiles.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
                    ForEach(tiles, id: \.self) { Tile(item: $0) }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, -7)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .selectionDisabled()
            }
        case .vaults:
            if !model.organizations.isEmpty {
                Section(isExpanded: layout.expanded(.vaults)) {
                    if layout.isVisible(SidebarItem.personal) { row(.personal, "My Vault") }
                    ForEach(model.organizations.filter { layout.isVisible(SidebarItem.organization($0.id)) }) { org in
                        row(.organization(org.id), org.name ?? "Organization")
                        ForEach(model.collections.filter { $0.organizationId == org.id && layout.isVisible(SidebarItem.collection($0.id)) }) { c in
                            row(.collection(c.id), c.name ?? "").padding(.leading, 18)
                        }
                    }
                } header: { header(.vaults) }
            }
        case .types, .tools:
            let items = layout.visibleItems(section)
            if !items.isEmpty {
                Section(isExpanded: layout.expanded(section)) {
                    ForEach(items, id: \.self) { i in
                        if section == .tools {
                            Label(i.label, systemImage: i.symbol).tag(i).contextMenu { hideButton(i, i.label) }
                        } else {
                            row(i, i.label)
                        }
                    }
                    .onMove { layout.moveItems(section, $0, $1, visibleOnly: true) }
                } header: { header(section) }
            }
        case .folders:
            Section(isExpanded: layout.expanded(.folders)) {
                ForEach(model.folders.filter { layout.isVisible(SidebarItem.folder($0.id)) }) { f in
                    row(.folder(f.id), f.name ?? "", menu: false)
                        .contextMenu {
                            Button("Rename…") { folderName = f.name ?? ""; renameFolder = f }
                            Button("Delete", role: .destructive) {
                                model.run("Delete folder") {
                                    try await model.service?.deleteFolder(f.id)
                                    await model.sync()
                                }
                            }
                            Divider()
                            hideButton(.folder(f.id), f.name ?? "")
                        }
                }
                if layout.isVisible(SidebarItem.folder(nil)) { row(.folder(nil), "No Folder") }
            } header: {
                HStack {
                    header(.folders)
                    Spacer()
                    Button { folderName = ""; newFolder = true } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.borderless).help("New Folder")
                        .padding(.trailing, 9)
                }
            }
        }
    }

    func header(_ s: SidebarSection) -> some View {
        Text(s.title).contextMenu {
            Button("Hide \u{201C}\(s.title)\u{201D} from Sidebar") { layout.setVisible(s, false) }
            editButton
        }
    }

    func row(_ item: SidebarItem, _ title: String, menu: Bool = true) -> some View {
        HStack {
            Label(title, systemImage: item.symbol)
            Spacer()
            Text("\(model.count(item))").foregroundStyle(.secondary).font(.caption).monospacedDigit()
        }
        .tag(item)
        .contextMenu { if menu { hideButton(item, title) } }
    }

    @ViewBuilder
    func hideButton(_ item: SidebarItem, _ title: String) -> some View {
        Button("Hide \u{201C}\(title)\u{201D} from Sidebar") { layout.setVisible(item, false) }
        editButton
    }

    var editButton: some View {
        Button("Edit Sidebar\u{2026}") { settingsTab = "sidebar"; openSettings() }
    }
}

struct Tile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Prefs.settingsTab) private var settingsTab = "general"
    @State private var targeted = false
    let item: SidebarItem

    var body: some View {
        let selected = model.sidebar == item
        let color = item.tint
        Button { model.sidebar = item; model.selectedId = nil } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(selected ? color : .white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(selected ? Color.white : color))
                    Spacer()
                    Text("\(model.count(item))").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                }
                Text(item.title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? color : Palette.tile))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor, lineWidth: targeted ? 2 : 0))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .draggable(item.key)
        .dropDestination(for: String.self) { keys, _ in
            guard let k = keys.first else { return false }
            withAnimation { SidebarLayout.shared.move(k, before: item) }
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Hide \u{201C}\(item.title)\u{201D} from Sidebar") { SidebarLayout.shared.setVisible(item, false) }
            Button("Edit Sidebar\u{2026}") { settingsTab = "sidebar"; openSettings() }
        }
    }
}

struct SyncFooter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 6) {
            if model.syncing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.triangle.2.circlepath") }
            if let d = model.account?.lastSync {
                Text("Synced \(d.formatted(.relative(presentation: .named)))").lineLimit(1)
            }
            Spacer()
            Button { model.lock() } label: { Image(systemName: "lock") }.buttonStyle(.borderless).help("Lock")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.sync() } }
    }
}





