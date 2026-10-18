import Foundation

public struct SymmetricCryptoKey: Hashable, Sendable {
    public let encKey: Data
    public let macKey: Data?

    public init(_ data: Data) throws {
        switch data.count {
        case 64: encKey = Data(data.prefix(32)); macKey = Data(data.suffix(32))
        case 32: encKey = Data(data); macKey = nil
        default: throw CryptoError.invalidKey
        }
    }

    public init(enc: Data, mac: Data) { encKey = enc; macKey = mac }

    public static func generate() -> SymmetricCryptoKey { try! SymmetricCryptoKey(Primitives.random(64)) }

    public var data: Data { encKey + (macKey ?? Data()) }
}

public struct EncString: Hashable, Sendable, CustomStringConvertible {
    public let type: Int
    public let iv: Data?
    public let data: Data
    public let mac: Data?

    public init(type: Int, iv: Data?, data: Data, mac: Data?) {
        self.type = type; self.iv = iv; self.data = data; self.mac = mac
    }

    public init(_ s: String) throws {
        let type: Int
        let body: Substring
        if let dot = s.firstIndex(of: "."), let t = Int(s[s.startIndex ..< dot]) {
            type = t
            body = s[s.index(after: dot)...]
        } else {
            body = Substring(s)
            type = s.split(separator: "|").count == 3 ? 1 : 0
        }
        let raw = body.split(separator: "|", omittingEmptySubsequences: false).map { Data(base64Encoded: String($0)) }
        guard !raw.contains(where: { $0 == nil }) else { throw CryptoError.invalidEncString }
        let parts = raw.map { $0! }
        switch type {
        case 0:
            guard parts.count == 2 else { throw CryptoError.invalidEncString }
            self.init(type: 0, iv: parts[0], data: parts[1], mac: nil)
        case 1, 2:
            guard parts.count == 3 else { throw CryptoError.invalidEncString }
            self.init(type: type, iv: parts[0], data: parts[1], mac: parts[2])
        case 3, 4:
            guard parts.count >= 1 else { throw CryptoError.invalidEncString }
            self.init(type: type, iv: nil, data: parts[0], mac: nil)
        case 5, 6:
            guard parts.count == 2 else { throw CryptoError.invalidEncString }
            self.init(type: type, iv: nil, data: parts[0], mac: parts[1])
        default: throw CryptoError.invalidEncString
        }
    }

    public var description: String {
        switch type {
        case 0: "0.\(iv!.base64EncodedString())|\(data.base64EncodedString())"
        case 1, 2: "\(type).\(iv!.base64EncodedString())|\(data.base64EncodedString())|\(mac!.base64EncodedString())"
        case 3, 4: "\(type).\(data.base64EncodedString())"
        default: "\(type).\(data.base64EncodedString())|\(mac?.base64EncodedString() ?? "")"
        }
    }

    public static func encrypt(_ plain: Data, key: SymmetricCryptoKey) throws -> EncString {
        guard let macKey = key.macKey else { throw CryptoError.invalidKey }
        let iv = Primitives.random(16)
        let ct = try Primitives.aesEncrypt(plain, key: key.encKey, iv: iv)
        let mac = Primitives.hmacSHA256(iv + ct, key: macKey)
        return EncString(type: 2, iv: iv, data: ct, mac: mac)
    }

    public static func encrypt(_ s: String, key: SymmetricCryptoKey) throws -> EncString {
        try encrypt(Data(s.utf8), key: key)
    }

    public func decrypt(key: SymmetricCryptoKey) throws -> Data {
        guard let iv else { throw CryptoError.invalidEncString }
        switch type {
        case 2:
            guard let macKey = key.macKey, let mac else { throw CryptoError.invalidKey }
            guard Primitives.constantTimeEqual(Primitives.hmacSHA256(iv + data, key: macKey), mac) else { throw CryptoError.macMismatch }
        case 0:
            guard key.macKey == nil else { throw CryptoError.invalidEncString }
        default:
            throw CryptoError.invalidEncString
        }
        return try Primitives.aesDecrypt(data, key: key.encKey, iv: iv)
    }

    public func decryptString(key: SymmetricCryptoKey) throws -> String {
        guard let s = String(data: try decrypt(key: key), encoding: .utf8) else { throw CryptoError.decryptFailed }
        return s
    }
}

public enum EncFile {
    public static func decrypt(_ blob: Data, key: SymmetricCryptoKey) throws -> Data {
        let b = [UInt8](blob)
        guard b.count > 49, b[0] == 2, let macKey = key.macKey else { throw CryptoError.invalidEncString }
        let iv = Data(b[1 ..< 17]), mac = Data(b[17 ..< 49]), ct = Data(b[49...])
        guard Primitives.constantTimeEqual(Primitives.hmacSHA256(iv + ct, key: macKey), mac) else { throw CryptoError.macMismatch }
        return try Primitives.aesDecrypt(ct, key: key.encKey, iv: iv)
    }

    public static func encrypt(_ data: Data, key: SymmetricCryptoKey) throws -> Data {
        let e = try EncString.encrypt(data, key: key)
        return Data([2]) + e.iv! + e.mac! + e.data
    }
}
