import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(s): try c.encode(s)
        case let .number(n): try c.encode(n)
        case let .bool(b): try c.encode(b)
        case let .object(o): try c.encode(o)
        case let .array(a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    public var int: Int? { if case let .number(n) = self { Int(n) } else if case let .string(s) = self { Int(s) } else { nil } }
    public var bool: Bool? { if case let .bool(b) = self { b } else { nil } }
    public var string: String? { if case let .string(s) = self { s } else { nil } }
}

public enum CipherType: Int, Codable, CaseIterable, Sendable {
    case login = 1, secureNote, card, identity, sshKey

    public var label: String {
        switch self {
        case .login: "Login"
        case .secureNote: "Secure Note"
        case .card: "Card"
        case .identity: "Identity"
        case .sshKey: "SSH Key"
        }
    }

    public var symbol: String {
        switch self {
        case .login: "globe"
        case .secureNote: "note.text"
        case .card: "creditcard"
        case .identity: "person.text.rectangle"
        case .sshKey: "key.horizontal"
        }
    }
}

public enum UriMatch: Int, Codable, CaseIterable, Sendable {
    case domain = 0, host, startsWith, exact, regex, never

    public var label: String {
        switch self {
        case .domain: "Base domain"
        case .host: "Host"
        case .startsWith: "Starts with"
        case .exact: "Exact"
        case .regex: "Regular expression"
        case .never: "Never"
        }
    }
}

public struct LoginUri: Codable, Hashable, Sendable {
    public var uri: String?
    public var uriChecksum: String?
    public var match: UriMatch?
    public init(uri: String? = nil, match: UriMatch? = nil) { self.uri = uri; self.match = match }
}

public struct Fido2Credential: Codable, Hashable, Sendable {
    public var credentialId, keyType, keyAlgorithm, keyCurve, keyValue, rpId, userHandle, userName, counter, rpName, userDisplayName, discoverable: String?
    public var creationDate: String?
}

public struct Login: Codable, Hashable, Sendable {
    public var username, password, totp: String?
    public var uris: [LoginUri]?
    public var passwordRevisionDate: String?
    public var autofillOnPageLoad: Bool?
    public var fido2Credentials: [Fido2Credential]?
    public init() {}
}

public struct Card: Codable, Hashable, Sendable {
    public var cardholderName, brand, number, expMonth, expYear, code: String?
    public init() {}
}

public struct Identity: Codable, Hashable, Sendable {
    public var title, firstName, middleName, lastName, address1, address2, address3, city, state, postalCode, country,
               company, email, phone, ssn, username, passportNumber, licenseNumber: String?
    public init() {}

    public var fullName: String { [title, firstName, middleName, lastName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ") }
}

public struct SecureNote: Codable, Hashable, Sendable {
    public var type: Int = 0
    public init() {}
}

public struct SSHKeyData: Codable, Hashable, Sendable {
    public var privateKey, publicKey, keyFingerprint: String?
    public init(privateKey: String? = nil, publicKey: String? = nil, keyFingerprint: String? = nil) {
        self.privateKey = privateKey; self.publicKey = publicKey; self.keyFingerprint = keyFingerprint
    }
}

public enum FieldType: Int, Codable, CaseIterable, Sendable {
    case text = 0, hidden, boolean, linked
    public var label: String { ["Text", "Hidden", "Checkbox", "Linked"][rawValue] }
}

public struct Field: Codable, Hashable, Sendable, Identifiable {
    public var name, value: String?
    public var type: FieldType
    public var linkedId: Int?
    public var localId = UUID()
    public var id: UUID { localId }

    enum CodingKeys: String, CodingKey { case name, value, type, linkedId }

    public init(name: String? = nil, value: String? = nil, type: FieldType = .text, linkedId: Int? = nil) {
        self.name = name; self.value = value; self.type = type; self.linkedId = linkedId
    }
}

public struct PasswordHistory: Codable, Hashable, Sendable {
    public var password: String?
    public var lastUsedDate: String?
    public init(password: String?, lastUsedDate: String?) { self.password = password; self.lastUsedDate = lastUsedDate }
}

public struct Attachment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var url, fileName, key, sizeName: String?
    public var size: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        sizeName = try c.decodeIfPresent(String.self, forKey: .sizeName)
        size = (try? c.decodeIfPresent(String.self, forKey: .size)) ?? (try? c.decodeIfPresent(Int.self, forKey: .size)).flatMap { $0.map(String.init) }
    }
}

