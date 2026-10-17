import AppKit
import SwiftUI
import SwiftwardenCore

enum Phase { case loggedOut, locked, unlocked }

enum SidebarItem: Hashable {
    case all, favorites, codes, passkeys, security, trash
    case type(CipherType)
    case folder(String?)
    case collection(String)
    case organization(String)
    case personal
    case sends, generator

    var title: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .codes: "Codes"
        case .passkeys: "Passkeys"
        case .security: "Security"
        case .trash: "Deleted"
        case let .type(t): ["Logins", "Secure Notes", "Cards", "Identities", "SSH Keys"][t.rawValue - 1]
        case .folder: "Folder"
        case .collection: "Collection"
        case .organization: "Organization"
        case .personal: "My Vault"
        case .sends: "Send"
        case .generator: "Generator"
        }
    }
}

enum SortOrder: String, CaseIterable {
    case name, modified, created
    var label: String { ["name": "Name", "modified": "Date Modified", "created": "Date Created"][rawValue]! }
}

struct HealthReport {
    var weak: Set<String> = []
    var reused: [String: Int] = [:]
    var exposed: [String: Int] = [:]
    var unsecured: Set<String> = []
    var exposedChecked = false

    func flagged(_ id: String) -> Bool { weak.contains(id) || reused[id] != nil || exposed[id] != nil || unsecured.contains(id) }
    var flaggedCount: Int { Set(weak).union(reused.keys).union(exposed.keys).union(unsecured).count }
}

