import SwiftUI
import SwiftwardenCore
import UniformTypeIdentifiers

struct ItemDetailContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.draft != nil {
                ItemEditView(c: Binding(get: { model.draft ?? Cipher() }, set: { model.draft = $0 }))
            } else if let c = model.cipher(model.selectedId) {
                ItemDetailView(cipher: c)
            } else if model.sidebar == .codes {
                ContentUnavailableView {
                    Label("No Verification Code Selected", systemImage: "lock.badge.clock.fill")
                } description: {
                    Text("Verification codes provide an extra layer of security to help keep your accounts safe.")
                } actions: {
                    Button("More About Verification Codes") {
                        NSWorkspace.shared.open(URL(string: "https://bitwarden.com/help/integrated-authenticator/")!)
                    }
                }
            } else {
                ContentUnavailableView("No Item Selected", systemImage: "key.viewfinder")
            }
        }
        .sheet(item: $model.pendingReprompt) { p in
            RepromptSheet { model.repromptPassed.insert(p.id); p.action() }
        }
    }
}

struct ItemDetailView: View {
    @Environment(AppModel.self) private var model
    let cipher: Cipher
    @State private var showHistory = false
    @State private var moveToOrg = false
    @State private var importingFile = false
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                let securityIssues = model.sidebar == .security ? model.issues(cipher) : []
                if !securityIssues.isEmpty {
                    SecurityHero(cipher: cipher, issues: securityIssues)
                    GroupCard {
                        VStack(spacing: 0) { rows }.padding(.top, -1).clipped().padding(.horizontal, 6).padding(.vertical, 6)
                    }
                } else {
                    GroupCard {
                        VStack(spacing: 10) {
                            ItemIcon(cipher: cipher, size: 64)
                            Text(cipher.displayName).font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center).textSelection(.enabled)
                        }
                        .padding(.top, 20).padding(.bottom, 14).frame(maxWidth: .infinity)
                        VStack(spacing: 0) { rows }.padding(.horizontal, 6).padding(.bottom, 6)
                    }
                    IssueCards(cipher: cipher)
                }
                if !(cipher.attachments ?? []).isEmpty { attachmentsCard }
            }
            .padding(16)
            .frame(minWidth: 320, idealWidth: 520, maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .toolbar { toolbar }
        .sheet(isPresented: $moveToOrg) { MoveToOrgSheet(cipher: cipher) }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item]) { r in
            guard let url = try? r.get() else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            model.run("Upload") {
                busy = true; defer { busy = false }
                try await model.service?.uploadAttachment(cipher: cipher, fileName: url.lastPathComponent, data: data)
                await model.sync()
            }
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if cipher.isDeleted {
                Button("Restore") { model.restore(cipher) }
                Button("Delete", role: .destructive) { model.trash(cipher) }
            } else {
                Button { model.toggleFavorite(cipher) } label: { Image(systemName: cipher.isFavorite ? "star.fill" : "star") }
                    .help("Favorite")
                if cipher.canEdit {
                    Button("Edit") { model.withReprompt(cipher) { model.draft = cipher } }
                }
                Menu {
                    ItemMenu(cipher: cipher)
                    if cipher.canEdit { Button("Add Attachment…") { importingFile = true } }
                    if cipher.organizationId == nil && !model.organizations.isEmpty && cipher.canEdit {
                        Button("Move to Organization…") { moveToOrg = true }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    func copier(_ v: String?, _ label: String, secret: Bool = false) -> (() -> Bool) {
        {
            if secret && cipher.needsReprompt && !model.repromptPassed.contains(cipher.id) {
                model.withReprompt(cipher) { model.copy(v, label) }
                return false
            }
            model.copy(v, label, sensitive: secret, toast: false)
            return true
        }
    }

    @ViewBuilder func row(_ label: String, _ value: String?, secret: Bool = false, copy: Bool = true) -> some View {
        if let value, !value.isEmpty {
            RowDivider()
            DetailRow(label: label, copy: copy ? copier(value, label.lowercased(), secret: secret) : nil) {
                if secret { SecretValue(cipher: cipher, text: value) } else { Text(value).textSelection(.enabled).lineLimit(4) }
            }
        }
    }

    @ViewBuilder var rows: some View {
        switch cipher.type {
        case .login:
            row("Username", cipher.login?.username)
            if cipher.canViewPassword { row("Password", cipher.login?.password, secret: true) }
            if let t = cipher.login?.totp, !t.isEmpty {
                RowDivider()
                DetailRow(label: "Code", copy: copier(TOTP(t)?.code(), "code")) { TOTPView(secret: t) }
            }
            ForEach(Array((cipher.login?.fido2Credentials ?? []).enumerated()), id: \.offset) { _, p in
                RowDivider()
                DetailRow(label: "Passkey") {
                    Text("Created " + (Dates.parse(p.creationDate)?.formatted(date: .abbreviated, time: .omitted) ?? ""))
                }
            }
            ForEach(Array((cipher.login?.uris ?? []).enumerated()), id: \.offset) { i, u in
                if let s = u.uri, !s.isEmpty {
                    RowDivider()
                    DetailRow(label: i == 0 ? "Website" : "", copy: copier(s, "website")) {
                        HStack(spacing: 6) {
                            Text(URLMatcher.host(of: s) ?? s).lineLimit(1)
                            if let url = URL(string: s.contains("://") ? s : "https://" + s), URLMatcher.host(of: s) != nil {
                                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        case .card:
            row("Cardholder", cipher.card?.cardholderName)
            row("Brand", cipher.card?.brand, copy: false)
            row("Number", cipher.card?.number, secret: true)
            let exp = [cipher.card?.expMonth, cipher.card?.expYear].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " / ")
            row("Expiration", exp)
            row("Security Code", cipher.card?.code, secret: true)
        case .identity:
            let i = cipher.identity ?? Identity()
            row("Name", i.fullName)
            row("Username", i.username)
            row("Company", i.company)
            row("Email", i.email)
            row("Phone", i.phone)
            row("SSN", i.ssn, secret: true)
            row("Passport", i.passportNumber, secret: true)
            row("License", i.licenseNumber, secret: true)
            let addr = [i.address1, i.address2, i.address3, [i.postalCode, i.city].compactMap { $0 }.joined(separator: " "), i.state, i.country]
                .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
            row("Address", addr)
        case .sshKey:
            row("Private Key", cipher.sshKey?.privateKey, secret: true)
            row("Public Key", cipher.sshKey?.publicKey)
            row("Fingerprint", cipher.sshKey?.keyFingerprint)
        case .secureNote:
            EmptyView()
        }
        ForEach(cipher.fields ?? []) { f in
            RowDivider()
            DetailRow(label: f.name ?? "", copy: f.type == .boolean || f.type == .linked ? nil : copier(f.value, f.name ?? "field", secret: f.type == .hidden)) {
                switch f.type {
                case .hidden: SecretValue(cipher: cipher, text: f.value ?? "")
                case .boolean: Image(systemName: f.value == "true" ? "checkmark.square.fill" : "square")
                case .linked: Text("Linked: " + linkedName(f.linkedId))
                case .text: Text(f.value ?? "").textSelection(.enabled)
                }
            }
        }
        if let f = model.folderName(cipher.folderId) { row("Folder", f, copy: false) }
        if let o = model.orgName(cipher.organizationId) {
            row("Organization", o, copy: false)
            row("Collections", model.collectionNames(cipher.collectionIds).joined(separator: ", "), copy: false)
        }
        if let d = Dates.parse(cipher.revisionDate) { row("Modified", d.formatted(date: .numeric, time: .shortened), copy: false) }
        if let d = Dates.parse(cipher.creationDate) { row("Created", d.formatted(date: .numeric, time: .shortened), copy: false) }
        if let d = Dates.parse(cipher.login?.passwordRevisionDate) { row("Password Updated", d.formatted(date: .numeric, time: .shortened), copy: false) }
        if let h = cipher.passwordHistory, !h.isEmpty, cipher.canViewPassword {
            RowDivider()
            DetailRow(label: "Password History", action: { model.withReprompt(cipher) { showHistory = true } }) {
                Text("\(h.count)").popover(isPresented: $showHistory) { PasswordHistoryList(entries: h).frame(width: 360, height: 260) }
            }
        }
        if let n = cipher.notes, !n.isEmpty {
            RowDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                if cipher.needsReprompt && !model.repromptPassed.contains(cipher.id) {
                    Button("Show Notes") { model.withReprompt(cipher) {} }
                } else {
                    Text(n).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
    }

    func linkedName(_ id: Int?) -> String {
        switch id {
        case 100: "Username"
        case 101: "Password"
        case 300: "Cardholder Name"
        case 301: "Expiration Month"
        case 302: "Expiration Year"
        case 303: "Security Code"
        case 304: "Brand"
        case 305: "Number"
        default: "Field"
        }
    }

    var attachmentsCard: some View {
        GroupCard {
            HStack {
                Text("Attachments").font(.system(size: 13, weight: .semibold))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if cipher.canEdit && !cipher.isDeleted {
                    Button { importingFile = true } label: { Image(systemName: "paperclip.badge.plus") }.buttonStyle(.borderless).help("Add Attachment")
                }
            }
            .padding(12)
            ForEach(cipher.attachments ?? []) { a in
                RowDivider()
                HStack {
                    Image(systemName: "doc")
                    Text(a.fileName ?? "file").lineLimit(1)
                    Spacer()
                    Text(a.sizeName ?? "").foregroundStyle(.secondary).font(.caption)
                    Button { download(a) } label: { Image(systemName: "arrow.down.circle") }.buttonStyle(.borderless)
                    if cipher.canEdit {
                        Button {
                            model.run("Delete attachment") {
                                try await model.service?.deleteAttachment(cipherId: cipher.id, attachmentId: a.id)
                                await model.sync()
                            }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    func download(_ a: Attachment) {
        model.withReprompt(cipher) {
            model.run("Download") {
                guard let d = try await model.service?.downloadAttachment(cipher: cipher, attachment: a) else { return }
                revealInFinderSave(d, name: a.fileName ?? "attachment")
            }
        }
    }
}

struct SecretValue: View {
    @Environment(AppModel.self) private var model
    let cipher: Cipher
    let text: String
    @State private var shown = false

    var body: some View {
        HStack(spacing: 6) {
            if shown {
                Text(text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).lineLimit(nil)
            } else {
                Text(String(repeating: "•", count: min(max(text.count, 8), 24))).lineLimit(1)
            }
            Button { model.withReprompt(cipher) { shown.toggle() } } label: { Image(systemName: shown ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
        }
    }
}

struct PasswordHistoryList: View {
    @Environment(AppModel.self) private var model
    let entries: [PasswordHistory]
    var body: some View {
        List(Array(entries.enumerated()), id: \.offset) { _, e in
            HStack {
                VStack(alignment: .leading) {
                    Text(e.password ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                    Text(Dates.parse(e.lastUsedDate)?.formatted() ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.copy(e.password, "password") } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
            }
        }
    }
}

struct SecurityHero: View {
    @Environment(AppModel.self) private var model
    let cipher: Cipher
    let issues: [SecurityIssue]

    var website: URL? {
        guard let u = cipher.login?.uris?.first(where: { URLMatcher.host(of: $0.uri ?? "") != nil })?.uri else { return nil }
        return URL(string: u.contains("://") ? u : "https://" + u)
    }

    var title: String {
        if issues.contains(where: { if case .exposed = $0 { true } else { false } }) { return "This password appeared in a data leak." }
        if issues.allSatisfy({ $0 == .unsecured }) { return "This website isn’t secure." }
        return "This password should be changed."
    }

    var message: String {
        var parts: [String] = []
        for issue in issues.sorted(by: { $0.rank < $1.rank }) {
            switch issue {
            case let .exposed(n):
                parts.append("It was found \(n.formatted()) time\(n == 1 ? "" : "s") in known data leaks, which puts this account at high risk.")
            case .reused:
                let others = model.reusedWith(cipher).map(\.displayName)
                let shown = others.prefix(2).map { "“\($0)”" }
                var list = shown.joined(separator: " and ")
                if others.count > 2 { list = shown.joined(separator: ", ") + " and \(others.count - 2) other\(others.count - 2 == 1 ? "" : "s")" }
                parts.append(others.isEmpty ? "You’re using this password for more than one account." : "You’re already using the password for “\(cipher.displayName)” with \(list).")
            case .weak:
                parts.append("This password is easy to guess.")
            case .unsecured:
                parts.append("A website for this item uses an unencrypted http:// address.")
            }
        }
        if issues.contains(where: { $0 != .unsecured }) {
            parts.append("Change it on the website, then save a new, generated password here to help keep your account safe.")
        }
        return parts.joined(separator: " ")
    }

    @ViewBuilder func actions(fill: Bool) -> some View {
        let hidden = model.isHidden(cipher.id)
        if let website {
            Button { NSWorkspace.shared.open(website) } label: { Text("Change Password on Website…").fixedSize().frame(maxWidth: .infinity) }
        }
        Button { model.setHidden(cipher.id, !hidden) } label: { Text(hidden ? "Unhide" : "Hide").fixedSize().frame(maxWidth: .infinity) }
    }

    var body: some View {
        GroupCard {
            VStack(spacing: 12) {
                ItemIcon(cipher: cipher, size: 64)
                Text(title).font(.system(size: 20, weight: .bold)).multilineTextAlignment(.center)
                Text(message)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions(fill: true) }
                    VStack(spacing: 8) { actions(fill: true) }
                }
                .controlSize(.large)
                .frame(maxWidth: 480)
                .padding(.top, 4)
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
    }
}

struct IssueCards: View {
    @Environment(AppModel.self) private var model
    let cipher: Cipher

    var body: some View {
        let h = model.health
        if let n = h.exposed[cipher.id] {
            issue("exclamationmark.shield.fill", .red, "Compromised Password",
                  "This password appeared in \(n.formatted()) data breaches. Change it as soon as possible.")
        }
        if let n = h.reused[cipher.id] {
            issue("arrow.triangle.2.circlepath", .orange, "Reused Password", "This password is used for \(n) accounts. Use a unique password for each account.")
        }
        if h.weak.contains(cipher.id) {
            issue("exclamationmark.triangle.fill", .yellow, "Weak Password", "This password is easy to guess. Change it to a strong password.")
        }
        if h.unsecured.contains(cipher.id) {
            issue("lock.open.fill", .purple, "Unsecured Website", "A website uses http://. Update it to https:// if the site supports it.")
        }
        if cipher.type == .login, cipher.canViewPassword, !(cipher.login?.password ?? "").isEmpty, !h.flagged(cipher.id), !cipher.isDeleted {
            GroupCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "shield").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary).frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No Issues Found").font(.system(size: 13, weight: .semibold))
                        Text("This password doesn’t appear to contain words or patterns that may be obvious to an attacker, and you aren’t reusing it for other items in your vault." + (h.exposedChecked ? " It wasn’t found in known data breaches." : ""))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
        }
    }

    func issue(_ symbol: String, _ color: Color, _ title: String, _ text: String) -> some View {
        GroupCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            Divider().padding(.horizontal, 12)
            HStack {
                Spacer()
                if let u = cipher.login?.uris?.first?.uri, let url = URL(string: u.contains("://") ? u : "https://" + u) {
                    Button("Change Password…") { NSWorkspace.shared.open(url) }
                }
                if cipher.canEdit {
                    Button("Generate New…") {
                        var d = cipher
                        d.login?.password = Generator.password(Prefs.codable(Prefs.passwordOptions, default: PasswordOptions()))
                        model.draft = d
                    }
                }
            }
            .padding(10)
        }
    }
}

struct MoveToOrgSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let cipher: Cipher
    @State private var org: String = ""
    @State private var cols: Set<String> = []
    @State private var busy = false

    var body: some View {
        Form {
            Picker("Organization", selection: $org) {
                ForEach(model.organizations) { Text($0.name ?? "").tag($0.id) }
            }
            Section("Collections") {
                ForEach(model.writableCollections(org)) { c in
                    Toggle(c.name ?? "", isOn: Binding(get: { cols.contains(c.id) }, set: { if $0 { cols.insert(c.id) } else { cols.remove(c.id) } }))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 340)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Move") {
                    busy = true
                    model.run("Move") {
                        defer { busy = false }
                        guard let s = try await model.service?.share(cipher, organizationId: org, collectionIds: Array(cols)) else { return }
                        model.upsert(s)
                        dismiss()
                    }
                }
                .disabled(org.isEmpty || cols.isEmpty || busy)
            }
        }
        .onAppear { org = model.organizations.first?.id ?? "" }
    }
}






