import SwiftUI
import SwiftwardenCore

struct SuggestionView: View {
    @Environment(AppModel.self) private var model
    let target: FillTarget
    let matches: [Cipher]
    let onFill: (Cipher) -> Void
    let onSearch: () -> Void
    let onDismiss: () -> Void
    let onUnlocked: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.phase != .unlocked {
                HStack(spacing: 0) {
                    Button {
                        Task {
                            if await model.unlockWithBiometrics() { onUnlocked() } else { NSApp.activate(ignoringOtherApps: true) }
                        }
                    } label: {
                        Label(model.biometricEnabled ? "Unlock with Touch ID" : "Open Swiftwarden to unlock", systemImage: model.biometricEnabled ? "touchid" : "lock")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(SuggestionButtonStyle())
                    closeButton
                }
            } else {
                ForEach(matches) { c in
                    Button { onFill(c) } label: {
                        HStack(spacing: 8) {
                            ItemIcon(cipher: c, size: 24)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(c.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(c.type == .login ? (c.login?.username ?? "") : c.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(SuggestionButtonStyle())
                }
                if matches.isEmpty {
                    Text("No logins for \(target.contextLabel)").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 4)
                }
                if !matches.isEmpty { Divider().padding(.horizontal, 6) }
                HStack(spacing: 0) {
                    Button(action: onSearch) {
                        Label("Search vault…", systemImage: "magnifyingglass").font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(SuggestionButtonStyle())
                    closeButton
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
    }
}

extension SuggestionView {
    var closeButton: some View {
        Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) }
            .buttonStyle(.borderless)
            .padding(.trailing, 10)
            .help("Dismiss")
    }
}

struct SuggestionButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover || configuration.isPressed ? Color.accentColor.opacity(0.25) : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .padding(.horizontal, 4)
    }
}

struct QuickFillView: View {
    @Environment(AppModel.self) private var model
    let target: FillTarget
    let initial: [Cipher]
    let onFill: (Cipher) -> Void
    let onClose: () -> Void
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    var pool: SidebarItem { target.kind.isCard ? .type(.card) : target.kind.isIdentity ? .type(.identity) : .type(.login) }

    var results: [Cipher] {
        guard model.phase == .unlocked else { return [] }
        if query.isEmpty { return initial.isEmpty ? Array(model.items(for: pool, query: "").prefix(8)) : Array(initial.prefix(8)) }
        return Array(model.items(for: pool, query: query).prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Fill \(target.contextLabel)…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                    .onSubmit { if let c = results[safe: index] { onFill(c) } }
                    .onKeyPress(.downArrow) { index = min(index + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                    .onKeyPress(.escape) { onClose(); return .handled }
                    .onChange(of: query) { index = 0 }
            }
            .padding(10)
            if model.phase != .unlocked {
                Button("Unlock with Touch ID") { Task { _ = await model.unlockWithBiometrics() } }.padding(10)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { i, c in
                Button { onFill(c) } label: {
                    HStack(spacing: 8) {
                        ItemIcon(cipher: c, size: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(c.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(c.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if i == index { Text("↩").foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(i == index ? Color.accentColor.opacity(0.25) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
            }
        }
        .padding(.bottom, 6)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        .onAppear { focused = true }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}



struct RememberOfferView: View {
    let cipher: Cipher
    let place: String
    let onSave: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ItemIcon(cipher: cipher, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Remember for \(place)?").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("Suggest “\(cipher.displayName)” here next time.").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button("Not Now", action: onDismiss).controlSize(.small)
                Button("Save", action: onSave).controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
    }
}