struct Toast: Equatable { var text: String; var id = UUID() }

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var phase: Phase = .loggedOut {
        didSet { if oldValue != phase { DispatchQueue.main.async { AutofillController.shared.focusChanged() } } }
    }
    var account: StoredAccount?
    @ObservationIgnored var service: VaultService?

    var ciphers: [Cipher] = []
    var folders: [Folder] = []
    var collections: [Collection] = []
    var organizations: [ProfileOrganization] = []
    var sends: [Send] = []
    var profile: Profile?
    var policies: [Policy] = []
    var health = HealthReport()
    @ObservationIgnored var searchIndex: [String: String] = [:]

    var syncing = false
    var errorMessage: String?
    var toast: Toast?

    var sidebar: SidebarItem? = .all
    var selectedId: String?
    var selectedSendId: String?
    var draft: Cipher?
    var search = ""
    var sort = SortOrder(rawValue: UserDefaults.standard.string(forKey: "sortOrder") ?? "name") ?? .name {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "sortOrder") }
    }
    var repromptPassed: Set<String> = []
    var pendingReprompt: PendingReprompt?
    var generatorHistory: [PasswordHistory] = []

    @ObservationIgnored let deviceId = Store.deviceId
    @ObservationIgnored private var pinEphemeralKey: Data?
    @ObservationIgnored private var clipboardTask: Task<Void, Never>?
    @ObservationIgnored private var timers: [Timer] = []

    init() {
        Prefs.register()
        account = Store.loadAccount()
        phase = account == nil ? .loggedOut : .locked
        startTimers()
    }

    var email: String { account?.email ?? "" }
    var biometricEnabled: Bool { Prefs.d.bool(forKey: Prefs.biometricUnlock) && account.map { Keychain.get("bio.\($0.userId)") != nil } == true }
    var pinEnabled: Bool { account?.pinProtectedUserKey != nil || pinEphemeralKey != nil }

    // MARK: Login

    func makeAPI(_ env: ServerEnvironment) -> APIClient {
        let api = APIClient(env: env, deviceId: deviceId)
        return api
    }

    func login(env: ServerEnvironment, email: String, password: String, twoFactor: (provider: Int, token: String, remember: Bool)? = nil,
               newDeviceOtp: String? = nil) async throws {
        let api = makeAPI(env)
        let pre = try await api.prelogin(email: email)
        var tf = twoFactor
        let rememberKey = "2fa.\(env.label).\(email.lowercased())"
        if tf == nil, let r = Keychain.get(rememberKey).flatMap({ String(data: $0, encoding: .utf8) }) { tf = (5, r, false) }
        let secrets: LoginSecrets
        do {
            secrets = try await Task.detached { try await VaultService.login(api: api, email: email, password: password, kdf: pre.config, twoFactor: tf, newDeviceOtp: newDeviceOtp) }.value
        } catch APIError.twoFactorRequired(let p, let i) where tf?.provider == 5 {
            Keychain.delete(rememberKey)
            throw APIError.twoFactorRequired(providers: p, info: i)
        }
        if let r = secrets.twoFactorRememberToken { Keychain.set(Data(r.utf8), for: rememberKey) }
        Prefs.d.set(email, forKey: Prefs.lastEmail)
        let svc = VaultService(api: api, keys: KeyRing(userKey: secrets.userKey))
        let data = try await svc.fetchSync()
        let profile = try JSON.decoder.decode(SyncResponse.self, from: data).profile
        account = StoredAccount(userId: profile.id, email: profile.email, name: profile.name, env: env, kdf: secrets.kdf,
                                protectedUserKey: secrets.protectedUserKey, encryptedPrivateKey: secrets.encryptedPrivateKey)
        Store.save(account)
        persistTokens(api.tokens)
        wire(api)
        service = svc
        try? data.write(to: Paths.syncCache, options: .atomic)
        await apply(data)
        account?.lastSync = Date()
        Store.save(account)
        phase = .unlocked
    }

    func loginWithAPIKey(env: ServerEnvironment, clientId: String, clientSecret: String, password: String) async throws {
        let api = makeAPI(env)
        let t = try await VaultService.loginAPIKey(api: api, clientId: clientId, clientSecret: clientSecret)
        guard let pk = t.key, let kdfType = t.kdf, let iters = t.kdfIterations else { throw APIError.invalidResponse }
        let svcTmp = VaultService(api: api, keys: KeyRing(userKey: .generate()))
        let data = try await svcTmp.fetchSync()
        let profile = try JSON.decoder.decode(SyncResponse.self, from: data).profile
        let kdf = KdfConfig(type: kdfType, iterations: iters, memory: t.kdfMemory, parallelism: t.kdfParallelism)
        let email = profile.email
        let uk = try await Task.detached { try VaultService.unlock(password: password, email: email, kdf: kdf, protectedUserKey: pk) }.value
        account = StoredAccount(userId: profile.id, email: email, name: profile.name, env: env, kdf: kdf, protectedUserKey: pk,
                                encryptedPrivateKey: t.privateKey)
        Store.save(account)
        persistTokens(api.tokens)
        wire(api)
        service = VaultService(api: api, keys: KeyRing(userKey: uk))
        try? data.write(to: Paths.syncCache, options: .atomic)
        await apply(data)
        phase = .unlocked
    }

    private func wire(_ api: APIClient) {
        let uid = account?.userId ?? ""
        api.onTokensChanged = { t in
            if let t { Keychain.setCodable(t, for: "tokens.\(uid)") }
        }
    }

    private func persistTokens(_ t: Tokens?) {
        guard let uid = account?.userId, let t else { return }
        Keychain.setCodable(t, for: "tokens.\(uid)")
    }

    // MARK: Lock / unlock

    func unlock(password: String) async throws {
        guard let a = account else { return }
        let uk = try await Task.detached { try VaultService.unlock(password: password, email: a.email, kdf: a.kdf, protectedUserKey: a.protectedUserKey) }.value
        await didUnlock(uk)
    }

    func unlockWithBiometrics() async -> Bool {
        guard let a = account, Prefs.d.bool(forKey: Prefs.biometricUnlock) else { return false }
        guard await Biometrics.authenticate("unlock your vault") else { return false }
        guard let raw = Keychain.get("bio.\(a.userId)"), let uk = try? SymmetricCryptoKey(raw) else { return false }
        await didUnlock(uk)
        return true
    }

    func unlock(pin: String) async throws {
        guard let a = account else { return }
        let prot: String
        if let p = a.pinProtectedUserKey { prot = p }
        else if let e = pinEphemeralKey, let s = String(data: e, encoding: .utf8) { prot = s }
        else { throw CryptoError.invalidKey }
        let uk = try await Task.detached { () throws -> SymmetricCryptoKey in
            let key = try KeyDerivation.deriveKey(secret: pin, salt: a.email.lowercased(), kdf: a.kdf)
            return try KeyDerivation.decryptUserKey(prot, with: key)
        }.value
        await didUnlock(uk)
    }

    func verifyMasterPassword(_ password: String) async -> Bool {
        guard let a = account else { return false }
        return (try? await Task.detached { try VaultService.unlock(password: password, email: a.email, kdf: a.kdf, protectedUserKey: a.protectedUserKey) }.value) != nil
    }

    private func didUnlock(_ uk: SymmetricCryptoKey) async {
        guard let a = account else { return }
        let api = makeAPI(a.env)
        api.tokens = Keychain.getCodable(Tokens.self, "tokens.\(a.userId)")
        wire(api)
        let svc = VaultService(api: api, keys: KeyRing(userKey: uk))
        service = svc
        if let cached = try? Data(contentsOf: Paths.syncCache) { await apply(cached) }
        phase = .unlocked
        loadGeneratorHistory()
        Task { await sync() }
    }

    func lock() {
        guard phase == .unlocked else { return }
        if Prefs.d.string(forKey: Prefs.timeoutAction) == "logout" { logout(); return }
        clearVault()
        phase = .locked
    }

    private func clearVault() {
        service = nil
        ciphers = []; folders = []; collections = []; organizations = []; sends = []; profile = nil
        searchIndex = [:]; health = HealthReport(); draft = nil; selectedId = nil; repromptPassed = []
        generatorHistory = []
    }

    func logout() {
        if let a = account {
            Keychain.delete("tokens.\(a.userId)")
            Keychain.delete("bio.\(a.userId)")
        }
        try? FileManager.default.removeItem(at: Paths.syncCache)
        try? FileManager.default.removeItem(at: Paths.generatorHistory)
        clearVault()
        pinEphemeralKey = nil
        account = nil
        Store.save(nil)
        phase = .loggedOut
    }

    func setBiometric(_ on: Bool) async -> Bool {
        guard let a = account, let uk = service?.keys.userKey else { return false }
        if on {
            guard await Biometrics.authenticate("enable unlock with Touch ID") else { return false }
            Keychain.set(uk.data, for: "bio.\(a.userId)")
        } else {
            Keychain.delete("bio.\(a.userId)")
        }
        Prefs.d.set(on, forKey: Prefs.biometricUnlock)
        return true
    }

    func setPIN(_ pin: String?, requireMasterOnRestart: Bool) async throws {
        guard var a = account else { return }
        guard let pin, !pin.isEmpty else {
            a.pinProtectedUserKey = nil; pinEphemeralKey = nil
            account = a; Store.save(a); return
        }
        guard let uk = service?.keys.userKey else { return }
        let email = a.email, kdf = a.kdf
        let prot = try await Task.detached { () throws -> String in
            let key = try KeyDerivation.deriveKey(secret: pin, salt: email.lowercased(), kdf: kdf)
            return try KeyDerivation.protectUserKey(uk, with: key)
        }.value
        if requireMasterOnRestart {
            pinEphemeralKey = Data(prot.utf8); a.pinProtectedUserKey = nil
        } else {
            a.pinProtectedUserKey = prot; pinEphemeralKey = nil
        }
        Prefs.d.set(requireMasterOnRestart, forKey: Prefs.pinRequireMasterOnRestart)
        account = a
        Store.save(a)
    }

    // MARK: Sync

    func sync() async {
        guard let svc = service, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let data = try await svc.fetchSync()
            try? data.write(to: Paths.syncCache, options: .atomic)
            await apply(data)
            account?.lastSync = Date()
            if let p = profile, let k = p.key, account?.protectedUserKey != k { account?.protectedUserKey = k }
            Store.save(account)
            errorMessage = nil
        } catch APIError.unauthorized {
            errorMessage = "Session expired. Log out and log in again to sync."
        } catch {
            errorMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    func apply(_ data: Data) async {
        guard let svc = service else { return }
        guard let v = try? await Task.detached(priority: .userInitiated, operation: { try svc.decryptVault(data) }).value else { return }
        guard service === svc else { return }
        profile = v.profile
        ciphers = v.ciphers
        folders = v.folders
        collections = v.collections
        organizations = v.organizations.filter { $0.enabled ?? true }
        sends = v.sends
        policies = v.policies
        rebuildIndex()
        computeHealth()
    }

    private func rebuildIndex() {
        var idx: [String: String] = [:]
        idx.reserveCapacity(ciphers.count)
        for c in ciphers {
            var parts = [c.name ?? "", c.subtitle, c.login?.username ?? "", c.card?.brand ?? "", c.identity?.email ?? ""]
            parts += (c.login?.uris ?? []).compactMap(\.uri)
            idx[c.id] = parts.joined(separator: " ").lowercased()
        }
        searchIndex = idx
    }

    func computeHealth() {
        let items = ciphers.filter { !$0.isDeleted && $0.type == .login && $0.canViewPassword }
        let prevExposed = health.exposed, checked = health.exposedChecked
        Task.detached(priority: .utility) {
            var h = HealthReport()
            var byPw: [String: [String]] = [:]
            for c in items {
                if let u = c.login?.uris, u.contains(where: { ($0.uri ?? "").lowercased().hasPrefix("http://") }) { h.unsecured.insert(c.id) }
                guard let pw = c.login?.password, !pw.isEmpty else { continue }
                byPw[pw, default: []].append(c.id)
                let inputs = [c.login?.username ?? "", c.name ?? ""].flatMap { $0.split(whereSeparator: { !$0.isLetter }).map(String.init) }
                if PasswordStrength.isWeak(pw, userInputs: inputs) { h.weak.insert(c.id) }
            }
            for (_, ids) in byPw where ids.count > 1 { for id in ids { h.reused[id] = ids.count } }
            h.exposed = prevExposed
            h.exposedChecked = checked
            let result = h
            await MainActor.run { AppModel.shared.health = result }
        }
    }

    func checkExposed() async {
        let items = ciphers.filter { !$0.isDeleted && $0.type == .login && !($0.login?.password ?? "").isEmpty }
        var cache: [String: Int] = [:]
        var result: [String: Int] = [:]
        for c in items {
            let pw = c.login!.password!
            if let n = cache[pw] { if n > 0 { result[c.id] = n }; continue }
            let hash = Primitives.sha1(Data(pw.utf8)).hex.uppercased()
            let prefix = String(hash.prefix(5)), suffix = hash.dropFirst(5)
            guard let url = URL(string: "https://api.pwnedpasswords.com/range/\(prefix)"),
                  let (d, _) = try? await URLSession.shared.data(from: url), let body = String(data: d, encoding: .utf8) else { continue }
            var n = 0
            for line in body.split(whereSeparator: \.isNewline) where line.hasPrefix(suffix) {
                n = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            }
            cache[pw] = n
            if n > 0 { result[c.id] = n }
        }
        health.exposed = result
        health.exposedChecked = true
    }

    // MARK: Queries

    func items(for s: SidebarItem?, query: String? = nil, sorted: Bool = true) -> [Cipher] {
        let q = (query ?? search).trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Cipher]
        switch s ?? .all {
        case .trash: out = ciphers.filter(\.isDeleted)
        case let x:
            out = ciphers.filter { c in
                guard !c.isDeleted else { return false }
                switch x {
                case .favorites: return c.isFavorite
                case .codes: return c.hasTotp
                case .passkeys: return c.hasPasskey
                case .security: return health.flagged(c.id)
                case let .type(t): return c.type == t
                case let .folder(id): return c.folderId == id
                case let .collection(id): return c.collectionIds?.contains(id) ?? false
                case let .organization(id): return c.organizationId == id
                case .personal: return c.organizationId == nil
                default: return true
                }
            }
        }
        if !q.isEmpty {
            let terms = q.split(separator: " ")
            out = out.filter { c in let s = searchIndex[c.id] ?? ""; return terms.allSatisfy { s.contains($0) } }
        }
        guard sorted else { return out }
        switch sort {
        case .name: out.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .modified: out.sort { ($0.revisionDate ?? "") > ($1.revisionDate ?? "") }
        case .created: out.sort { ($0.creationDate ?? "") > ($1.creationDate ?? "") }
        }
        return out
    }

    func count(_ s: SidebarItem) -> Int { items(for: s, query: "", sorted: false).count }

    func cipher(_ id: String?) -> Cipher? { id.flatMap { i in ciphers.first { $0.id == i } } }
    func folderName(_ id: String?) -> String? { id.flatMap { i in folders.first { $0.id == i }?.name } }
    func orgName(_ id: String?) -> String? { id.flatMap { i in organizations.first { $0.id == i }?.name } }
    func collectionNames(_ ids: [String]?) -> [String] { (ids ?? []).compactMap { i in collections.first { $0.id == i }?.name } }
    func writableCollections(_ org: String) -> [Collection] { collections.filter { $0.organizationId == org && !($0.readOnly ?? false) } }

    func matches(url: String) -> [Cipher] {
        let def = UriMatch(rawValue: Prefs.d.integer(forKey: Prefs.defaultUriMatch)) ?? .domain
        return ciphers.filter { c in
            !c.isDeleted && c.type == .login && (c.login?.uris ?? []).contains { URLMatcher.matches($0, url: url, defaultMatch: def) }
        }
    }

    func matches(bundleId: String, appName: String) -> [Cipher] {
        ciphers.filter { c in
            !c.isDeleted && c.type == .login && (c.login?.uris ?? []).contains { URLMatcher.matchesApp($0, bundleId: bundleId, appName: appName) }
        }
    }

    // MARK: Mutations

    func run(_ label: String, _ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch { errorMessage = "\(label) failed: \(error.localizedDescription)" }
        }
    }

    func save(_ c: Cipher, collectionIds: [String] = []) async throws -> Cipher {
        guard let svc = service else { throw APIError.unauthorized }
        var x = c
        x.recordHistory(from: cipher(c.id))
        let saved = try await svc.save(x, collectionIds: collectionIds)
        upsert(saved)
        return saved
    }

    func upsert(_ c: Cipher) {
        if let i = ciphers.firstIndex(where: { $0.id == c.id }) { ciphers[i] = c } else { ciphers.append(c) }
        rebuildIndex()
        computeHealth()
    }

    func toggleFavorite(_ c: Cipher) {
        run("Update") { [self] in
            try await service?.partial(c.id, folderId: c.folderId, favorite: !c.isFavorite)
            var x = c; x.favorite = !c.isFavorite; upsert(x)
        }
    }

    func move(_ c: Cipher, toFolder f: String?) {
        run("Move") { [self] in
            try await service?.partial(c.id, folderId: f, favorite: c.isFavorite)
            var x = c; x.folderId = f; upsert(x)
        }
    }

    func trash(_ c: Cipher) {
        run("Delete") { [self] in
            if c.isDeleted {
                try await service?.deletePermanently(c.id)
                ciphers.removeAll { $0.id == c.id }
            } else {
                try await service?.trash(c.id)
                var x = c; x.deletedDate = Dates.string(Date()); upsert(x)
            }
            if selectedId == c.id { selectedId = nil }
        }
    }

    func restore(_ c: Cipher) {
        run("Restore") { [self] in
            try await service?.restore(c.id)
            var x = c; x.deletedDate = nil; upsert(x)
        }
    }

    func emptyTrash() {
        run("Empty trash") { [self] in
            for c in ciphers where c.isDeleted { try await service?.deletePermanently(c.id) }
            ciphers.removeAll(where: \.isDeleted)
        }
    }

    // MARK: Clipboard

    func copy(_ s: String?, _ label: String, sensitive: Bool = true, toast: Bool = true) {
        guard let s, !s.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        if sensitive { pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
        if toast { showToast("Copied \(label)") }
        let secs = Prefs.d.integer(forKey: Prefs.clearClipboard)
        clipboardTask?.cancel()
        guard sensitive, secs > 0 else { return }
        let change = pb.changeCount
        clipboardTask = Task {
            try? await Task.sleep(for: .seconds(secs))
            guard !Task.isCancelled, pb.changeCount == change else { return }
            pb.clearContents()
        }
    }

    func showToast(_ s: String) {
        let t = Toast(text: s)
        toast = t
        Task { try? await Task.sleep(for: .seconds(1.6)); if toast == t { toast = nil } }
    }

    // MARK: Generator history

    func recordGenerated(_ s: String) {
        generatorHistory.insert(PasswordHistory(password: s, lastUsedDate: Dates.string(Date())), at: 0)
        generatorHistory = Array(generatorHistory.prefix(100))
        guard let k = service?.keys.userKey, let d = try? JSONEncoder().encode(generatorHistory),
              let e = try? EncString.encrypt(d, key: k) else { return }
        try? Data(e.description.utf8).write(to: Paths.generatorHistory, options: .atomic)
    }

    func clearGeneratorHistory() {
        generatorHistory = []
        try? FileManager.default.removeItem(at: Paths.generatorHistory)
    }

    private func loadGeneratorHistory() {
        guard let k = service?.keys.userKey, let s = try? String(contentsOf: Paths.generatorHistory, encoding: .utf8),
              let d = try? EncString(s).decrypt(key: k), let h = try? JSONDecoder().decode([PasswordHistory].self, from: d) else { return }
        generatorHistory = h
    }

    // MARK: Auto-lock

    private func startTimers() {
        let t = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.checkIdle() }
        }
        let s = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated { _ = Task { await AppModel.shared.sync() } }
        }
        timers = [t, s]
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if Prefs.d.bool(forKey: Prefs.lockOnSleep) { AppModel.shared.lock() } }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if Prefs.d.bool(forKey: Prefs.lockOnScreenLock) { AppModel.shared.lock() } }
        }
    }

    private func checkIdle() {
        guard phase == .unlocked else { return }
        let mins = Prefs.d.integer(forKey: Prefs.timeoutMinutes)
        guard mins > 0 else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= Double(mins * 60) { lock() }
    }
}






