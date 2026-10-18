import Foundation
import Security

public struct KeyRing: @unchecked Sendable {
    public var userKey: SymmetricCryptoKey
    public var privateKey: SecKey?
    public var orgKeys: [String: SymmetricCryptoKey] = [:]

    public init(userKey: SymmetricCryptoKey) { self.userKey = userKey }

    public func key(for orgId: String?) -> SymmetricCryptoKey? {
        guard let orgId else { return userKey }
        return orgKeys[orgId]
    }
}

public struct CipherRequest: Encodable {
    var type: Int
    var organizationId, folderId, name, notes, key: String?
    var favorite: Bool
    var reprompt: Int
    var login: Login?
    var card: Card?
    var identity: Identity?
    var secureNote: SecureNote?
    var sshKey: SSHKeyData?
    var fields: [Field]?
    var passwordHistory: [PasswordHistory]?
    var lastKnownRevisionDate: String?
    var encryptedFor: String?

    init(_ c: Cipher, userId: String? = nil) {
        encryptedFor = userId
        type = c.type.rawValue
        organizationId = c.organizationId; folderId = c.folderId; name = c.name; notes = c.notes; key = c.key
        favorite = c.favorite ?? false; reprompt = c.reprompt ?? 0
        login = c.type == .login ? c.login : nil
        card = c.type == .card ? c.card : nil
        identity = c.type == .identity ? c.identity : nil
        secureNote = c.type == .secureNote ? (c.secureNote ?? SecureNote()) : nil
        sshKey = c.type == .sshKey ? c.sshKey : nil
        fields = c.fields; passwordHistory = c.passwordHistory
        lastKnownRevisionDate = c.revisionDate
    }
}

struct SendRequest: Encodable {
    var type: Int
    var name, notes, key, password, expirationDate, deletionDate: String?
    var maxAccessCount: Int?
    var text: SendText?
    var file: SendFile?
    var disabled: Bool
    var hideEmail: Bool?
    var fileLength: Int?

    init(_ s: Send) {
        type = s.type; name = s.name; notes = s.notes; key = s.key; password = s.password
        expirationDate = s.expirationDate; deletionDate = s.deletionDate; maxAccessCount = s.maxAccessCount
        text = s.type == 0 ? s.text : nil
        file = s.type == 1 ? SendFile(fileName: s.file?.fileName) : nil
        disabled = s.disabled; hideEmail = s.hideEmail; fileLength = s.fileLength
    }
}

public struct DecryptedVault: Sendable {
    public var profile: Profile
    public var ciphers: [Cipher]
    public var folders: [Folder]
    public var collections: [Collection]
    public var sends: [Send]
    public var organizations: [ProfileOrganization]
    public var policies: [Policy]
}

public struct LoginSecrets: Sendable {
    public var tokens: Tokens
    public var protectedUserKey: String
    public var encryptedPrivateKey: String?
    public var kdf: KdfConfig
    public var userKey: SymmetricCryptoKey
    public var twoFactorRememberToken: String?
}

public enum TwoFactorProvider: Int, CaseIterable, Sendable {
    case authenticator = 0, email = 1, duo = 2, yubikey = 3, u2f = 4, remember = 5, orgDuo = 6, webAuthn = 7

    public var label: String {
        switch self {
        case .authenticator: "Authenticator app"
        case .email: "Email"
        case .duo, .orgDuo: "Duo"
        case .yubikey: "YubiKey OTP"
        case .u2f: "FIDO U2F"
        case .remember: "Remember"
        case .webAuthn: "Passkey / Security key"
        }
    }

    public var supported: Bool { [.authenticator, .email, .yubikey].contains(self) }
}

public final class VaultService: @unchecked Sendable {
    public let api: APIClient
    public var keys: KeyRing
    public var profile: Profile?

    public init(api: APIClient, keys: KeyRing) {
        self.api = api
        self.keys = keys
    }

    // MARK: Auth

