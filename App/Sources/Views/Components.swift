import AppKit
import CryptoKit
import SwiftUI
import SwiftwardenCore

enum Palette {
    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255) }
    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    static let blue = rgb(0, 112, 245)
    static let green = rgb(29, 195, 55)
    static let yellow = rgb(236, 187, 15)
    static let cyan = rgb(65, 175, 220)
    static let red = rgb(235, 49, 40)
    static let orange = rgb(245, 139, 1)
    static let purple = rgb(150, 90, 230)
    static let tile = dynamic(dark: NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 59 / 255, alpha: 1),
                              light: NSColor(white: 0, alpha: 0.06))
    static let card = dynamic(dark: NSColor(srgbRed: 36 / 255, green: 36 / 255, blue: 37 / 255, alpha: 1), light: .white)
    static let pill = dynamic(dark: NSColor(white: 1, alpha: 0.1), light: NSColor(white: 0, alpha: 0.07))
}

struct IconEntry: @unchecked Sendable {
    let image: NSImage
    let tint: NSColor
}

actor IconStore {
    static let shared = IconStore()
    private var mem: [String: IconEntry] = [:]
    private var missing: Set<String> = []
    private var inflight: [String: Task<IconEntry?, Never>] = [:]

    func icon(_ host: String, base: String) async -> IconEntry? {
        if let i = mem[host] { return i }
        if missing.contains(host) { return nil }
        if let t = inflight[host] { return await t.value }
        let file = Paths.caches.appendingPathComponent("icons/\(host).png")
        let t = Task<IconEntry?, Never> {
            var data = try? Data(contentsOf: file)
            if data == nil, let url = URL(string: "\(base)/\(host)/icon.png"),
               let (d, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? d.write(to: file)
                data = d
            }
            guard let data, !data.isEmpty, !Self.fallbackHashes.contains(Data(SHA256.hash(data: data)).hex),
                  let i = NSImage(data: data), let rep = i.representations.first, rep.pixelsWide >= 24 || i.size.width >= 24 else {
                try? Data().write(to: file)
                return nil
            }
            return IconEntry(image: i, tint: Self.tint(of: i))
        }
        inflight[host] = t
        let i = await t.value
        inflight[host] = nil
        if let i { mem[host] = i } else { missing.insert(host) }
        return i
    }

    static let fallbackHashes: Set<String> = [
        "01d7ddb3c3c46ca24f7d911abd32849aa19627c8be515273bdfb98100460aacb",
        "aaa64871332ad5b7d28fe8874efb19c2d9cc2f1e6de75d52b080b438225a0783",
    ]

    static func tint(of img: NSImage) -> NSColor {
        let n = 16
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return NSColor(white: 0.3, alpha: 1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        img.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()
        var r = 0.0, g = 0.0, b = 0.0, w = 0.0
        for x in 0 ..< n {
            for y in 0 ..< n {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.3 else { continue }
                let sat = c.saturationComponent, bri = c.brightnessComponent
                if bri > 0.92 && sat < 0.1 { continue }
                let weight = c.alphaComponent * (0.15 + sat)
                r += c.redComponent * weight; g += c.greenComponent * weight; b += c.blueComponent * weight; w += weight
            }
        }
        guard w > 0 else { return NSColor(white: 0.3, alpha: 1) }
        let avg = NSColor(deviceRed: r / w, green: g / w, blue: b / w, alpha: 1)
        return NSColor(deviceHue: avg.hueComponent, saturation: min(avg.saturationComponent * 1.1, 1),
                       brightness: min(avg.brightnessComponent * 0.55, 0.45), alpha: 1)
    }
}

struct LetterTile: View {
    let text: String
    let size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Color(nsColor: .systemGray))
            .overlay(Text(String(text.prefix(1)).uppercased()).font(.system(size: size * 0.62, weight: .light)).foregroundStyle(.white))
    }
}

struct ItemIcon: View {
    let cipher: Cipher
    var size: CGFloat = 32
    @AppStorage(Prefs.showIcons) private var showIcons = true
    @State private var icon: IconEntry?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            if cipher.organizationId != nil {
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.44, height: size * 0.44)
                    .background(Circle().fill(badgeColor))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: max(1.5, size * 0.04)))
                    .offset(x: size * 0.14, y: size * 0.14)
            }
        }
        .task(id: cipher.id + "|" + (cipher.primaryHost ?? "")) {
            icon = nil
            guard showIcons, cipher.type == .login, let h = cipher.primaryHost, let base = AppModel.shared.account?.env.iconsURL else { return }
            icon = await IconStore.shared.icon(h, base: base)
        }
    }

    var badgeColor: Color {
        if let icon, showIcons { return Color(nsColor: icon.tint) }
        if cipher.type != .login { return Color(nsColor: NSColor(typeColor(cipher.type)).blended(withFraction: 0.45, of: .black) ?? .darkGray) }
        return Color(white: 0.32)
    }

    @ViewBuilder var content: some View {
        if let icon, showIcons {
            Image(nsImage: icon.image).resizable().interpolation(.high).scaledToFit()
        } else if cipher.type == .login {
            LetterTile(text: cipher.displayName, size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(typeColor(cipher.type))
                .overlay(Image(systemName: cipher.type.symbol).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(.white))
        }
    }
}

func typeColor(_ t: CipherType) -> Color {
    switch t {
    case .login: Palette.blue
    case .card: Palette.orange
    case .identity: Palette.green
    case .secureNote: Palette.yellow
    case .sshKey: Palette.purple
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
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.horizontal, 10) }
}

struct CopiedPill: View {
    var body: some View {
        Label("Copied", systemImage: "doc.on.doc.fill")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.pill))
    }
}

struct DetailRow<Value: View>: View {
    let label: String
    var copy: (() -> Bool)?
    var action: (() -> Void)?
    @ViewBuilder var value: Value
    @State private var hover = false
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary.opacity(0.9))
                .fixedSize()
            Spacer(minLength: 16)
            value.font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                .layoutPriority(-1)
                .opacity(copied ? 0 : 1)
                .scaleEffect(copied ? 0.92 : 1, anchor: .trailing)
                .blur(radius: copied ? 2 : 0)
        }
        .padding(.horizontal, 10)
        .overlay(alignment: .trailing) {
            if copied {
                CopiedPill()
                    .padding(.trailing, 4)
                    .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover && (copy != nil || action != nil) ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if let copy {
                guard copy() else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { copied = true }
                resetTask?.cancel()
                resetTask = Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { copied = false }
                }
            } else {
                action?()
            }
        }
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




