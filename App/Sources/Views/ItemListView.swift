import SwiftUI
import SwiftwardenCore

struct ItemListView: View {
    @Environment(AppModel.self) private var model

    var title: String {
        switch model.sidebar {
        case let .folder(id): id == nil ? "No Folder" : model.folderName(id) ?? "Folder"
        case let .collection(id): model.collections.first { $0.id == id }?.name ?? "Collection"
        case let .organization(id): model.orgName(id) ?? "Organization"
        case let s?: s.title
        case nil: "All"
        }
    }

    var body: some View {
        @Bindable var model = model
        let items = model.items(for: model.sidebar)
        List(selection: $model.selectedId) {
            if model.sidebar == .security { SecurityHeader() }
            ForEach(items) { c in
                ItemRow(cipher: c).tag(c.id)
            }
            if model.sidebar == .security { SecurityFooter() }
        }
        .id(model.sidebar)
        .transaction { $0.animation = nil }
        .task(id: model.sidebar) {
            if model.sidebar == .security, Prefs.d.bool(forKey: Prefs.detectCompromised), !model.health.exposedChecked {
                await model.checkExposed()
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let c = model.cipher(ids.first) { ItemMenu(cipher: c) }
        } primaryAction: { ids in
            guard let c = model.cipher(ids.first) else { return }
            if model.sidebar == .codes, let t = c.login?.totp { model.copy(TOTP(t)?.code(), "code") }
            else if c.type == .login { model.copy(c.login?.password, "password") }
        }
        .onChange(of: model.selectedId) { _, _ in model.draft = nil }
        .overlay {
            if items.isEmpty && model.sidebar == .security && model.search.isEmpty {
                ContentUnavailableView("No Security Recommendations", systemImage: "checkmark.shield", description: Text("None of your passwords are reused, easily guessed, or found in known data leaks."))
            } else if items.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? "No Items" : "No Results", systemImage: model.search.isEmpty ? "tray" : "magnifyingglass")
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(model.sidebar == .codes ? "\(items.count) Verification Code\(items.count == 1 ? "" : "s")"
                            : model.sidebar == .security ? "\(items.count) Recommendation\(items.count == 1 ? "" : "s")" : "\(items.count) Items")
        .toolbar {
            if model.sidebar == .codes {
                if #available(macOS 26.0, *) {
                    ToolbarItem { CountdownRing().help("Codes refresh every 30 seconds") }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem { CountdownRing().help("Codes refresh every 30 seconds") }
                }
            }
            ToolbarItemGroup {
                if model.sidebar != .codes {
                Menu {
                    Picker("Sort By", selection: $model.sort) {
                        ForEach(SortOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .help("Sort")
                }
                if model.sidebar == .trash {
                    Button { model.emptyTrash() } label: { Image(systemName: "trash.slash").reportsToolbarEdge() }.help("Empty Trash").disabled(items.isEmpty)
                } else {
                    NewItemMenu()
                }
            }
        }
    }
}

struct NewItemMenu: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Menu {
            ForEach(CipherType.allCases, id: \.self) { t in
                Button { model.newItem(t) } label: { Label(t.label, systemImage: t.symbol) }
            }
        } label: { Image(systemName: "plus").reportsToolbarEdge() }
            .help("New Item")
    }
}

extension AppModel {
    func newItem(_ t: CipherType) {
        var c = Cipher(type: t)
        switch sidebar {
        case let .folder(id): c.folderId = id
        case .favorites: c.favorite = true
        case let .organization(o): c.organizationId = o
        case let .collection(cid): c.organizationId = collections.first { $0.id == cid }?.organizationId; c.collectionIds = [cid]
        default: break
        }
        if t == .login { c.login?.uris = [LoginUri(uri: "")] }
        if sidebar == .trash || sidebar == .sends || sidebar == .generator { sidebar = .all }
        selectedId = nil
        draft = c
    }
}

struct SecurityHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Swiftwarden privately and securely monitors your passwords to alert you if any are easily guessed, reused, or appear in data leaks from websites.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.checkingExposed {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking for data leaks…")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !model.health.exposedChecked {
                Button("Check for Data Leaks") { Task { await model.checkExposed() } }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
        .padding(.bottom, 10)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }
}

struct SecurityFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hidden = model.hiddenFlaggedCount
        if hidden > 0 {
            Button(model.showHiddenWarnings ? "Don’t Show Hidden Warnings" : "Show Hidden Warnings (\(hidden))") {
                model.showHiddenWarnings.toggle()
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .selectionDisabled()
        }
    }
}

extension View {
    func reportsToolbarEdge() -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { AppModel.shared.reportLastToolbarItemEdge($0) }
    }
}