    public static func login(api: APIClient, email: String, password: String, kdf: KdfConfig,
                             twoFactor: (provider: Int, token: String, remember: Bool)? = nil,
                             newDeviceOtp: String? = nil) async throws -> LoginSecrets {
        let mk = try KeyDerivation.masterKey(password: password, email: email, kdf: kdf)
        let hash = try KeyDerivation.masterPasswordHash(password: password, masterKey: mk)
        var f: [String: String] = [
            "grant_type": "password", "username": email.trimmingCharacters(in: .whitespaces).lowercased(), "password": hash,
            "scope": "api offline_access", "client_id": APIClient.clientName,
        ]
        if let tf = twoFactor {
            f["twoFactorProvider"] = String(tf.provider)
            f["twoFactorToken"] = tf.token
            f["twoFactorRemember"] = tf.remember ? "1" : "0"
        }
        if let newDeviceOtp { f["newDeviceOtp"] = newDeviceOtp }
        let t = try await api.token(f, email: email)
        guard let pk = t.key else { throw APIError.http(0, "Account has no master password (SSO/key connector not supported)") }
        let uk = try KeyDerivation.decryptUserKey(pk, with: mk)
        return LoginSecrets(tokens: api.tokens!, protectedUserKey: pk, encryptedPrivateKey: t.privateKey, kdf: kdf, userKey: uk,
                            twoFactorRememberToken: t.twoFactorToken)
    }

    public static func loginAPIKey(api: APIClient, clientId: String, clientSecret: String) async throws -> TokenResponse {
        try await api.token(["grant_type": "client_credentials", "client_id": clientId, "client_secret": clientSecret, "scope": "api"])
    }

    public static func sendEmailCode(api: APIClient, email: String, password: String, kdf: KdfConfig) async throws {
        let mk = try KeyDerivation.masterKey(password: password, email: email, kdf: kdf)
        let hash = try KeyDerivation.masterPasswordHash(password: password, masterKey: mk)
        try await api.call("POST", "/two-factor/send-email-login",
                           ["email": email, "masterPasswordHash": hash, "deviceIdentifier": api.deviceId] as [String: String])
    }

    public static func resendNewDeviceOtp(api: APIClient, email: String, password: String, kdf: KdfConfig) async throws {
        let mk = try KeyDerivation.masterKey(password: password, email: email, kdf: kdf)
        let hash = try KeyDerivation.masterPasswordHash(password: password, masterKey: mk)
        _ = try await api.raw("POST", "/accounts/resend-new-device-otp",
                              body: try JSON.encoder.encode(["email": email, "masterPasswordHash": hash]), auth: false)
    }

    public static func passwordHint(api: APIClient, email: String) async throws {
        _ = try await api.raw("POST", "/accounts/password-hint", body: try JSON.encoder.encode(["email": email]), auth: false)
    }

    /// Returns nil when the server emailed a verification link instead of returning the token directly.
    public static func requestRegistration(api: APIClient, email: String, name: String) async throws -> String? {
        let d = try await api.raw("POST", api.env.identityURL + "/accounts/register/send-verification-email",
                                  body: try JSON.encoder.encode(["email": email.lowercased(), "name": name]), auth: false)
        let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n")) ?? ""
        return s.isEmpty ? nil : s
    }

