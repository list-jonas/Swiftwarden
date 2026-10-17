import SwiftUI
import SwiftwardenCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var newFolder = false
    @State private var renameFolder: Folder?
    @State private var folderName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                Tile(item: .all, symbol: "key.fill", color: .blue)
                Tile(item: .favorites, symbol: "star.fill", color: .yellow)
                Tile(item: .codes, symbol: "lock.rotation", color: .teal)
                Tile(item: .passkeys, symbol: "person.badge.key.fill", color: .green)
                Tile(item: .security, symbol: "exclamationmark", color: .red)
                Tile(item: .trash, symbol: "trash.fill", color: .orange)
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            .selectionDisabled()

            Section("Types") {
                ForEach(CipherType.allCases, id: \.self) { t in
                    row(t.label + (t == .identity ? "" : ""), symbol: t.symbol, count: model.count(.type(t))).tag(SidebarItem.type(t))
                }
            }

            Section {
                ForEach(model.folders) { f in
                    row(f.name ?? "", symbol: "folder", count: model.count(.folder(f.id)))
                        .tag(SidebarItem.folder(f.id))
                        .contextMenu {
                            Button("Rename…") { folderName = f.name ?? ""; renameFolder = f }
                            Button("Delete", role: .destructive) {
                                model.run("Delete folder") {
                                    try await model.service?.deleteFolder(f.id)
                                    await model.sync()
                                }
                            }
                        }
                }
                row("No Folder", symbol: "folder.badge.questionmark", count: model.count(.folder(nil))).tag(SidebarItem.folder(nil))
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button { folderName = ""; newFolder = true } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("New Folder")
                }
            }

            ForEach(model.organizations) { org in
                Section(org.name ?? "Organization") {
                    row("All Items", symbol: "building.2", count: model.count(.organization(org.id))).tag(SidebarItem.organization(org.id))
                    ForEach(model.collections.filter { $0.organizationId == org.id }) { c in
                        row(c.name ?? "", symbol: "folder.badge.person.crop", count: model.count(.collection(c.id))).tag(SidebarItem.collection(c.id))
                    }
                }
            }

            Section("Tools") {
                Label("Send", systemImage: "paperplane").tag(SidebarItem.sends)
                Label("Generator", systemImage: "wand.and.stars").tag(SidebarItem.generator)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SyncFooter() }
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

    func row(_ title: String, symbol: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).font(.caption).monospacedDigit()
        }
    }
}

struct Tile: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem
    let symbol: String
    let color: Color

    var body: some View {
        let selected = model.sidebar == item
        let count = item == .security ? model.health.flaggedCount : model.count(item)
        Button { model.sidebar = item; model.selectedId = nil } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(selected ? color : .white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(selected ? Color.white : color))
                    Spacer()
                    Text("\(count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
                }
                Text(item.title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? .white : .primary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
