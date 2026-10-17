import Foundation

public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var it = Array(text.replacingOccurrences(of: "\r\n", with: "\n")).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() {
                        if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r": row.append(field); field = ""; rows.append(row); row = []
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    public static func escape(_ s: String?) -> String {
        let v = s ?? ""
        if v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}

public struct ImportResult {
    public var ciphers: [Cipher] = []
    public var folders: [String] = []
    public var relations: [(cipher: Int, folder: Int)] = []

    mutating func add(_ c: Cipher, folder: String?) {
        ciphers.append(c)
        if let f = folder?.trimmingCharacters(in: .whitespaces), !f.isEmpty {
            var idx = folders.firstIndex(of: f)
            if idx == nil { folders.append(f); idx = folders.count - 1 }
            relations.append((ciphers.count - 1, idx!))
        }
    }
}

public enum ImportExportError: LocalizedError {
    case unsupported, wrongPassword, accountRestricted
    public var errorDescription: String? {
        switch self {
        case .unsupported: "Unrecognized file format"
        case .wrongPassword: "Wrong file password"
        case .accountRestricted: "Account-restricted encrypted exports can only be imported into the account that created them via the web vault."
        }
    }
}

public enum Exporter {
    static let dropKeys: Set<String> = ["key", "attachments", "edit", "viewPassword", "organizationUseTotp", "lastKnownRevisionDate",
                                        "revisionDate", "creationDate", "deletedDate", "archivedDate"]

    public static func json(ciphers: [Cipher], folders: [Folder]) throws -> Data {
        let items: [Any] = try ciphers.filter { !$0.isDeleted }.map { c in
            var o = try JSONSerialization.jsonObject(with: JSON.encoder.encode(c)) as! [String: Any]
            for k in dropKeys { o.removeValue(forKey: k) }
            if o["organizationId"] == nil { o["organizationId"] = NSNull() }
            if o["folderId"] == nil { o["folderId"] = NSNull() }
            return o
        }
        let root: [String: Any] = ["encrypted": false,
                                   "folders": folders.map { ["id": $0.id, "name": $0.name ?? ""] },
                                   "items": items]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func encryptedJSON(ciphers: [Cipher], folders: [Folder], password: String, kdf: KdfConfig = .pbkdf2Default) throws -> Data {
        let salt = Primitives.random(16).base64EncodedString()
        let key = KeyDerivation.stretch(try KeyDerivation.deriveKey(secret: password, salt: salt, kdf: kdf))
        let plain = try json(ciphers: ciphers, folders: folders)
        var root: [String: Any] = [
            "encrypted": true, "passwordProtected": true, "salt": salt, "kdfType": kdf.type, "kdfIterations": kdf.iterations,
            "encKeyValidation_DO_NOT_EDIT": try EncString.encrypt(UUID().uuidString, key: key).description,
            "data": try EncString.encrypt(plain, key: key).description,
        ]
        if let m = kdf.memory { root["kdfMemory"] = m }
        if let p = kdf.parallelism { root["kdfParallelism"] = p }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func csv(ciphers: [Cipher], folders: [Folder]) -> String {
        let names = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name ?? "") })
        var out = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n"
        for c in ciphers where !c.isDeleted && (c.type == .login || c.type == .secureNote) {
            let fields = (c.fields ?? []).map { "\($0.name ?? ""): \($0.value ?? "")" }.joined(separator: "\n")
            let uris = (c.login?.uris ?? []).compactMap(\.uri).joined(separator: ",")
            let cols: [String?] = [c.folderId.flatMap { names[$0] }, c.isFavorite ? "1" : "", c.type == .login ? "login" : "note",
                                   c.name, c.notes, fields, String(c.reprompt ?? 0), uris, c.login?.username, c.login?.password, c.login?.totp]
            out += cols.map(CSV.escape).joined(separator: ",") + "\n"
        }
        return out
    }
}

