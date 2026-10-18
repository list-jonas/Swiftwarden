import CommonCrypto
import CryptoKit
import Foundation

public enum CryptoError: LocalizedError {
    case invalidEncString, macMismatch, decryptFailed, encryptFailed, invalidKey, rsa(String), kdf, unsafeKdf, undecryptableItem

    public var errorDescription: String? {
        switch self {
        case .invalidEncString: "Invalid encrypted value"
        case .macMismatch: "Wrong key or corrupted data"
        case .decryptFailed: "Decryption failed"
        case .encryptFailed: "Encryption failed"
        case .invalidKey: "Invalid key"
        case let .rsa(m): "RSA error: \(m)"
        case .kdf: "Key derivation failed"
        case .unsafeKdf: "The server sent unsafe key derivation settings. Login was stopped to protect your master password."
        case .undecryptableItem: "Parts of this item couldn't be decrypted, so it can't be saved without losing data."
        }
    }
}

public enum Primitives {
    public static func random(_ n: Int) -> Data {
        var d = Data(count: n)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    public static func randomInt(_ upper: Int) -> Int {
        var g = SystemRandomNumberGenerator()
        return Int.random(in: 0 ..< max(upper, 1), using: &g)
    }

    static func aesCBC(_ op: Int, _ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 32 || key.count == 16, iv.count == 16 else { throw CryptoError.invalidKey }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCap = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { i in
                        CCCrypt(CCOperation(op), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, i.baseAddress, d.baseAddress, data.count, o.baseAddress, outCap, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw op == kCCEncrypt ? CryptoError.encryptFailed : CryptoError.decryptFailed }
        out.count = moved
        return out
    }

    public static func aesEncrypt(_ data: Data, key: Data, iv: Data) throws -> Data { try aesCBC(kCCEncrypt, data, key: key, iv: iv) }
    public static func aesDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data { try aesCBC(kCCDecrypt, data, key: key, iv: iv) }

    public static func hmacSHA256(_ data: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public static func hmac(_ alg: String, _ data: Data, key: Data) -> Data {
        let k = SymmetricKey(data: key)
        switch alg {
        case "SHA256": return Data(HMAC<SHA256>.authenticationCode(for: data, using: k))
        case "SHA512": return Data(HMAC<SHA512>.authenticationCode(for: data, using: k))
        default: return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: k))
        }
    }

    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    public static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }

    public static func pbkdf2(password: Data, salt: Data, iterations: Int, length: Int = 32) throws -> Data {
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { o in
            password.withUnsafeBytes { p in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         p.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         o.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.kdf }
        return out
    }

    public static func hkdfExpand(prk: Data, info: String, length: Int) -> Data {
        HKDF<SHA256>.expand(pseudoRandomKey: SymmetricKey(data: prk), info: Data(info.utf8), outputByteCount: length)
            .withUnsafeBytes { Data($0) }
    }

    public static func hkdf(ikm: Data, salt: String, info: String, length: Int) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: length)
            .withUnsafeBytes { Data($0) }
    }

    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        let x = [UInt8](a), y = [UInt8](b)
        var r: UInt8 = 0
        for i in 0 ..< x.count { r |= x[i] ^ y[i] }
        return r == 0
    }
}

public extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