    public static func register(api: APIClient, email: String, name: String, password: String, hint: String, kdf: KdfConfig,
                                token: String? = nil) async throws {
        var token = token
        if token == nil {
            token = try await requestRegistration(api: api, email: email, name: name)
            guard token != nil else { throw APIError.http(0, "Check your email and paste the verification link to finish creating the account.") }
        }
        if let t = token, let c = URLComponents(string: t) {
            let items = c.queryItems ?? c.fragment.flatMap { URLComponents(string: $0)?.queryItems }
            if let q = items?.first(where: { $0.name == "token" })?.value { token = q }
        }
        let mk = try KeyDerivation.masterKey(password: password, email: email, kdf: kdf)
        let hash = try KeyDerivation.masterPasswordHash(password: password, masterKey: mk)
        let uk = SymmetricCryptoKey.generate()
        let pk = try KeyDerivation.protectUserKey(uk, with: mk)
        let rsa = try RSA.generate()
        let keys: JSONValue = .object(["publicKey": .string(rsa.publicSPKI.base64EncodedString()),
                                       "encryptedPrivateKey": .string(try EncString.encrypt(rsa.privatePKCS8, key: uk).description)])
        var body: [String: JSONValue] = [
            "email": .string(email.lowercased()), "masterPasswordHash": .string(hash), "emailVerificationToken": .string(token ?? ""),
            "masterPasswordHint": hint.isEmpty ? .null : .string(hint), "userSymmetricKey": .string(pk), "userAsymmetricKeys": keys,
            "kdf": .number(Double(kdf.type)), "kdfIterations": .number(Double(kdf.iterations)),
        ]
        if let m = kdf.memory { body["kdfMemory"] = .number(Double(m)) }
        if let p = kdf.parallelism { body["kdfParallelism"] = .number(Double(p)) }
        _ = try await api.raw("POST", api.env.identityURL + "/accounts/register/finish", body: try JSON.encoder.encode(body), auth: false)
    }

    public static func unlock(password: String, email: String, kdf: KdfConfig, protectedUserKey: String) throws -> SymmetricCryptoKey {
        let mk = try KeyDerivation.masterKey(password: password, email: email, kdf: kdf)
        return try KeyDerivation.decryptUserKey(protectedUserKey, with: mk)
    }

    // MARK: Sync

    public func fetchSync() async throws -> Data {
        try await api.raw("GET", "/sync?excludeDomains=true")
    }

    public func revisionDate() async throws -> Double? {
        let d = try await api.raw("GET", "/accounts/revision-date")
        return Double(String(data: d, encoding: .utf8) ?? "")
    }

    public func loadKeys(profile: Profile, encryptedPrivateKey: String?) {
        self.profile = profile
        if let pkStr = profile.privateKey ?? encryptedPrivateKey,
           let der = try? EncString(pkStr).decrypt(key: keys.userKey),
           let sk = try? RSA.privateKey(der: der) {
            keys.privateKey = sk
        }
        var org: [String: SymmetricCryptoKey] = [:]
        for o in profile.organizations ?? [] {
            guard let k = o.key, let sk = keys.privateKey, let e = try? EncString(k),
                  let raw = try? RSA.decrypt(e, privateKey: sk), let key = try? SymmetricCryptoKey(raw) else { continue }
            org[o.id] = key
        }
        keys.orgKeys = org
    }

