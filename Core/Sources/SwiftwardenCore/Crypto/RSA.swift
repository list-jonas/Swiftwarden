import Foundation
import Security

enum DER {
    static func len(_ n: Int) -> [UInt8] {
        if n < 128 { return [UInt8(n)] }
        var b = [UInt8](), v = n
        while v > 0 { b.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return [0x80 | UInt8(b.count)] + b
    }

    static func tlv(_ tag: UInt8, _ c: [UInt8]) -> [UInt8] { [tag] + len(c.count) + c }

    static let rsaAlg: [UInt8] = tlv(0x30, tlv(0x06, [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]) + [0x05, 0x00])

    static func spki(pkcs1: Data) -> Data { Data(tlv(0x30, rsaAlg + tlv(0x03, [0] + [UInt8](pkcs1)))) }
    static func pkcs8(pkcs1: Data) -> Data { Data(tlv(0x30, tlv(0x02, [0]) + rsaAlg + tlv(0x04, [UInt8](pkcs1)))) }

    static func read(_ b: [UInt8], _ i: inout Int) -> (UInt8, Range<Int>)? {
        guard i + 2 <= b.count else { return nil }
        let tag = b[i]; i += 1
        var l = Int(b[i]); i += 1
        if l & 0x80 != 0 {
            let n = l & 0x7f
            guard n <= 4, i + n <= b.count else { return nil }
            l = 0
            for _ in 0 ..< n { l = (l << 8) | Int(b[i]); i += 1 }
        }
        guard i + l <= b.count else { return nil }
        let r = i ..< i + l
        return (tag, r)
    }

    static func unwrapPKCS8(_ d: Data) -> Data? {
        let b = [UInt8](d); var i = 0
        guard let (t, seq) = read(b, &i), t == 0x30 else { return nil }
        i = seq.lowerBound
        guard let (t1, r1) = read(b, &i), t1 == 0x02 else { return nil }
        i = r1.upperBound
        guard let (t2, r2) = read(b, &i), t2 == 0x30 else { return nil }
        i = r2.upperBound
        guard let (t3, r3) = read(b, &i), t3 == 0x04 else { return nil }
        return Data(b[r3])
    }

    static func unwrapSPKI(_ d: Data) -> Data? {
        let b = [UInt8](d); var i = 0
        guard let (t, seq) = read(b, &i), t == 0x30 else { return nil }
        i = seq.lowerBound
        guard let (t1, r1) = read(b, &i), t1 == 0x30 else { return nil }
        i = r1.upperBound
        guard let (t2, r2) = read(b, &i), t2 == 0x03, r2.count > 1 else { return nil }
        return Data(b[(r2.lowerBound + 1) ..< r2.upperBound])
    }
}

public enum RSA {
    public static func privateKey(der: Data) throws -> SecKey {
        let pkcs1 = DER.unwrapPKCS8(der) ?? der
        var err: Unmanaged<CFError>?
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let k = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &err) else {
            throw CryptoError.rsa(err?.takeRetainedValue().localizedDescription ?? "bad private key")
        }
        return k
    }

    public static func publicKey(der: Data) throws -> SecKey {
        let pkcs1 = DER.unwrapSPKI(der) ?? der
        var err: Unmanaged<CFError>?
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let k = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &err) else {
            throw CryptoError.rsa(err?.takeRetainedValue().localizedDescription ?? "bad public key")
        }
        return k
    }

    public static func publicSPKI(of privateKey: SecKey) throws -> Data {
        guard let pub = SecKeyCopyPublicKey(privateKey), let raw = SecKeyCopyExternalRepresentation(pub, nil) as Data? else {
            throw CryptoError.rsa("cannot export public key")
        }
        return DER.spki(pkcs1: raw)
    }

    public static func generate() throws -> (privatePKCS8: Data, publicSPKI: Data) {
        var err: Unmanaged<CFError>?
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let k = SecKeyCreateRandomKey(attrs as CFDictionary, &err), let raw = SecKeyCopyExternalRepresentation(k, nil) as Data? else {
            throw CryptoError.rsa("keygen failed")
        }
        return (DER.pkcs8(pkcs1: raw), try publicSPKI(of: k))
    }

    public static func decrypt(_ e: EncString, privateKey: SecKey) throws -> Data {
        let alg: SecKeyAlgorithm
        switch e.type {
        case 3, 5: alg = .rsaEncryptionOAEPSHA256
        case 4, 6: alg = .rsaEncryptionOAEPSHA1
        default: throw CryptoError.invalidEncString
        }
        var err: Unmanaged<CFError>?
        guard let out = SecKeyCreateDecryptedData(privateKey, alg, e.data as CFData, &err) as Data? else {
            throw CryptoError.rsa(err?.takeRetainedValue().localizedDescription ?? "decrypt failed")
        }
        return out
    }

    public static func encrypt(_ data: Data, publicKey: SecKey) throws -> EncString {
        var err: Unmanaged<CFError>?
        guard let out = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA1, data as CFData, &err) as Data? else {
            throw CryptoError.rsa(err?.takeRetainedValue().localizedDescription ?? "encrypt failed")
        }
        return EncString(type: 4, iv: nil, data: out, mac: nil)
    }
}