public enum Importer {
    public static func detect(_ data: Data, password: String? = nil) throws -> ImportResult {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return try bitwardenJSON(obj, password: password)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw ImportExportError.unsupported }
        return try csv(text)
    }

    public static func needsPassword(_ data: Data) -> Bool {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return o["passwordProtected"] as? Bool == true
    }

    static func bitwardenJSON(_ root: [String: Any], password: String?) throws -> ImportResult {
        var root = root
        if root["encrypted"] as? Bool == true {
            guard root["passwordProtected"] as? Bool == true else { throw ImportExportError.accountRestricted }
            guard let password, let salt = root["salt"] as? String, let data = root["data"] as? String else { throw ImportExportError.wrongPassword }
            let kdf = KdfConfig(type: root["kdfType"] as? Int ?? 0, iterations: root["kdfIterations"] as? Int ?? 600_000,
                                memory: root["kdfMemory"] as? Int, parallelism: root["kdfParallelism"] as? Int)
            let key = KeyDerivation.stretch(try KeyDerivation.deriveKey(secret: password, salt: salt, kdf: kdf))
            guard let plain = try? EncString(data).decrypt(key: key),
                  let inner = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw ImportExportError.wrongPassword }
            root = inner
        }
        var result = ImportResult()
        let folders = (root["folders"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) { $0[$1["id"] as? String ?? ""] = $1["name"] as? String }
        for item in root["items"] as? [[String: Any]] ?? [] {
            var it = item
            it.removeValue(forKey: "id")
            it.removeValue(forKey: "collectionIds")
            it.removeValue(forKey: "organizationId")
            let d = try JSONSerialization.data(withJSONObject: it)
            guard var c = try? JSON.decoder.decode(Cipher.self, from: d) else { continue }
            c.folderId = nil
            result.add(c, folder: (item["folderId"] as? String).flatMap { folders[$0] })
        }
        return result
    }

    static func csv(_ text: String) throws -> ImportResult {
        let rows = CSV.parse(text)
        guard let header = rows.first?.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) else { throw ImportExportError.unsupported }
        func col(_ names: String...) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        let iName = col("name", "title", "account", "item name")
        let iURL = col("login_uri", "url", "website", "web site", "login url", "uri", "hostname")
        let iUser = col("login_username", "username", "user name", "login", "email", "login name")
        let iPass = col("login_password", "password")
        let iNotes = col("notes", "note", "comments", "extra")
        let iTotp = col("login_totp", "totp", "otpauth", "one-time password", "otp")
        let iFolder = col("folder", "grouping", "group", "category")
        let iFav = col("favorite", "fav")
        let iType = col("type")
        let iFields = col("fields")
        guard iPass != nil || iNotes != nil else { throw ImportExportError.unsupported }
        var result = ImportResult()
        for r in rows.dropFirst() {
            func v(_ i: Int?) -> String? { guard let i, i < r.count else { return nil }; let s = r[i]; return s.isEmpty ? nil : s }
            let isNote = v(iType)?.lowercased() == "note"
            var c = Cipher(type: isNote ? .secureNote : .login)
            c.name = v(iName) ?? v(iURL).flatMap(URLMatcher.host(of:)) ?? "--"
            c.notes = v(iNotes)
            c.favorite = v(iFav) == "1" || v(iFav)?.lowercased() == "true"
            if !isNote {
                c.login?.username = v(iUser)
                c.login?.password = v(iPass)
                c.login?.totp = v(iTotp)
                if let u = v(iURL) { c.login?.uris = u.split(separator: ",").map { LoginUri(uri: String($0)) } }
            }
            if let f = v(iFields) {
                c.fields = f.split(separator: "\n").map { line in
                    let p = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return Field(name: p.first, value: p.count > 1 ? p[1] : nil)
                }
            }
            result.add(c, folder: v(iFolder))
        }
        return result
    }
}
