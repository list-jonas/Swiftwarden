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
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
                Tile(item: .all, symbol: "key.fill", color: Palette.blue)
                Tile(item: .favorites, symbol: "star.fill", color: Palette.yellow)
                Tile(item: .codes, symbol: "lock.rotation", color: Palette.cyan)
                Tile(item: .passkeys, symbol: "person.badge.key.fill", color: Palette.green)
                Tile(item: .security, symbol: "exclamationmark", color: Palette.red)
                Tile(item: .trash, symbol: "trash.fill", color: Palette.orange)
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            .selectionDisabled()

            if !model.organizations.isEmpty {
                Section("Vaults") {
                    row("My Vault", symbol: "person.crop.circle", count: model.count(.personal)).tag(SidebarItem.personal)
                    ForEach(model.organizations) { org in
                        row(org.name ?? "Organization", symbol: "folder.badge.person.crop", count: model.count(.organization(org.id)))
                            .tag(SidebarItem.organization(org.id))
                        ForEach(model.collections.filter { $0.organizationId == org.id }) { c in
                            row(c.name ?? "", symbol: "folder", count: model.count(.collection(c.id)))
                                .padding(.leading, 18)
                                .tag(SidebarItem.collection(c.id))
                        }
                    }
                }
            }

            Section("Types") {
                ForEach(CipherType.allCases, id: \.self) { t in
                    row(t.label, symbol: t.symbol, count: model.count(.type(t))).tag(SidebarItem.type(t))
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
        Button { model.sidebar = item; model.selectedId = nil } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
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
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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


