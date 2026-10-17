import ServiceManagement
import SwiftUI
import SwiftwardenCore
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SecuritySettings().tabItem { Label("Security", systemImage: "lock") }
            AutofillSettings().tabItem { Label("Autofill", systemImage: "rectangle.and.pencil.and.ellipsis") }
            AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 520)
        .frame(minHeight: 420)
    }
}

struct GeneralSettings: View {
    @AppStorage(Prefs.showIcons) private var showIcons = true
    @AppStorage(Prefs.menuBarIcon) private var menuBar = true
    @AppStorage(Prefs.clearClipboard) private var clear = 30
    @AppStorage(Prefs.appearance) private var appearance = "system"
    @AppStorage(Prefs.defaultUriMatch) private var match = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { launchAtLogin = !on }
                }
            Toggle("Show menu bar icon", isOn: $menuBar)
            Toggle("Show website icons", isOn: $showIcons)
            Picker("Clear clipboard", selection: $clear) {
                Text("Never").tag(0)
                ForEach([10, 20, 30, 60, 120, 300], id: \.self) { Text($0 < 60 ? "\($0) seconds" : "\($0 / 60) minute\($0 > 60 ? "s" : "")").tag($0) }
            }
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
            .onChange(of: appearance) { _, v in applyAppearance(v) }
            Picker("Default URI match detection", selection: $match) {
                ForEach(UriMatch.allCases.filter { $0 != .never }, id: \.self) { Text($0.label).tag($0.rawValue) }
            }
        }
        .formStyle(.grouped)
    }
}

func applyAppearance(_ v: String) {
    NSApp.appearance = v == "light" ? NSAppearance(named: .aqua) : v == "dark" ? NSAppearance(named: .darkAqua) : nil
}

struct SecuritySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.timeoutMinutes) private var timeout = 15
    @AppStorage(Prefs.timeoutAction) private var action = "lock"
    @AppStorage(Prefs.lockOnSleep) private var onSleep = true
    @AppStorage(Prefs.lockOnScreenLock) private var onScreenLock = true
    @AppStorage(Prefs.biometricUnlock) private var bio = false
    @AppStorage(Prefs.pinRequireMasterOnRestart) private var pinRestart = false
    @State private var pinSheet = false
    @State private var pin = ""

    var body: some View {
        Form {
            Section("Vault timeout") {
                Picker("Lock after idle", selection: $timeout) {
                    ForEach([1, 5, 15, 30, 60, 240], id: \.self) { Text($0 < 60 ? "\($0) minute\($0 == 1 ? "" : "s")" : "\($0 / 60) hour\($0 > 60 ? "s" : "")").tag($0) }
                    Text("Never").tag(0)
                }
                Picker("Timeout action", selection: $action) { Text("Lock").tag("lock"); Text("Log out").tag("logout") }
                Toggle("Lock when Mac sleeps", isOn: $onSleep)
                Toggle("Lock when screen locks", isOn: $onScreenLock)
                Button("Lock Now") { model.lock() }.disabled(model.phase != .unlocked)
            }
            Section("Unlock options") {
                Toggle("Unlock with Touch ID", isOn: Binding(get: { model.biometricEnabled }, set: { on in
                    Task { if !(await model.setBiometric(on)) { bio = false } }
                }))
                .disabled(!Biometrics.available || model.phase != .unlocked)
                Toggle("Unlock with PIN", isOn: Binding(get: { model.pinEnabled }, set: { on in
                    if on { pin = ""; pinSheet = true } else { Task { try? await model.setPIN(nil, requireMasterOnRestart: false) } }
                }))
                .disabled(model.phase != .unlocked)
                if model.pinEnabled {
                    Text(pinRestart ? "Master password required after restart" : "PIN works after restart").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let fp = model.service?.fingerprintPhrase() {
                Section("Fingerprint phrase") {
                    Text(fp).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $pinSheet) {
            Form {
                Text("Set a PIN to unlock Swiftwarden. Your PIN settings reset if you log out.").font(.callout)
                SecureField("PIN", text: $pin)
                Toggle("Require master password on app restart", isOn: $pinRestart)
            }
            .formStyle(.grouped)
            .frame(width: 360)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pinSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set PIN") {
                        let p = pin, r = pinRestart
                        Task { try? await model.setPIN(p, requireMasterOnRestart: r); pinSheet = false }
                    }
                    .disabled(pin.count < 4)
                }
            }
        }
    }
}

