import SwiftUI
import SwiftwardenCore

struct ItemEditView: View {
    @Environment(AppModel.self) private var model
    @Binding var c: Cipher
    @State private var collectionIds: Set<String> = []
    @State private var saving = false
    @State private var showGenerator = false

    var isNew: Bool { c.id.isEmpty }

    func b(_ kp: WritableKeyPath<Cipher, String?>) -> Binding<String> {
        Binding(get: { c[keyPath: kp] ?? "" }, set: { c[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: b(\.name))
                Picker("Folder", selection: $c.folderId) {
                    Text("No Folder").tag(String?.none)
                    ForEach(model.folders) { Text($0.name ?? "").tag(Optional($0.id)) }
                }
                Toggle("Favorite", isOn: Binding(get: { c.isFavorite }, set: { c.favorite = $0 }))
                Toggle("Master password re-prompt", isOn: Binding(get: { c.needsReprompt }, set: { c.reprompt = $0 ? 1 : 0 }))
            } header: {
                Label(isNew ? "New \(c.type.label)" : "Edit \(c.type.label)", systemImage: c.type.symbol).font(.headline)
            }

            if isNew && !model.organizations.isEmpty {
                Section("Ownership") {
                    Picker("Owner", selection: $c.organizationId) {
                        Text("My Vault").tag(String?.none)
                        ForEach(model.organizations) { Text($0.name ?? "").tag(Optional($0.id)) }
                    }
                    if let org = c.organizationId {
                        ForEach(model.writableCollections(org)) { col in
                            Toggle(col.name ?? "", isOn: Binding(get: { collectionIds.contains(col.id) },
                                                                 set: { if $0 { collectionIds.insert(col.id) } else { collectionIds.remove(col.id) } }))
                        }
                    }
                }
            }

            switch c.type {
            case .login: loginSection
            case .card: cardSection
            case .identity: identitySection
            case .sshKey: sshSection
            case .secureNote: EmptyView()
            }

            Section("Notes") {
                TextEditor(text: b(\.notes)).frame(minHeight: 80).font(.body)
            }

            Section {
                ForEach($c.fields.unwrap()) { $f in
                    HStack {
                        TextField("Name", text: Binding(get: { f.name ?? "" }, set: { f.name = $0 })).frame(maxWidth: 140)
                        switch f.type {
                        case .boolean:
                            Toggle("", isOn: Binding(get: { f.value == "true" }, set: { f.value = $0 ? "true" : "false" })).labelsHidden()
                            Spacer()
                        case .linked:
                            Picker("", selection: Binding(get: { f.linkedId ?? 100 }, set: { f.linkedId = $0 })) {
                                Text("Username").tag(100); Text("Password").tag(101)
                            }.labelsHidden()
                        case .hidden:
                            SecureField("Value", text: Binding(get: { f.value ?? "" }, set: { f.value = $0 }))
                        case .text:
                            TextField("Value", text: Binding(get: { f.value ?? "" }, set: { f.value = $0 }))
                        }
                        Button(role: .destructive) { c.fields?.removeAll { $0.id == f.id } } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.red)
                    }
                }
                Menu("Add Field") {
                    ForEach(FieldType.allCases, id: \.self) { t in
                        if t != .linked || c.type == .login {
                            Button(t.label) { c.fields = (c.fields ?? []) + [Field(type: t, linkedId: t == .linked ? 100 : nil)] }
                        }
                    }
                }
            } header: { Text("Custom Fields") }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Cancel") { model.draft = nil }.keyboardShortcut(.cancelAction)
                Button { save() } label: { if saving { ProgressView().controlSize(.small) } else { Text("Save") } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled((c.name ?? "").isEmpty || saving || (c.organizationId != nil && isNew && collectionIds.isEmpty))
                    .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { collectionIds = Set(c.collectionIds ?? []); ensureSub() }
    }

    func ensureSub() {
        switch c.type {
        case .login: if c.login == nil { c.login = Login() }
        case .card: if c.card == nil { c.card = Card() }
        case .identity: if c.identity == nil { c.identity = Identity() }
        case .sshKey: if c.sshKey == nil { c.sshKey = SSHKeyData() }
        case .secureNote: if c.secureNote == nil { c.secureNote = SecureNote() }
        }
    }

    func save() {
        saving = true
        let item = c, cols = Array(collectionIds)
        Task {
            do {
                let s = try await model.save(item, collectionIds: cols)
                model.draft = nil
                model.selectedId = s.id
            } catch {
                model.errorMessage = "Save failed: \(error.localizedDescription)"
            }
            saving = false
        }
    }

    @ViewBuilder var loginSection: some View {
        Section("Login") {
            TextField("Username", text: b(\.login!.username))
            HStack {
                SecureFieldToggle(title: "Password", text: b(\.login!.password))
                Button { showGenerator = true } label: { Image(systemName: "wand.and.stars") }
                    .buttonStyle(.borderless).help("Generate Password")
                    .popover(isPresented: $showGenerator) {
                        GeneratorPopover { c.login?.password = $0; showGenerator = false }.frame(width: 380)
                    }
            }
            if let pw = c.login?.password, !pw.isEmpty { StrengthMeter(password: pw) }
            TextField("Authenticator Key (TOTP)", text: b(\.login!.totp))
            if let t = c.login?.totp, !t.isEmpty, TOTP(t) == nil { Text("Invalid authenticator key").font(.caption).foregroundStyle(.red) }
            if let n = c.login?.fido2Credentials?.count, n > 0 {
                LabeledContent("Passkey", value: "Saved (\(n))")
            }
        }
        Section("Websites") {
            ForEach(Array((c.login?.uris ?? []).indices), id: \.self) { i in
                HStack {
                    TextField("Website", text: Binding(get: { c.login?.uris?[i].uri ?? "" }, set: { c.login?.uris?[i].uri = $0 }), prompt: Text("https://"))
                        .labelsHidden()
                    Picker("", selection: Binding(get: { c.login?.uris?[i].match }, set: { c.login?.uris?[i].match = $0 })) {
                        Text("Default").tag(UriMatch?.none)
                        ForEach(UriMatch.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    .labelsHidden().frame(width: 130)
                    Button { c.login?.uris?.remove(at: i) } label: { Image(systemName: "minus.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.red)
                }
            }
            Button("Add Website") { c.login?.uris = (c.login?.uris ?? []) + [LoginUri(uri: "")] }
        }
    }

    @ViewBuilder var cardSection: some View {
        Section("Card") {
            TextField("Cardholder Name", text: b(\.card!.cardholderName))
            TextField("Number", text: b(\.card!.number))
            Picker("Brand", selection: b(\.card!.brand)) {
                Text("—").tag("")
                ForEach(["Visa", "Mastercard", "Amex", "Discover", "Diners Club", "JCB", "Maestro", "UnionPay", "RuPay", "Other"], id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Picker("Expiration", selection: b(\.card!.expMonth)) {
                    Text("Month").tag("")
                    ForEach(1 ... 12, id: \.self) { Text(String(format: "%02d", $0)).tag(String($0)) }
                }
                TextField("Year", text: b(\.card!.expYear)).frame(width: 70)
            }
            SecureFieldToggle(title: "Security Code", text: b(\.card!.code))
        }
    }

    @ViewBuilder var identitySection: some View {
        Section("Personal") {
            Picker("Title", selection: b(\.identity!.title)) {
                Text("—").tag("")
                ForEach(["Mr", "Mrs", "Ms", "Mx", "Dr"], id: \.self) { Text($0).tag($0) }
            }
            TextField("First Name", text: b(\.identity!.firstName))
            TextField("Middle Name", text: b(\.identity!.middleName))
            TextField("Last Name", text: b(\.identity!.lastName))
            TextField("Username", text: b(\.identity!.username))
            TextField("Company", text: b(\.identity!.company))
        }
        Section("Identification") {
            TextField("Social Security Number", text: b(\.identity!.ssn))
            TextField("Passport Number", text: b(\.identity!.passportNumber))
            TextField("License Number", text: b(\.identity!.licenseNumber))
        }
        Section("Contact") {
            TextField("Email", text: b(\.identity!.email))
            TextField("Phone", text: b(\.identity!.phone))
            TextField("Address 1", text: b(\.identity!.address1))
            TextField("Address 2", text: b(\.identity!.address2))
            TextField("Address 3", text: b(\.identity!.address3))
            TextField("City / Town", text: b(\.identity!.city))
            TextField("State / Province", text: b(\.identity!.state))
            TextField("Zip / Postal Code", text: b(\.identity!.postalCode))
            TextField("Country", text: b(\.identity!.country))
        }
    }

    @ViewBuilder var sshSection: some View {
        Section("SSH Key") {
            TextField("Private Key", text: b(\.sshKey!.privateKey), axis: .vertical).font(.system(.caption, design: .monospaced)).lineLimit(3 ... 8)
            TextField("Public Key", text: b(\.sshKey!.publicKey), axis: .vertical).font(.system(.caption, design: .monospaced))
            TextField("Fingerprint", text: b(\.sshKey!.keyFingerprint))
            Button("Generate Ed25519 Key") { c.sshKey = SSHKeyGen.ed25519() }
        }
    }
}

struct SecureFieldToggle: View {
    let title: String
    @Binding var text: String
    @State private var shown = false
    var body: some View {
        HStack {
            if shown { TextField(title, text: $text).font(.system(.body, design: .monospaced)) } else { SecureField(title, text: $text) }
            Button { shown.toggle() } label: { Image(systemName: shown ? "eye.slash" : "eye") }.buttonStyle(.borderless)
        }
    }
}

struct StrengthMeter: View {
    let password: String
    var body: some View {
        let s = PasswordStrength.score(password)
        let colors: [Color] = [.red, .red, .orange, .green, .green]
        let labels = ["Very weak", "Weak", "Fair", "Good", "Strong"]
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0 ..< 5) { i in Capsule().fill(i <= s ? colors[s] : Color.secondary.opacity(0.2)).frame(height: 4) }
            }
            Text(labels[s]).font(.caption).foregroundStyle(colors[s]).frame(width: 64, alignment: .trailing)
        }
    }
}

extension Binding where Value == [Field]? {
    func unwrap() -> Binding<[Field]> {
        Binding<[Field]>(get: { wrappedValue ?? [] }, set: { wrappedValue = $0 })
    }
}

