import SwiftUI
import SwiftwardenCore

struct GeneratorModel {
    var type = Prefs.d.string(forKey: Prefs.generatorType) ?? "password"
    var pw: PasswordOptions = Prefs.codable(Prefs.passwordOptions, default: PasswordOptions())
    var pp: PassphraseOptions = Prefs.codable(Prefs.passphraseOptions, default: PassphraseOptions())
    var userType = Prefs.d.string(forKey: Prefs.usernameType) ?? "word"
    var email = Prefs.d.string(forKey: Prefs.usernameEmail) ?? ""
    var domain = Prefs.d.string(forKey: Prefs.usernameDomain) ?? ""
    var wordCap = false
    var wordNum = false
    var forwarder: Forwarder = .addy
    var forwarderKey = ""
    var forwarderDomain = ""

    func persist() {
        Prefs.d.set(type, forKey: Prefs.generatorType)
        Prefs.setCodable(Prefs.passwordOptions, pw)
        Prefs.setCodable(Prefs.passphraseOptions, pp)
        Prefs.d.set(userType, forKey: Prefs.usernameType)
        Prefs.d.set(email, forKey: Prefs.usernameEmail)
        Prefs.d.set(domain, forKey: Prefs.usernameDomain)
    }

    func generate() -> String {
        switch type {
        case "passphrase": return Generator.passphrase(pp)
        case "username":
            switch userType {
            case "plus": return email.contains("@") ? Generator.plusAddressed(email) : ""
            case "catchall": return domain.isEmpty ? "" : Generator.catchAll(domain)
            case "forwarded": return ""
            default: return Generator.randomWord(capitalize: wordCap, includeNumber: wordNum)
            }
        default: return Generator.password(pw)
        }
    }
}

struct GeneratorOptions: View {
    @Binding var g: GeneratorModel
    var allowUsername = true

    var body: some View {
        Picker("Type", selection: $g.type) {
            Text("Password").tag("password")
            Text("Passphrase").tag("passphrase")
            if allowUsername { Text("Username").tag("username") }
        }
        .pickerStyle(.segmented)
        switch g.type {
        case "passphrase":
            Stepper("Words: \(g.pp.words)", value: $g.pp.words, in: 3 ... 20)
            TextField("Separator", text: $g.pp.separator)
            Toggle("Capitalize", isOn: $g.pp.capitalize)
            Toggle("Include number", isOn: $g.pp.includeNumber)
        case "username":
            Picker("Kind", selection: $g.userType) {
                Text("Random word").tag("word")
                Text("Plus addressed email").tag("plus")
                Text("Catch-all email").tag("catchall")
                Text("Forwarded email alias").tag("forwarded")
            }
            switch g.userType {
            case "plus": TextField("Email", text: $g.email)
            case "catchall": TextField("Domain", text: $g.domain)
            case "forwarded":
                Picker("Service", selection: $g.forwarder) { ForEach(Forwarder.allCases, id: \.self) { Text($0.label).tag($0) } }
                SecureField("API key", text: $g.forwarderKey)
                if g.forwarder.needsDomain { TextField("Domain", text: $g.forwarderDomain) }
            default:
                Toggle("Capitalize", isOn: $g.wordCap)
                Toggle("Include number", isOn: $g.wordNum)
            }
        default:
            HStack {
                Text("Length")
                Slider(value: Binding(get: { Double(g.pw.length) }, set: { g.pw.length = Int($0) }), in: 5 ... 128, step: 1)
                Text("\(g.pw.length)").monospacedDigit().frame(width: 32)
            }
            Toggle("A-Z", isOn: $g.pw.uppercase)
            Toggle("a-z", isOn: $g.pw.lowercase)
            Toggle("0-9", isOn: $g.pw.numbers)
            Toggle("!@#$%^&*", isOn: $g.pw.special)
            Stepper("Minimum numbers: \(g.pw.minNumbers)", value: $g.pw.minNumbers, in: 0 ... 9)
            Stepper("Minimum special: \(g.pw.minSpecial)", value: $g.pw.minSpecial, in: 0 ... 9)
            Toggle("Avoid ambiguous characters", isOn: $g.pw.avoidAmbiguous)
        }
    }
}

struct GeneratorView: View {
    @Environment(AppModel.self) private var model
    @State private var g = GeneratorModel()
    @State private var value = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    Text(colored(value)).font(.system(size: 17, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if busy { ProgressView().controlSize(.small) }
                    Button { regenerate() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Regenerate")
                    Button { model.copy(value, "value"); model.recordGenerated(value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
                }
                .padding(.vertical, 6)
                if g.type != "username" { StrengthMeter(password: value) }
            }
            Section("Options") { GeneratorOptions(g: $g) }
        }
        .formStyle(.grouped)
        .navigationTitle("Generator")
        .onAppear(perform: regenerate)
        .onChange(of: g.type) { regenerate() }
        .onChange(of: g.pw) { regenerate() }
        .onChange(of: g.pp) { regenerate() }
        .onChange(of: g.userType) { regenerate() }
        .onChange(of: g.wordCap) { regenerate() }
        .onChange(of: g.wordNum) { regenerate() }
    }

    func regenerate() {
        g.persist()
        if g.type == "username" && g.userType == "forwarded" {
            guard !g.forwarderKey.isEmpty else { value = "Enter an API key"; return }
            busy = true
            Task {
                do { value = try await g.forwarder.generate(apiKey: g.forwarderKey, domain: g.forwarderDomain, website: nil) } catch { value = error.localizedDescription }
                busy = false
            }
            return
        }
        value = g.generate()
    }

    func colored(_ s: String) -> AttributedString {
        var a = AttributedString()
        for ch in s {
            var part = AttributedString(String(ch))
            if ch.isNumber { part.foregroundColor = .blue } else if !ch.isLetter { part.foregroundColor = .red }
            a += part
        }
        return a
    }
}

struct GeneratorPopover: View {
    @Environment(AppModel.self) private var model
    let onUse: (String) -> Void
    @State private var g = GeneratorModel()
    @State private var value = ""

    var body: some View {
        Form {
            HStack {
                Text(value).font(.system(.body, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button { value = g.generate() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            GeneratorOptions(g: $g, allowUsername: false)
            Button("Use This Password") { model.recordGenerated(value); onUse(value) }.buttonStyle(.borderedProminent)
        }
        .formStyle(.grouped)
        .onAppear { if g.type == "username" { g.type = "password" }; value = g.generate() }
        .onChange(of: g.pw) { value = g.generate(); g.persist() }
        .onChange(of: g.pp) { value = g.generate(); g.persist() }
        .onChange(of: g.type) { value = g.generate(); g.persist() }
    }
}

struct GeneratorHistoryView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            if model.generatorHistory.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock", description: Text("Copied values appear here."))
            } else {
                PasswordHistoryList(entries: model.generatorHistory)
            }
        }
        .navigationTitle("History")
        .toolbar { Button("Clear") { model.clearGeneratorHistory() }.disabled(model.generatorHistory.isEmpty) }
    }
}