    public func decryptVault(_ data: Data) throws -> DecryptedVault {
        let s = try JSON.decoder.decode(SyncResponse.self, from: data)
        loadKeys(profile: s.profile, encryptedPrivateKey: nil)
        let ciphers = decryptAll(s.ciphers ?? [])
        let folders = (s.folders ?? []).map { f in var x = f; x.name = dec(f.name, keys.userKey); return x }
        let cols = (s.collections ?? []).map { c in
            var x = c
            if let k = keys.orgKeys[c.organizationId] { x.name = dec(c.name, k) }
            return x
        }
        let sends = (s.sends ?? []).map(decrypt)
        return DecryptedVault(profile: s.profile, ciphers: ciphers, folders: folders.sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending },
                              collections: cols.sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending },
                              sends: sends, organizations: s.profile.organizations ?? [], policies: s.policies ?? [])
    }

    public func decryptAll(_ list: [Cipher]) -> [Cipher] {
        guard list.count > 64 else { return list.map(decrypt) }
        let out = UnsafeMutableBufferPointer<Cipher?>.allocate(capacity: list.count)
        out.initialize(repeating: nil)
        defer { out.deinitialize(); out.deallocate() }
        let chunks = min(ProcessInfo.processInfo.activeProcessorCount * 2, list.count)
        let size = (list.count + chunks - 1) / chunks
        let box = UncheckedBox(out)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let lo = c * size, hi = min(lo + size, list.count)
            guard lo < hi else { return }
            for i in lo ..< hi { box.value[i] = decrypt(list[i]) }
        }
        return out.map { $0! }
    }

    func dec(_ s: String?, _ key: SymmetricCryptoKey) -> String? {
        guard let s, !s.isEmpty else { return s }
        do { return try EncString(s).decryptString(key: key) } catch { return Self.decryptionError }
    }

    public static let decryptionError = "[decryption error]"

    public func itemKey(_ c: Cipher) throws -> SymmetricCryptoKey {
        guard let base = keys.key(for: c.organizationId) else { throw CryptoError.invalidKey }
        if let k = c.key { return try SymmetricCryptoKey(EncString(k).decrypt(key: base)) }
        return base
    }

    public func decrypt(_ c: Cipher) -> Cipher {
        guard let key = try? itemKey(c) else {
            var x = c
            x.name = "[locked: missing key]"
            x.notes = nil; x.login = nil; x.card = nil; x.identity = nil; x.fields = nil
            return x
        }
        return c.mapStrings { dec($0, key) }
    }

    public func encrypt(_ c: Cipher) throws -> Cipher {
        let key = try itemKey(c)
        var x = c
        if var l = x.login {
            l.uris = l.uris?.filter { !($0.uri ?? "").isEmpty }.map { u in
                var u = u
                u.uriChecksum = Primitives.sha256(Data((u.uri ?? "").utf8)).base64EncodedString()
                return u
            }
            x.login = l
        }
        x.fields = x.fields?.filter { !($0.name ?? "").isEmpty || !($0.value ?? "").isEmpty }
        var check = x
        check.attachments = nil
        _ = try check.mapStrings { s in
            if s == Self.decryptionError { throw CryptoError.undecryptableItem }
            return s
        }
        return try x.mapStrings { s in
            guard let s, !s.isEmpty else { return nil }
            return try EncString.encrypt(s, key: key).description
        }
    }

    // MARK: Cipher CRUD

    public func save(_ cipher: Cipher, collectionIds: [String] = []) async throws -> Cipher {
        let enc = try encrypt(cipher)
        let body = CipherRequest(enc, userId: profile?.id)
        let resp: Cipher
        if cipher.id.isEmpty {
            if cipher.organizationId != nil {
                struct Create: Encodable { var cipher: CipherRequest; var collectionIds: [String] }
                resp = try await api.send("POST", "/ciphers/create", Create(cipher: body, collectionIds: collectionIds))
            } else {
                resp = try await api.send("POST", "/ciphers", body)
            }
        } else {
            resp = try await api.send("PUT", "/ciphers/\(cipher.id)", body)
        }
        return decrypt(resp)
    }

    public func share(_ cipher: Cipher, organizationId: String, collectionIds: [String]) async throws -> Cipher {
        var c = cipher
        c.organizationId = organizationId
        c.key = nil
        c.folderId = cipher.folderId
        struct Share: Encodable { var cipher: CipherRequest; var collectionIds: [String] }
        let resp: Cipher = try await api.send("PUT", "/ciphers/\(cipher.id)/share", Share(cipher: CipherRequest(try encrypt(c), userId: profile?.id), collectionIds: collectionIds))
        return decrypt(resp)
    }

    public func updateCollections(_ id: String, collectionIds: [String]) async throws {
        try await api.call("PUT", "/ciphers/\(id)/collections", ["collectionIds": collectionIds])
    }

    public func partial(_ id: String, folderId: String?, favorite: Bool) async throws {
        struct P: Encodable { var folderId: String?; var favorite: Bool
            func encode(to e: Encoder) throws { var c = e.container(keyedBy: K.self); try c.encode(folderId, forKey: .folderId); try c.encode(favorite, forKey: .favorite) }
            enum K: String, CodingKey { case folderId, favorite }
        }
        try await api.call("PUT", "/ciphers/\(id)/partial", P(folderId: folderId, favorite: favorite))
    }

    public func trash(_ id: String) async throws { try await api.call("PUT", "/ciphers/\(id)/delete") }
    public func restore(_ id: String) async throws { try await api.call("PUT", "/ciphers/\(id)/restore") }
    public func deletePermanently(_ id: String) async throws { try await api.call("DELETE", "/ciphers/\(id)") }

    // MARK: Folders

    public func saveFolder(id: String?, name: String) async throws -> Folder {
        let body = ["name": try EncString.encrypt(name, key: keys.userKey).description]
        var f: Folder = id == nil ? try await api.send("POST", "/folders", body) : try await api.send("PUT", "/folders/\(id!)", body)
        f.name = name
        return f
    }

    public func deleteFolder(_ id: String) async throws { try await api.call("DELETE", "/folders/\(id)") }

    // MARK: Attachments

    public func downloadAttachment(cipher: Cipher, attachment: Attachment) async throws -> Data {
        struct R: Decodable { var url: String? }
        var url = attachment.url
        if let r: R = try? await api.send("GET", "/ciphers/\(cipher.id)/attachment/\(attachment.id)"), let u = r.url { url = u }
        guard let url else { throw APIError.invalidResponse }
        let blob = try await api.download(url)
        let ik = try itemKey(cipher)
        let key = try attachment.key.map { try SymmetricCryptoKey(EncString($0).decrypt(key: ik)) } ?? ik
        return try EncFile.decrypt(blob, key: key)
    }

    public func uploadAttachment(cipher: Cipher, fileName: String, data: Data) async throws {
        let ik = try itemKey(cipher)
        let ak = SymmetricCryptoKey.generate()
        let blob = try EncFile.encrypt(data, key: ak)
        let encName = try EncString.encrypt(fileName, key: ik).description
        struct Req: Encodable { var key, fileName: String; var fileSize: Int; var adminRequest = false }
        struct Resp: Decodable { var attachmentId: String; var url: String?; var fileUploadType: Int? }
        let r: Resp = try await api.send("POST", "/ciphers/\(cipher.id)/attachment/v2",
                                         Req(key: try EncString.encrypt(ak.data, key: ik).description, fileName: encName, fileSize: blob.count))
        try await api.upload(url: r.url ?? "", data: blob, azure: r.fileUploadType == 1, fileName: encName,
                             fallbackPath: "/ciphers/\(cipher.id)/attachment/\(r.attachmentId)")
    }

    public func deleteAttachment(cipherId: String, attachmentId: String) async throws {
        try await api.call("DELETE", "/ciphers/\(cipherId)/attachment/\(attachmentId)")
    }

    // MARK: Send

    static func sendKey(_ material: Data) throws -> SymmetricCryptoKey {
        try SymmetricCryptoKey(Primitives.hkdf(ikm: material, salt: "bitwarden-send", info: "send", length: 64))
    }

    public func decrypt(_ s: Send) -> Send {
        guard let k = s.key, let material = try? EncString(k).decrypt(key: keys.userKey), let key = try? Self.sendKey(material) else { return s }
        var x = s
        x.key = material.base64URL
        x.name = dec(s.name, key)
        x.notes = dec(s.notes, key)
        if var t = s.text { t.text = dec(t.text, key); x.text = t }
        if var f = s.file { f.fileName = dec(f.fileName, key); x.file = f }
        return x
    }

    public func sendLink(_ s: Send) -> String {
        let web = api.env.webVaultURL
        let base = web == "https://vault.bitwarden.com" ? "https://send.bitwarden.com/#" : web + "/#/send/"
        return base + (s.accessId ?? "") + "/" + (s.key ?? "")
    }

    public func saveSend(_ send: Send, newPassword: String?, fileData: Data? = nil) async throws -> Send {
        let material = send.key.flatMap { Data(base64URL: $0) } ?? Primitives.random(16)
        let key = try Self.sendKey(material)
        func enc(_ v: String?) throws -> String? { guard let v, !v.isEmpty else { return nil }; return try EncString.encrypt(v, key: key).description }
        var e = send
        e.key = try EncString.encrypt(material, key: keys.userKey).description
        e.name = try enc(send.name)
        e.notes = try enc(send.notes)
        if var t = send.text { t.text = try enc(t.text); e.text = t }
        if var f = send.file { f.fileName = try enc(f.fileName); e.file = f }
        e.password = nil
        if let p = newPassword, !p.isEmpty {
            e.password = try Primitives.pbkdf2(password: Data(p.utf8), salt: material, iterations: 100_000).base64EncodedString()
        }
        var resp: Send
        if send.id.isEmpty, send.type == 1, let fileData {
            let blob = try EncFile.encrypt(fileData, key: key)
            e.fileLength = blob.count
            struct R: Decodable { var url: String?; var fileUploadType: Int?; var sendResponse: Send }
            let r: R = try await api.send("POST", "/sends/file/v2", SendRequest(e))
            resp = r.sendResponse
            try await api.upload(url: r.url ?? "", data: blob, azure: r.fileUploadType == 1, fileName: e.file?.fileName ?? "file",
                                 fallbackPath: "/sends/\(resp.id)/file/\(resp.file?.id ?? "")")
        } else if send.id.isEmpty {
            resp = try await api.send("POST", "/sends", SendRequest(e))
        } else {
            resp = try await api.send("PUT", "/sends/\(send.id)", SendRequest(e))
        }
        return decrypt(resp)
    }

    public func removeSendPassword(_ id: String) async throws { try await api.call("PUT", "/sends/\(id)/remove-password") }
    public func deleteSend(_ id: String) async throws { try await api.call("DELETE", "/sends/\(id)") }

    // MARK: Import

    public func importVault(ciphers: [Cipher], folders: [String], relations: [(cipher: Int, folder: Int)]) async throws {
        struct KV: Encodable { var key: Int; var value: Int }
        struct Req: Encodable { var ciphers: [CipherRequest]; var folders: [[String: String]]; var folderRelationships: [KV] }
        let enc = try ciphers.map { c -> CipherRequest in
            var x = c
            x.organizationId = nil; x.key = nil; x.id = ""; x.revisionDate = nil
            return CipherRequest(try encrypt(x), userId: profile?.id)
        }
        let f = try folders.map { ["name": try EncString.encrypt($0, key: keys.userKey).description] }
        try await api.call("POST", "/ciphers/import", Req(ciphers: enc, folders: f, folderRelationships: relations.map { KV(key: $0.cipher, value: $0.folder) }))
    }

    public func fingerprintPhrase() -> String? {
        guard let p = profile, let sk = keys.privateKey, let pub = try? RSA.publicSPKI(of: sk) else { return nil }
        return Fingerprint.phrase(userId: p.id, publicKey: pub)
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}

public extension Cipher {
    mutating func recordHistory(from old: Cipher?) {
        guard let old, type == .login else { return }
        var hist = passwordHistory ?? []
        let now = Dates.string(Date())
        if let op = old.login?.password, !op.isEmpty, op != login?.password {
            hist.insert(PasswordHistory(password: op, lastUsedDate: now), at: 0)
            login?.passwordRevisionDate = now
        }
        for f in old.fields ?? [] where f.type == .hidden && !(f.value ?? "").isEmpty {
            let new = fields?.first { $0.name == f.name && $0.type == .hidden }
            if new?.value != f.value {
                hist.insert(PasswordHistory(password: "\(f.name ?? ""): \(f.value ?? "")", lastUsedDate: now), at: 0)
            }
        }
        passwordHistory = Array(hist.prefix(5))
    }
}