struct CipherData: Codable, Hashable, Sendable {
    var id: String = ""
    var organizationId, folderId: String?
    var type: CipherType = .login
    var name, notes: String?
    var favorite: Bool?
    var reprompt: Int?
    var key: String?
    var login: Login?
    var card: Card?
    var identity: Identity?
    var secureNote: SecureNote?
    var sshKey: SSHKeyData?
    var fields: [Field]?
    var passwordHistory: [PasswordHistory]?
    var attachments: [Attachment]?
    var collectionIds: [String]?
    var revisionDate, creationDate, deletedDate, archivedDate: String?
    var edit, viewPassword, organizationUseTotp: Bool?
    var lastKnownRevisionDate: String?

    init(type: CipherType = .login) {
        self.type = type
        switch type {
        case .login: login = Login()
        case .card: card = Card()
        case .identity: identity = Identity()
        case .secureNote: secureNote = SecureNote()
        case .sshKey: sshKey = SSHKeyData()
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        organizationId = try c.decodeIfPresent(String.self, forKey: .organizationId)
        folderId = try c.decodeIfPresent(String.self, forKey: .folderId)
        type = (try? c.decode(CipherType.self, forKey: .type)) ?? .secureNote
        name = try c.decodeIfPresent(String.self, forKey: .name)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite)
        reprompt = try c.decodeIfPresent(Int.self, forKey: .reprompt)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        login = try c.decodeIfPresent(Login.self, forKey: .login)
        card = try c.decodeIfPresent(Card.self, forKey: .card)
        identity = try c.decodeIfPresent(Identity.self, forKey: .identity)
        secureNote = try c.decodeIfPresent(SecureNote.self, forKey: .secureNote)
        sshKey = try c.decodeIfPresent(SSHKeyData.self, forKey: .sshKey)
        fields = try c.decodeIfPresent([Field].self, forKey: .fields)
        passwordHistory = try c.decodeIfPresent([PasswordHistory].self, forKey: .passwordHistory)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments)
        collectionIds = try c.decodeIfPresent([String].self, forKey: .collectionIds)
        revisionDate = try c.decodeIfPresent(String.self, forKey: .revisionDate)
        creationDate = try c.decodeIfPresent(String.self, forKey: .creationDate)
        deletedDate = try c.decodeIfPresent(String.self, forKey: .deletedDate)
        archivedDate = try c.decodeIfPresent(String.self, forKey: .archivedDate)
        edit = try c.decodeIfPresent(Bool.self, forKey: .edit)
        viewPassword = try c.decodeIfPresent(Bool.self, forKey: .viewPassword)
        organizationUseTotp = try c.decodeIfPresent(Bool.self, forKey: .organizationUseTotp)
    }
}

public struct Cipher: Codable, Hashable, Sendable, Identifiable {
    private final class Box: @unchecked Sendable {
        var v: CipherData
        init(_ v: CipherData) { self.v = v }
    }

    private var box: Box
    private var v: CipherData {
        get { box.v }
        _modify {
            if !isKnownUniquelyReferenced(&box) { box = Box(box.v) }
            yield &box.v
        }
    }