struct AutofillSettings: View {
    @AppStorage(Prefs.autofillEnabled) private var enabled = true
    @AppStorage(Prefs.autofillSuggestions) private var suggestions = true
    @AppStorage(Prefs.fillMethod) private var method = "type"
    @AppStorage(Prefs.autoSubmit) private var submit = false
    @AppStorage(Prefs.copyTotpAfterFill) private var copyTotp = true
    @AppStorage(Prefs.hotkey) private var hotkey = "cmdShiftL"
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                LabeledContent("Accessibility access") {
                    if trusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") {
                            AutofillController.shared.requestPermission()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            } footer: {
                Text("Swiftwarden reads which field is focused in other apps to detect login forms. Nothing leaves your Mac.").font(.caption)
            }
            Toggle("Autofill in other apps", isOn: $enabled)
                .onChange(of: enabled) { AutofillController.shared.attach(NSWorkspace.shared.frontmostApplication) }
            Toggle("Suggest logins when a password field is focused", isOn: $suggestions).disabled(!enabled)
            Picker("Quick fill shortcut", selection: $hotkey) {
                Text("⇧⌘L").tag("cmdShiftL")
                Text("⌥⌘L").tag("optCmdL")
                Text("⌃⇧L").tag("ctrlShiftL")
                Text("⇧⌘\\").tag("cmdShiftBackslash")
                Text("None").tag("none")
            }
            .onChange(of: hotkey) { AutofillController.shared.registerHotKey() }
            Picker("Fill method", selection: $method) {
                Text("Type keystrokes").tag("type")
                Text("Set field value").tag("value")
                Text("Paste").tag("paste")
            }
            Toggle("Press Return after filling", isOn: $submit)
            Toggle("Copy verification code after filling", isOn: $copyTotp)
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in trusted = AXIsProcessTrusted() }
    }
}

struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var exportFormat = "json"
    @State private var exporting = false
    @State private var exportPassword = ""
    @State private var filePassword = ""
    @State private var importing = false
    @State private var importNeedsPassword: Data?
    @State private var importPassword = ""
    @State private var status: String?

    var body: some View {
        Form {
            if let a = model.account {
                Section("Account") {
                    LabeledContent("Email", value: a.email)
                    LabeledContent("Server", value: a.env.label)
                    if let d = a.lastSync { LabeledContent("Last sync", value: d.formatted()) }
                    HStack {
                        Button("Sync Now") { Task { await model.sync() } }.disabled(model.phase != .unlocked || model.syncing)
                        Spacer()
                        Button("Web Vault…") { NSWorkspace.shared.open(URL(string: a.env.webVaultURL)!) }
                        Button("Log Out", role: .destructive) { model.logout() }
                    }
                }
                Section {
                    Picker("Format", selection: $exportFormat) {
                        Text(".json").tag("json"); Text(".csv").tag("csv"); Text(".json (password protected)").tag("encrypted")
                    }
                    if exportFormat == "encrypted" { SecureField("File password", text: $filePassword) }
                    Button("Export Vault…") { exportPassword = ""; exporting = true }
                        .disabled(model.phase != .unlocked || (exportFormat == "encrypted" && filePassword.count < 8))
                } header: { Text("Export") } footer: {
                    Text("Unencrypted exports contain your passwords in plain text.").font(.caption)
                }
                Section("Import") {
                    Button("Import from File…") { importing = true }.disabled(model.phase != .unlocked)
                    Text("Bitwarden (.json, .csv, password-protected .json), Chrome, Edge, Firefox, Safari, 1Password and other CSV exports.").font(.caption).foregroundStyle(.secondary)
                    if let status { Text(status).font(.caption) }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $exporting) { exportSheet }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .commaSeparatedText, .plainText, .data]) { r in
            guard let u = try? r.get() else { return }
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            guard let d = try? Data(contentsOf: u) else { return }
            if Importer.needsPassword(d) { importPassword = ""; importNeedsPassword = d } else { runImport(d, nil) }
        }
        .alert("File password", isPresented: Binding(get: { importNeedsPassword != nil }, set: { if !$0 { importNeedsPassword = nil } })) {
            SecureField("Password", text: $importPassword)
            Button("Import") { if let d = importNeedsPassword { runImport(d, importPassword) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    var exportSheet: some View {
        VStack(spacing: 12) {
            Text("Confirm vault export").font(.headline)
            SecureField("Master password", text: $exportPassword).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { exporting = false }
                Spacer()
                Button("Export") {
                    Task {
                        guard await model.verifyMasterPassword(exportPassword) else { status = "Invalid master password"; exporting = false; return }
                        exporting = false
                        doExport()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 320)
    }

    func doExport() {
        let personal = model.ciphers.filter { $0.organizationId == nil }
        let stamp = Date().formatted(.iso8601.year().month().day())
        do {
            let data: Data
            var name = "bitwarden_export_\(stamp)"
            switch exportFormat {
            case "csv": data = Data(Exporter.csv(ciphers: personal, folders: model.folders).utf8); name += ".csv"
            case "encrypted": data = try Exporter.encryptedJSON(ciphers: personal, folders: model.folders, password: filePassword); name += "_encrypted.json"
            default: data = try Exporter.json(ciphers: personal, folders: model.folders); name += ".json"
            }
            revealInFinderSave(data, name: name)
        } catch { status = error.localizedDescription }
    }

    func runImport(_ d: Data, _ pw: String?) {
        Task {
            do {
                let r = try Importer.detect(d, password: pw)
                try await model.service?.importVault(ciphers: r.ciphers, folders: r.folders, relations: r.relations)
                status = "Imported \(r.ciphers.count) items."
                await model.sync()
            } catch { status = "Import failed: \(error.localizedDescription)" }
        }
    }
}
