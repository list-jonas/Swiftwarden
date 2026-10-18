import SwiftUI
import SwiftwardenCore

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .unlocked: unlocked
            case .locked:
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill").font(.title).foregroundStyle(.tint)
                    Text("Vault locked").font(.headline)
                    if model.biometricEnabled {
                        Button { Task { _ = await model.unlockWithBiometrics() } } label: { Label("Unlock with Touch ID", systemImage: "touchid") }
                    }
                    Button("Open Swiftwarden") { open() }
                }
                .padding(20)
            case .loggedOut:
                Button("Open Swiftwarden to log in") { open() }.padding(20)
            }
            Divider()
            HStack {
                Button("Open Swiftwarden") { open() }
                Spacer()
                if model.phase == .unlocked { Button { model.lock() } label: { Image(systemName: "lock") }.help("Lock") }
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit")
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .frame(width: 340)
    }

    var unlocked: some View {
        VStack(spacing: 0) {
            TextField("Search vault", text: $query).textFieldStyle(.roundedBorder).padding(10)
            let items = Array(model.items(for: query.isEmpty ? .favorites : .all, query: query).prefix(query.isEmpty ? 12 : 30))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { c in MenuBarRow(cipher: c) }
                    if items.isEmpty {
                        Text(query.isEmpty ? "Favorites appear here. Type to search." : "No results").font(.callout).foregroundStyle(.secondary).padding()
                    }
                }
            }
            .frame(maxHeight: 360)
            HStack {
                Button {
                    let g = GeneratorModel()
                    let v = g.type == "passphrase" ? Generator.passphrase(g.pp) : Generator.password(g.pw)
                    model.copy(v, "generated password"); model.recordGenerated(v)
                } label: { Label("Copy New Password", systemImage: "wand.and.stars") }
                Spacer()
                if model.syncing { ProgressView().controlSize(.small) }
                Button { Task { await model.sync() } } label: { Image(systemName: "arrow.triangle.2.circlepath") }.help("Sync")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    func open() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuBarRow: View {
    @Environment(AppModel.self) private var model
    let cipher: Cipher
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            ItemIcon(cipher: cipher, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(cipher.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(cipher.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if hover {
                if cipher.type == .login {
                    Button { model.copy(cipher.login?.username, "username", sensitive: false) } label: { Image(systemName: "person") }.help("Copy username")
                    if cipher.canViewPassword {
                        Button { model.withReprompt(cipher) { model.copy(cipher.login?.password, "password") } } label: { Image(systemName: "key") }.help("Copy password")
                    }
                    if let t = cipher.login?.totp, let o = TOTP(t) {
                        Button { model.copy(o.code(), "code") } label: { Image(systemName: "clock") }.help("Copy code")
                    }
                } else if cipher.type == .card {
                    Button { model.withReprompt(cipher) { model.copy(cipher.card?.number, "number") } } label: { Image(systemName: "creditcard") }
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(hover ? Color.primary.opacity(0.07) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if cipher.type == .login, cipher.canViewPassword { model.withReprompt(cipher) { model.copy(cipher.login?.password, "password") } }
        }
    }
}