    public init(type: CipherType = .login) { box = Box(CipherData(type: type)) }
    public init(from decoder: Decoder) throws { box = Box(try CipherData(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try box.v.encode(to: encoder) }
    public static func == (a: Cipher, b: Cipher) -> Bool { a.box === b.box || a.box.v == b.box.v }
    public func hash(into h: inout Hasher) { h.combine(box.v) }

    public var id: String { get { box.v.id } _modify { yield &v.id } }
    public var organizationId: String? { get { box.v.organizationId } _modify { yield &v.organizationId } }
    public var folderId: String? { get { box.v.folderId } _modify { yield &v.folderId } }
    public var type: CipherType { get { box.v.type } _modify { yield &v.type } }
    public var name: String? { get { box.v.name } _modify { yield &v.name } }
    public var notes: String? { get { box.v.notes } _modify { yield &v.notes } }
    public var favorite: Bool? { get { box.v.favorite } _modify { yield &v.favorite } }
    public var reprompt: Int? { get { box.v.reprompt } _modify { yield &v.reprompt } }
    public var key: String? { get { box.v.key } _modify { yield &v.key } }
    public var login: Login? { get { box.v.login } _modify { yield &v.login } }
    public var card: Card? { get { box.v.card } _modify { yield &v.card } }
    public var identity: Identity? { get { box.v.identity } _modify { yield &v.identity } }
    public var secureNote: SecureNote? { get { box.v.secureNote } _modify { yield &v.secureNote } }
    public var sshKey: SSHKeyData? { get { box.v.sshKey } _modify { yield &v.sshKey } }
    public var fields: [Field]? { get { box.v.fields } _modify { yield &v.fields } }
    public var passwordHistory: [PasswordHistory]? { get { box.v.passwordHistory } _modify { yield &v.passwordHistory } }
    public var attachments: [Attachment]? { get { box.v.attachments } _modify { yield &v.attachments } }
    public var collectionIds: [String]? { get { box.v.collectionIds } _modify { yield &v.collectionIds } }
    public var revisionDate: String? { get { box.v.revisionDate } _modify { yield &v.revisionDate } }
    public var creationDate: String? { get { box.v.creationDate } _modify { yield &v.creationDate } }
    public var deletedDate: String? { get { box.v.deletedDate } _modify { yield &v.deletedDate } }
    public var archivedDate: String? { get { box.v.archivedDate } _modify { yield &v.archivedDate } }
    public var edit: Bool? { get { box.v.edit } _modify { yield &v.edit } }
    public var viewPassword: Bool? { get { box.v.viewPassword } _modify { yield &v.viewPassword } }
    public var organizationUseTotp: Bool? { get { box.v.organizationUseTotp } _modify { yield &v.organizationUseTotp } }
    public var lastKnownRevisionDate: String? { get { box.v.lastKnownRevisionDate } _modify { yield &v.lastKnownRevisionDate } }

    public var isDeleted: Bool { deletedDate != nil }
    public var isFavorite: Bool { favorite ?? false }
    public var needsReprompt: Bool { (reprompt ?? 0) == 1 }
    public var canEdit: Bool { edit ?? true }
    public var canViewPassword: Bool { viewPassword ?? true }
    public var displayName: String { (name?.isEmpty == false ? name : nil) ?? "(no name)" }
    public var hasPasskey: Bool { !(login?.fido2Credentials ?? []).isEmpty }
    public var hasTotp: Bool { !(login?.totp ?? "").isEmpty }

    public var subtitle: String {
        switch type {
        case .login: return login?.username?.isEmpty == false ? login!.username! : "no username"
        case .card:
            let n = card?.number ?? ""
            let tail = n.count >= 4 ? "*" + n.suffix(4) : ""
            return [card?.brand, tail].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
        case .identity: return identity?.fullName ?? ""
        case .sshKey: return sshKey?.keyFingerprint ?? ""
        case .secureNote: return String((notes ?? "").prefix(60)).replacingOccurrences(of: "\n", with: " ")
        }
    }

    public var primaryHost: String? {
        for u in login?.uris ?? [] {
            if let s = u.uri, let h = URLMatcher.host(of: s) { return h }
        }
        return nil
    }

    func mapStrings(_ f: (String?) throws -> String?) rethrows -> Cipher {
        var c = self
        c.name = try f(name)
        c.notes = try f(notes)
        if var l = login {
            l.username = try f(l.username); l.password = try f(l.password); l.totp = try f(l.totp)
            l.uris = try l.uris?.map { var u = $0; u.uri = try f(u.uri); u.uriChecksum = try f(u.uriChecksum); return u }
            l.fido2Credentials = try l.fido2Credentials?.map { o in
                var x = o
                x.credentialId = try f(o.credentialId); x.keyType = try f(o.keyType); x.keyAlgorithm = try f(o.keyAlgorithm)
                x.keyCurve = try f(o.keyCurve); x.keyValue = try f(o.keyValue); x.rpId = try f(o.rpId)
                x.userHandle = try f(o.userHandle); x.userName = try f(o.userName); x.counter = try f(o.counter)
                x.rpName = try f(o.rpName); x.userDisplayName = try f(o.userDisplayName); x.discoverable = try f(o.discoverable)
                return x
            }
            c.login = l
        }
        if var k = card {
            k.cardholderName = try f(k.cardholderName); k.brand = try f(k.brand); k.number = try f(k.number)
            k.expMonth = try f(k.expMonth); k.expYear = try f(k.expYear); k.code = try f(k.code)
            c.card = k
        }
        if var i = identity {
            i.title = try f(i.title); i.firstName = try f(i.firstName); i.middleName = try f(i.middleName); i.lastName = try f(i.lastName)
            i.address1 = try f(i.address1); i.address2 = try f(i.address2); i.address3 = try f(i.address3)
            i.city = try f(i.city); i.state = try f(i.state); i.postalCode = try f(i.postalCode); i.country = try f(i.country)
            i.company = try f(i.company); i.email = try f(i.email); i.phone = try f(i.phone); i.ssn = try f(i.ssn)
            i.username = try f(i.username); i.passportNumber = try f(i.passportNumber); i.licenseNumber = try f(i.licenseNumber)
            c.identity = i
        }
        if var s = sshKey {
            s.privateKey = try f(s.privateKey); s.publicKey = try f(s.publicKey); s.keyFingerprint = try f(s.keyFingerprint)
            c.sshKey = s
        }
        c.fields = try fields?.map { var x = $0; x.name = try f(x.name); x.value = try f(x.value); return x }
        c.passwordHistory = try passwordHistory?.map { var x = $0; x.password = try f(x.password); return x }
        c.attachments = try attachments?.map { var x = $0; x.fileName = try f(x.fileName); return x }
        return c
    }
}

public struct Folder: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var revisionDate: String?
}

public struct Collection: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var organizationId: String
    public var name: String?
    public var readOnly, hidePasswords, manage: Bool?
}

