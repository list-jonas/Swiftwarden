import Foundation

public struct KdfConfig: Codable, Hashable, Sendable {
    public var type: Int
    public var iterations: Int
    public var memory: Int?
    public var parallelism: Int?

    public init(type: Int, iterations: Int, memory: Int? = nil, parallelism: Int? = nil) {
        self.type = type; self.iterations = iterations; self.memory = memory; self.parallelism = parallelism
    }

    public static let pbkdf2Default = KdfConfig(type: 0, iterations: 600_000)
    public static let argon2Default = KdfConfig(type: 1, iterations: 3, memory: 64, parallelism: 4)

    public func validate() throws {
        switch type {
        case 0:
            guard (5_000 ... 2_000_000).contains(iterations) else { throw CryptoError.unsafeKdf }
        case 1:
            guard (2 ... 10).contains(iterations), (16 ... 1024).contains(memory ?? 64), (1 ... 16).contains(parallelism ?? 4) else { throw CryptoError.unsafeKdf }
        default:
            throw CryptoError.unsafeKdf
        }
    }
}

public enum KeyDerivation {
    static func normalize(_ email: String) -> String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    public static func deriveKey(secret: String, salt: String, kdf: KdfConfig) throws -> Data {
        try kdf.validate()
        let pw = Data(secret.utf8)
        if kdf.type == 1 {
            let saltHash = Primitives.sha256(Data(salt.utf8))
            let out = Argon2id.hash(password: [UInt8](pw), salt: [UInt8](saltHash), iterations: kdf.iterations,
                                    memoryKiB: (kdf.memory ?? 64) * 1024, parallelism: kdf.parallelism ?? 4)
            return Data(out)
        }
        return try Primitives.pbkdf2(password: pw, salt: Data(salt.utf8), iterations: kdf.iterations)
    }

    public static func masterKey(password: String, email: String, kdf: KdfConfig) throws -> Data {
        try deriveKey(secret: password, salt: normalize(email), kdf: kdf)
    }

    public static func masterPasswordHash(password: String, masterKey: Data, iterations: Int = 1) throws -> String {
        try Primitives.pbkdf2(password: masterKey, salt: Data(password.utf8), iterations: iterations).base64EncodedString()
    }

    public static func stretch(_ key: Data) -> SymmetricCryptoKey {
        SymmetricCryptoKey(enc: Primitives.hkdfExpand(prk: key, info: "enc", length: 32),
                           mac: Primitives.hkdfExpand(prk: key, info: "mac", length: 32))
    }

    public static func decryptUserKey(_ protected: String, with key: Data) throws -> SymmetricCryptoKey {
        let e = try EncString(protected)
        let k = e.type == 0 ? try SymmetricCryptoKey(key) : stretch(key)
        return try SymmetricCryptoKey(e.decrypt(key: k))
    }

    public static func protectUserKey(_ userKey: SymmetricCryptoKey, with key: Data) throws -> String {
        try EncString.encrypt(userKey.data, key: stretch(key)).description
    }
}

public enum Fingerprint {
    public static let wordlist: [String] = {
        guard let url = Bundle.module.url(forResource: "wordlist", withExtension: "txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: \.isNewline).map(String.init)
    }()

    public static func phrase(userId: String, publicKey: Data) -> String {
        let fp = Primitives.hkdfExpand(prk: Primitives.sha256(publicKey), info: userId, length: 32)
        var num = [UInt8](fp)
        let n = wordlist.count
        guard n > 0 else { return "" }
        var words = [String]()
        let count = Int((64.0 / log2(Double(n))).rounded(.up))
        for _ in 0 ..< count {
            var rem = 0
            var q = [UInt8]()
            for byte in num {
                let cur = rem * 256 + Int(byte)
                let d = cur / n
                rem = cur % n
                if !q.isEmpty || d > 0 { q.append(UInt8(d)) }
            }
            words.append(wordlist[rem])
            num = q
        }
        return words.joined(separator: "-")
    }
}
