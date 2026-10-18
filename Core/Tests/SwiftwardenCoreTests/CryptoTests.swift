import Foundation
import Security
@testable import SwiftwardenCore
import XCTest

final class CryptoTests: XCTestCase {
    func testBlake2b() {
        let h = Blake2b.hash(Array("abc".utf8), outLen: 64)
        XCTAssertEqual(Data(h).hex, "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
    }

    func testArgon2idRFC9106() {
        let out = Argon2id.hash(password: [UInt8](repeating: 1, count: 32), salt: [UInt8](repeating: 2, count: 16), iterations: 3,
                                memoryKiB: 32, parallelism: 4, outLen: 32, secret: [UInt8](repeating: 3, count: 8), ad: [UInt8](repeating: 4, count: 12))
        XCTAssertEqual(Data(out).hex, "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    }

    func testPBKDF2Vector() throws {
        let d = try Primitives.pbkdf2(password: Data("password".utf8), salt: Data("salt".utf8), iterations: 1, length: 32)
        XCTAssertEqual(d.hex, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    func testEncStringRoundTrip() throws {
        let k = SymmetricCryptoKey.generate()
        let e = try EncString.encrypt("hello wörld", key: k)
        let parsed = try EncString(e.description)
        XCTAssertEqual(try parsed.decryptString(key: k), "hello wörld")
        XCTAssertThrowsError(try parsed.decryptString(key: .generate()))
    }

    func testEncStringParsesServerWireFormats() throws {
        let a = Data([1, 2, 3]).base64EncodedString(), b = Data([4, 5]).base64EncodedString(), c = Data([6]).base64EncodedString()
        let legacy = try EncString("\(a)|\(b)|\(c)")
        XCTAssertEqual(legacy.type, 1)
        XCTAssertEqual(legacy.mac, Data([6]))
        XCTAssertEqual(try EncString("0.\(a)|\(b)").iv, Data([1, 2, 3]))
        let rsa = try EncString("4.\(a)")
        XCTAssertNil(rsa.iv)
        XCTAssertEqual(rsa.data, Data([1, 2, 3]))
        XCTAssertEqual(try EncString("6.\(a)|\(b)").mac, Data([4, 5]))
        for s in ["2.\(a)|\(b)|\(c)", "0.\(a)|\(b)", "3.\(a)", "6.\(a)|\(b)"] {
            XCTAssertEqual(try EncString(s).description, s)
        }
        for bad in ["9.\(a)|\(b)", "2.\(a)|\(b)", "2.!!|\(b)|\(c)", "0.\(a)", "5.\(a)"] {
            XCTAssertThrowsError(try EncString(bad), bad)
        }
    }

    func testRejectsMacStrippedEncString() throws {
        let k = SymmetricCryptoKey.generate()
        let e = try EncString.encrypt("secret", key: k)
        XCTAssertThrowsError(try EncString(type: 0, iv: e.iv, data: e.data, mac: nil).decrypt(key: k))
    }

    func testLegacyUnauthenticatedUserKeyStillUnlocks() throws {
        let masterKey = Primitives.random(32), userKey = SymmetricCryptoKey.generate(), iv = Primitives.random(16)
        let ct = try Primitives.aesEncrypt(userKey.data, key: masterKey, iv: iv)
        let protected = EncString(type: 0, iv: iv, data: ct, mac: nil).description
        XCTAssertEqual(try KeyDerivation.decryptUserKey(protected, with: masterKey), userKey)
    }

    func testEncryptedFileFormat() throws {
        let k = SymmetricCryptoKey.generate()
        let blob = try EncFile.encrypt(Data("attachment".utf8), key: k)
        XCTAssertEqual(blob.first, 2)
        XCTAssertEqual(try EncFile.decrypt(blob, key: k), Data("attachment".utf8))
        var tampered = blob
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try EncFile.decrypt(tampered, key: k))
        XCTAssertThrowsError(try EncFile.decrypt(Data([1]) + blob.dropFirst(), key: k))
        XCTAssertThrowsError(try EncFile.decrypt(blob, key: SymmetricCryptoKey(Primitives.random(32))))
    }

    func testSymmetricKeyRejectsWrongLength() {
        XCTAssertThrowsError(try SymmetricCryptoKey(Primitives.random(48)))
        XCTAssertThrowsError(try EncString.encrypt("x", key: SymmetricCryptoKey(Primitives.random(32))))
    }

    func testRSAKeysAndBothOAEPVariants() throws {
        let kp = try RSA.generate()
        let priv = try RSA.privateKey(der: kp.privatePKCS8)
        let pub = try RSA.publicKey(der: kp.publicSPKI)
        let e = try RSA.encrypt(Data("secret".utf8), publicKey: pub)
        XCTAssertEqual(try RSA.decrypt(EncString(e.description), privateKey: priv), Data("secret".utf8))
        XCTAssertEqual(try RSA.publicSPKI(of: priv), kp.publicSPKI)

        let sha256 = try XCTUnwrap(SecKeyCreateEncryptedData(pub, .rsaEncryptionOAEPSHA256, Data("org".utf8) as CFData, nil) as Data?)
        XCTAssertEqual(try RSA.decrypt(EncString(type: 3, iv: nil, data: sha256, mac: nil), privateKey: priv), Data("org".utf8))
        XCTAssertThrowsError(try RSA.decrypt(EncString.encrypt("x", key: .generate()), privateKey: priv))
        XCTAssertThrowsError(try RSA.privateKey(der: Data([0x30, 0x01, 0x00])))
        XCTAssertThrowsError(try RSA.publicKey(der: Data("nope".utf8)))
    }

    func testRejectsUnsafeKdf() {
        XCTAssertThrowsError(try KeyDerivation.deriveKey(secret: "pw", salt: "s", kdf: KdfConfig(type: 0, iterations: 1)))
        XCTAssertThrowsError(try KeyDerivation.deriveKey(secret: "pw", salt: "s", kdf: KdfConfig(type: 1, iterations: 1, memory: 1, parallelism: 0)))
        XCTAssertThrowsError(try KeyDerivation.deriveKey(secret: "pw", salt: "s", kdf: KdfConfig(type: 7, iterations: 600_000)))
        XCTAssertNoThrow(try KdfConfig.argon2Default.validate())
        XCTAssertNoThrow(try KdfConfig.pbkdf2Default.validate())
    }

    func testFingerprintPhraseDependsOnUserAndKey() {
        let key = Data((0 ..< 32).map { UInt8($0) })
        let p = Fingerprint.phrase(userId: "user-1", publicKey: key)
        let words = p.split(separator: "-").map(String.init)
        XCTAssertEqual(words.count, 5)
        XCTAssertTrue(words.allSatisfy(Fingerprint.wordlist.contains))
        XCTAssertEqual(p, Fingerprint.phrase(userId: "user-1", publicKey: key))
        XCTAssertNotEqual(p, Fingerprint.phrase(userId: "user-2", publicKey: key))
        XCTAssertNotEqual(p, Fingerprint.phrase(userId: "user-1", publicKey: key + Data([0])))
    }

    func testBase64URL() {
        let d = Data([0xfb, 0xff, 0xfe, 0x01])
        XCTAssertEqual(d.base64URL, "-__-AQ")
        XCTAssertEqual(Data(base64URL: "-__-AQ"), d)
    }
}