public struct ProfileOrganization: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var key: String?
    public var type: Int?
    public var enabled: Bool?
    public var useTotp: Bool?
    public var usersGetPremium: Bool?
}

public struct Profile: Codable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var email: String
    public var emailVerified: Bool?
    public var premium: Bool?
    public var premiumFromOrganization: Bool?
    public var key: String?
    public var privateKey: String?
    public var securityStamp: String?
    public var twoFactorEnabled: Bool?
    public var avatarColor: String?
    public var organizations: [ProfileOrganization]?
}

public struct SendText: Codable, Hashable, Sendable {
    public var text: String?
    public var hidden: Bool?
    public init(text: String? = nil, hidden: Bool? = false) { self.text = text; self.hidden = hidden }
}

public struct SendFile: Codable, Hashable, Sendable {
    public var id, fileName, sizeName: String?
    public var size: String?

    public init(id: String? = nil, fileName: String? = nil) { self.id = id; self.fileName = fileName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        sizeName = try c.decodeIfPresent(String.self, forKey: .sizeName)
        size = (try? c.decodeIfPresent(String.self, forKey: .size)) ?? (try? c.decodeIfPresent(Int.self, forKey: .size)).flatMap { $0.map(String.init) }
    }
}

public struct Send: Codable, Hashable, Sendable, Identifiable {
    public var id: String = ""
    public var accessId: String?
    public var type: Int = 0
    public var name, notes: String?
    public var text: SendText?
    public var file: SendFile?
    public var key: String?
    public var maxAccessCount: Int?
    public var accessCount: Int?
    public var password: String?
    public var disabled: Bool = false
    public var hideEmail: Bool?
    public var revisionDate, expirationDate, deletionDate: String?
    public var fileLength: Int?

    public init(type: Int = 0) { self.type = type; if type == 0 { text = SendText() } }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        accessId = try c.decodeIfPresent(String.self, forKey: .accessId)
        type = try c.decodeIfPresent(Int.self, forKey: .type) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        text = try c.decodeIfPresent(SendText.self, forKey: .text)
        file = try c.decodeIfPresent(SendFile.self, forKey: .file)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        maxAccessCount = try c.decodeIfPresent(Int.self, forKey: .maxAccessCount)
        accessCount = try c.decodeIfPresent(Int.self, forKey: .accessCount)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        hideEmail = try c.decodeIfPresent(Bool.self, forKey: .hideEmail)
        revisionDate = try c.decodeIfPresent(String.self, forKey: .revisionDate)
        expirationDate = try c.decodeIfPresent(String.self, forKey: .expirationDate)
        deletionDate = try c.decodeIfPresent(String.self, forKey: .deletionDate)
    }
}

public struct Policy: Codable, Hashable, Sendable {
    public var id: String
    public var organizationId: String?
    public var type: Int
    public var data: [String: JSONValue]?
    public var enabled: Bool
}

public struct Domains: Codable, Hashable, Sendable {
    public struct Global: Codable, Hashable, Sendable { public var type: Int?; public var domains: [String]; public var excluded: Bool? }
    public var equivalentDomains: [[String]]?
    public var globalEquivalentDomains: [Global]?
}

public struct SyncResponse: Codable, Sendable {
    public var profile: Profile
    public var folders: [Folder]?
    public var collections: [Collection]?
    public var ciphers: [Cipher]?
    public var sends: [Send]?
    public var policies: [Policy]?
    public var domains: Domains?
}

public enum Dates {
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ s: String?) -> Date? {
        guard var s else { return nil }
        if !s.hasSuffix("Z") && !s.contains("+") { s += "Z" }
        if let d = iso.date(from: s) ?? isoPlain.date(from: s) { return d }
        if let dot = s.firstIndex(of: ".") {
            let base = String(s[..<dot])
            var frac = String(s[s.index(after: dot)...].prefix { $0.isNumber })
            frac = String(frac.prefix(3))
            return iso.date(from: base + "." + frac + "Z")
        }
        return nil
    }

    public static func string(_ d: Date) -> String { iso.string(from: d) }
}