struct CodeCell: View {
    @Environment(AppModel.self) private var model
    let secret: String
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button(action: copyCode) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(TOTP(secret).map { TOTPView.format($0.code(at: ctx.date)) } ?? "—")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .opacity(copied ? 0 : 1)
                    .overlay(alignment: .trailing) {
                        if copied { CopiedPill().fixedSize().transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity)) }
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to copy")
    }

    func copyCode() {
        model.copy(TOTP(secret)?.code(), "code", toast: false)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { copied = true }
        reset?.cancel()
        reset = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { copied = false }
        }
    }
}

struct CountdownRing: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let rem = 30 - Int(ctx.date.timeIntervalSince1970) % 30
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                Circle().trim(from: 0, to: CGFloat(rem) / 30)
                    .stroke(rem <= 5 ? Palette.red : Palette.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: rem)
            }
            .frame(width: 18, height: 18)
            .padding(.horizontal, 4)
        }
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.backgroundProminence) private var prominence
    let cipher: Cipher

    var body: some View {
        HStack(spacing: 10) {
            ItemIcon(cipher: cipher, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(cipher.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if model.sidebar == .security, let issue = model.issues(cipher).min(by: { $0.rank < $1.rank }) {
                    Text(issue.label + (model.isHidden(cipher.id) ? " · Hidden" : ""))
                        .font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(issue.isSevere && prominence != .increased && model.selectedId != cipher.id ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                } else {
                    Text(cipher.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if model.sidebar == .codes, let t = cipher.login?.totp {
                CodeCell(secret: t)
            } else if model.sidebar == .security {
                EmptyView()
            } else if model.health.exposed[cipher.id] != nil {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red).font(.system(size: 17))
            } else if model.health.flagged(cipher.id) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.primary, Color.primary.opacity(0.15)).font(.system(size: 17))
            }
        }
        .padding(.vertical, 5)
        .draggable(cipher.login?.username ?? cipher.displayName)
    }
}

struct ItemMenu: View {
    @Environment(AppModel.self) private var model
    let cipher: Cipher

    var body: some View {
        if cipher.isDeleted {
            Button("Restore") { model.restore(cipher) }
            Button("Delete Permanently", role: .destructive) { model.trash(cipher) }
        } else {
            if cipher.type == .login {
                Button("Copy Username") { model.copy(cipher.login?.username, "username", sensitive: false) }
                if cipher.canViewPassword {
                    Button("Copy Password") { model.withReprompt(cipher) { model.copy(cipher.login?.password, "password") } }
                }
                if let t = cipher.login?.totp, let o = TOTP(t) {
                    Button("Copy Verification Code") { model.copy(o.code(), "code") }
                }
                if let u = cipher.login?.uris?.lazy.compactMap({ URLMatcher.launchURL($0.uri) }).first {
                    Button("Open Website") { NSWorkspace.shared.open(u) }
                }
            }
            if cipher.type == .card {
                Button("Copy Number") { model.withReprompt(cipher) { model.copy(cipher.card?.number, "number") } }
                Button("Copy Security Code") { model.withReprompt(cipher) { model.copy(cipher.card?.code, "security code") } }
            }
            if cipher.type == .secureNote { Button("Copy Note") { model.withReprompt(cipher) { model.copy(cipher.notes, "note") } } }
            if cipher.type == .sshKey { Button("Copy Public Key") { model.copy(cipher.sshKey?.publicKey, "public key", sensitive: false) } }
            Divider()
            Button(cipher.isFavorite ? "Unfavorite" : "Favorite") { model.toggleFavorite(cipher) }
            if cipher.canEdit {
                Menu("Move to Folder") {
                    Button("No Folder") { model.move(cipher, toFolder: nil) }
                    ForEach(model.folders) { f in Button(f.name ?? "") { model.move(cipher, toFolder: f.id) } }
                }
                Button("Edit") { model.selectedId = cipher.id; model.draft = cipher }
                Button("Clone") { model.clone(cipher) }
                Divider()
                Button("Delete", role: .destructive) { model.trash(cipher) }
            }
        }
    }
}

extension AppModel {
    func clone(_ c: Cipher) {
        var x = c
        x.id = ""
        x.name = (c.name ?? "") + " - Clone"
        x.attachments = nil
        x.passwordHistory = nil
        x.key = nil
        x.login?.fido2Credentials = nil
        selectedId = nil
        draft = x
    }

    func withReprompt(_ c: Cipher, _ action: @escaping () -> Void) {
        if !c.needsReprompt || repromptPassed.contains(c.id) { action(); return }
        pendingReprompt = PendingReprompt(id: c.id, action: action)
    }
}

struct PendingReprompt: Identifiable {
    let id: String
    let action: () -> Void
}














