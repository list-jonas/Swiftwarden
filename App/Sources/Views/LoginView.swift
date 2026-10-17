import SwiftUI
import SwiftwardenCore

enum ServerChoice: String, CaseIterable {
    case us, eu, selfHosted
    var label: String { ["us": "bitwarden.com", "eu": "bitwarden.eu", "selfHosted": "Self-hosted"][rawValue]! }
}

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.lastServer) private var server = ServerChoice.us.rawValue
    @AppStorage("selfHostedURL") private var selfURL = ""
    @State private var email = UserDefaults.standard.string(forKey: Prefs.lastEmail) ?? ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?
    @State private var twoFactor: (providers: [Int], info: [String: JSONValue])?
    @State private var provider = 0
    @State private var code = ""
    @State private var remember = true
    @State private var newDevice = false
    @State private var showAPIKey = false
    @State private var showRegister = false

    var env: ServerEnvironment {
        switch ServerChoice(rawValue: server) ?? .us {
        case .us: .us
        case .eu: .eu
        case .selfHosted: .selfHosted(selfURL)
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill").font(.system(size: 54)).foregroundStyle(.tint)
            Text(twoFactor != nil ? "Two-step login" : newDevice ? "Verify this device" : "Log in to Bitwarden").font(.title2.bold())
            Group {
                if twoFactor != nil { twoFactorForm } else if newDevice { newDeviceForm } else { credentialsForm }
            }
            .frame(width: 320)
            if let error { Text(error).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center).frame(width: 340) }
            if let info { Text(info).foregroundStyle(.secondary).font(.callout).multilineTextAlignment(.center).frame(width: 340) }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showAPIKey) { APIKeyLoginSheet(env: env) }
        .sheet(isPresented: $showRegister) { RegisterSheet(env: env) }
    }

    var credentialsForm: some View {
        VStack(spacing: 10) {
            Picker("Server", selection: $server) {
                ForEach(ServerChoice.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()
            if server == ServerChoice.selfHosted.rawValue {
                TextField("https://vault.example.com", text: $selfURL).textFieldStyle(.roundedBorder)
            }
            TextField("Email address", text: $email).textFieldStyle(.roundedBorder).textContentType(.username)
            SecureField("Master password", text: $password).textFieldStyle(.roundedBorder).textContentType(.password).onSubmit { submit() }
            Button(action: { submit() }) {
                HStack { if busy { ProgressView().controlSize(.small) }; Text("Log in") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(busy || email.isEmpty || password.isEmpty)
            HStack {
                Button("Get password hint") {
                    let api = model.makeAPI(env), e = email
                    Task {
                        do { try await VaultService.passwordHint(api: api, email: e); info = "If an account exists, a hint was emailed." } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(email.isEmpty)
                Spacer()
                Menu("More") {
                    Button("Log in with API key…") { showAPIKey = true }
                    Button("Create account…") { showRegister = true }
                }
                .fixedSize()
            }
            .buttonStyle(.link).font(.callout)
        }
    }

    var supported: [Int] { (twoFactor?.providers ?? []).filter { TwoFactorProvider(rawValue: $0)?.supported == true } }

    var twoFactorForm: some View {
        VStack(spacing: 10) {
            if supported.isEmpty {
                Text("This account only has two-step methods that need a browser (Duo or security key). Add an authenticator app or email method in the web vault, or log in with your API key.")
                    .font(.callout).multilineTextAlignment(.center)
                Button("Log in with API key…") { showAPIKey = true }
            } else {
                Picker("Method", selection: $provider) {
                    ForEach(supported, id: \.self) { Text(TwoFactorProvider(rawValue: $0)!.label).tag($0) }
                }
                if provider == 1 {
                    let addr = twoFactor?.info["1"].flatMap { if case let .object(o) = $0 { o["Email"]?.string ?? o["email"]?.string } else { nil } }
                    HStack {
                        Text("Code sent to \(addr ?? "your email")").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Resend") { sendEmail() }.buttonStyle(.link).font(.caption)
                    }
                }
                TextField(provider == 3 ? "Touch your YubiKey" : "Verification code", text: $code).textFieldStyle(.roundedBorder).onSubmit { submit() }
                Toggle("Remember me", isOn: $remember)
                Button(action: { submit() }) {
                    HStack { if busy { ProgressView().controlSize(.small) }; Text("Continue") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(code.isEmpty || busy)
            }
            Button("Back") { twoFactor = nil; code = ""; error = nil }.buttonStyle(.link)
        }
        .onChange(of: provider) { _, p in if p == 1 { sendEmail() } }
    }

    var newDeviceForm: some View {
        VStack(spacing: 10) {
            Text("Enter the code sent to \(email)").font(.callout).foregroundStyle(.secondary)
            TextField("Verification code", text: $code).textFieldStyle(.roundedBorder).onSubmit { submit() }
            Button(action: { submit() }) { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(code.isEmpty || busy)
            HStack {
                Button("Resend code") {
                    let api = model.makeAPI(env), e = email, p = password
                    Task {
                        if let pre = try? await api.prelogin(email: e) { try? await VaultService.resendNewDeviceOtp(api: api, email: e, password: p, kdf: pre.config) }
                    }
                }
                Spacer()
                Button("Back") { newDevice = false; code = "" }
            }
            .buttonStyle(.link)
        }
    }

    func sendEmail() {
        let api = model.makeAPI(env), e = email, p = password
        Task {
            do {
                let pre = try await api.prelogin(email: e)
                try await VaultService.sendEmailCode(api: api, email: e, password: p, kdf: pre.config)
                info = "Verification email sent."
            } catch { self.error = error.localizedDescription }
        }
    }

    func submit() {
        guard !busy else { return }
        busy = true; error = nil; info = nil
        let tf = twoFactor != nil ? (provider: provider, token: code.trimmingCharacters(in: .whitespaces), remember: remember) : nil
        let otp = newDevice ? code.trimmingCharacters(in: .whitespaces) : nil
        Task {
            defer { busy = false }
            do {
                try await model.login(env: env, email: email.trimmingCharacters(in: .whitespaces), password: password, twoFactor: tf, newDeviceOtp: otp)
                password = ""
            } catch let APIError.twoFactorRequired(p, i) {
                twoFactor = (p, i)
                code = ""
                provider = supported.first ?? 0
                if provider == 1 && supported.count == 1 { sendEmail() }
            } catch APIError.newDeviceVerification {
                newDevice = true
                code = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct APIKeyLoginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let env: ServerEnvironment
    @State private var id = ""
    @State private var secret = ""
    @State private var pw = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("client_id", text: $id)
                SecureField("client_secret", text: $secret)
                SecureField("Master password", text: $pw)
            } footer: {
                Text("Find your personal API key in the web vault under Account settings → Security → Keys.").font(.caption)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Log in") {
                    busy = true
                    Task {
                        do { try await model.loginWithAPIKey(env: env, clientId: id, clientSecret: secret, password: pw); dismiss() } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
                .disabled(id.isEmpty || secret.isEmpty || pw.isEmpty || busy)
            }
        }
    }
}

struct RegisterSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let env: ServerEnvironment
    @State private var email = ""
    @State private var name = ""
    @State private var pw = ""
    @State private var pw2 = ""
    @State private var hint = ""
    @State private var token = ""
    @State private var needsToken = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Create account on \(env.label)") {
                TextField("Email", text: $email)
                TextField("Name", text: $name)
                SecureField("Master password (min. 12 characters)", text: $pw)
                SecureField("Confirm master password", text: $pw2)
                TextField("Master password hint (optional)", text: $hint)
                if !pw.isEmpty { StrengthMeter(password: pw) }
            }
            if needsToken {
                Section("Email verification") {
                    TextField("Paste the link from the verification email", text: $token)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { create() }.disabled(email.isEmpty || pw.count < 12 || pw != pw2 || busy || (needsToken && token.isEmpty))
            }
        }
    }

    func create() {
        busy = true; error = nil
        let api = model.makeAPI(env)
        Task {
            defer { busy = false }
            do {
                var t: String? = token.isEmpty ? nil : token
                if t == nil {
                    t = try await VaultService.requestRegistration(api: api, email: email, name: name)
                    if t == nil { needsToken = true; error = "Check your inbox and paste the verification link."; return }
                }
                try await VaultService.register(api: api, email: email, name: name, password: pw, hint: hint, kdf: .pbkdf2Default, token: t)
                try await model.login(env: env, email: email, password: pw)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct UnlockView: View {
    @Environment(AppModel.self) private var model
    @State private var secret = ""
    @State private var usePIN = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 46)).foregroundStyle(.tint)
            Text("Your vault is locked").font(.title2.bold())
            Text("\(model.email) on \(model.account?.env.label ?? "")").foregroundStyle(.secondary).font(.callout)
            VStack(spacing: 10) {
                SecureField(usePIN ? "PIN" : "Master password", text: $secret).textFieldStyle(.roundedBorder).onSubmit(unlock)
                Button(action: unlock) {
                    HStack { if busy { ProgressView().controlSize(.small) }; Text("Unlock") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(secret.isEmpty || busy)
                if model.biometricEnabled {
                    Button { bio() } label: { Label("Unlock with Touch ID", systemImage: "touchid").frame(maxWidth: .infinity) }.controlSize(.large)
                }
                if model.pinEnabled {
                    Button(usePIN ? "Use master password" : "Use PIN") { usePIN.toggle(); secret = "" }.buttonStyle(.link)
                }
            }
            .frame(width: 300)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            Button("Log out") { model.logout() }.buttonStyle(.link).padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            usePIN = model.pinEnabled
            if model.biometricEnabled { bio() }
        }
    }

    func bio() { Task { _ = await model.unlockWithBiometrics() } }

    func unlock() {
        busy = true; error = nil
        Task {
            do {
                if usePIN { try await model.unlock(pin: secret) } else { try await model.unlock(password: secret) }
                secret = ""
            } catch {
                self.error = usePIN ? "Invalid PIN" : "Invalid master password"
            }
            busy = false
        }
    }
}
