import AppKit
import SwiftUI
import SwiftwardenCore

actor IconStore {
    static let shared = IconStore()
    private var mem: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    func icon(_ host: String, base: String) async -> NSImage? {
        if let i = mem[host] { return i }
        if missing.contains(host) { return nil }
        if let t = inflight[host] { return await t.value }
        let file = Paths.caches.appendingPathComponent("icons/\(host).png")
        let t = Task<NSImage?, Never> {
            if let d = try? Data(contentsOf: file), let i = NSImage(data: d) { return i }
            guard let url = URL(string: "\(base)/\(host)/icon.png"),
                  let (d, r) = try? await URLSession.shared.data(from: url),
                  (r as? HTTPURLResponse)?.statusCode == 200, let i = NSImage(data: d), i.size.width > 1 else { return nil }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: file)
            return i
        }
        inflight[host] = t
        let i = await t.value
        inflight[host] = nil
        if let i { mem[host] = i } else { missing.insert(host) }
        return i
    }
}

struct LetterTile: View {
    let text: String
    let size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22)
            .fill(Color(nsColor: .systemGray))
            .overlay(Text(String(text.prefix(1)).uppercased()).font(.system(size: size * 0.55, weight: .regular)).foregroundStyle(.white))
    }
}

struct ItemIcon: View {
    let cipher: Cipher
    var size: CGFloat = 32
    @AppStorage(Prefs.showIcons) private var showIcons = true
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            if cipher.organizationId != nil {
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(Circle().fill(Color(white: 0.22)))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: size * 0.14, y: size * 0.14)
            }
        }
        .task(id: cipher.primaryHost) {
            guard showIcons, cipher.type == .login, let h = cipher.primaryHost, let base = AppModel.shared.account?.env.iconsURL else { return }
            image = await IconStore.shared.icon(h, base: base)
        }
    }

    @ViewBuilder var content: some View {
        if let image, showIcons {
            ZStack {
                Color.white
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(size * 0.12)
            }
        } else if cipher.type == .login {
            LetterTile(text: cipher.displayName, size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(typeColor(cipher.type).gradient)
                .overlay(Image(systemName: cipher.type.symbol).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(.white))
        }
    }
}

func typeColor(_ t: CipherType) -> Color {
    switch t {
    case .login: .blue
    case .card: .orange
    case .identity: .green
    case .secureNote: .yellow
    case .sshKey: .purple
    }
}

struct TOTPView: View {
    let secret: String
    var font: Font = .system(size: 13, weight: .semibold).monospacedDigit()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let t = TOTP(secret) {
                let rem = t.remaining(at: ctx.date)
                HStack(spacing: 8) {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                        Circle().trim(from: 0, to: CGFloat(rem) / CGFloat(t.period))
                            .stroke(rem <= 5 ? Color.red : Color.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: rem)
                    }
                    .frame(width: 14, height: 14)
                    Text(Self.format(t.code(at: ctx.date))).font(font)
                }
            } else {
                Text("Invalid key").foregroundStyle(.red)
            }
        }
    }

    static func format(_ c: String) -> String {
        guard c.count >= 6, c.allSatisfy(\.isNumber) else { return c }
        let mid = c.index(c.startIndex, offsetBy: c.count / 2)
        return c[..<mid] + " " + c[mid...]
    }
}

struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.06)))
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 10) }
}

struct DetailRow<Value: View>: View {
    let label: String
    var action: (() -> Void)?
    @ViewBuilder var value: Value
    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary.opacity(0.85))
            Spacer(minLength: 16)
            value.font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover && action != nil ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { action?() }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8, y: 2)
    }
}

struct SecureReveal: View {
    let text: String
    @State private var shown = false
    var body: some View {
        HStack(spacing: 6) {
            Text(shown ? text : String(repeating: "•", count: min(max(text.count, 8), 20)))
                .font(.system(size: 13, design: shown ? .monospaced : .default))
                .textSelection(.enabled)
            Button { shown.toggle() } label: { Image(systemName: shown ? "eye.slash" : "eye") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }
}

struct RepromptSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onSuccess: () -> Void
    @State private var pw = ""
    @State private var bad = false
    @State private var busy = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.tint)
            Text("Master password re-prompt").font(.headline)
            Text("This item is protected. Confirm your master password to continue.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField("Master password", text: $pw).textFieldStyle(.roundedBorder).onSubmit(verify)
            if bad { Text("Invalid master password").foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: verify) { if busy { ProgressView().controlSize(.small) } else { Text("Confirm") } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 340)
    }

    func verify() {
        busy = true
        Task {
            if await model.verifyMasterPassword(pw) { dismiss(); onSuccess() } else { bad = true }
            busy = false
        }
    }
}

func revealInFinderSave(_ data: Data, name: String) {
    let p = NSSavePanel()
    p.nameFieldStringValue = name
    if p.runModal() == .OK, let u = p.url { try? data.write(to: u) }
}
