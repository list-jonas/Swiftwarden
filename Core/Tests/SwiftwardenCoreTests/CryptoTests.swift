import Foundation
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

    func testEncStringRoundTrip() throws {
        let k = SymmetricCryptoKey.generate()
        let e = try EncString.encrypt("hello wörld", key: k)
        let parsed = try EncString(e.description)
        XCTAssertEqual(try parsed.decryptString(key: k), "hello wörld")
        XCTAssertThrowsError(try parsed.decryptString(key: .generate()))
    }

    func testPBKDF2Vector() throws {
        let d = try Primitives.pbkdf2(password: Data("password".utf8), salt: Data("salt".utf8), iterations: 1, length: 32)
        XCTAssertEqual(d.hex, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    func testRSARoundTrip() throws {
        let kp = try RSA.generate()
        let priv = try RSA.privateKey(der: kp.privatePKCS8)
        let pub = try RSA.publicKey(der: kp.publicSPKI)
        let e = try RSA.encrypt(Data("secret".utf8), publicKey: pub)
        XCTAssertEqual(try RSA.decrypt(EncString(e.description), privateKey: priv), Data("secret".utf8))
        XCTAssertEqual(try RSA.publicSPKI(of: priv), kp.publicSPKI)
    }

    func testTOTP() throws {
        let t = try XCTUnwrap(TOTP("otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8"))
        XCTAssertEqual(t.code(at: Date(timeIntervalSince1970: 59)), "94287082")
        XCTAssertEqual(TOTP("GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ")?.code(at: Date(timeIntervalSince1970: 1111111109)), "081804")
    }

    func testGeneratorAndStrength() {
        var o = PasswordOptions(); o.length = 20; o.special = true
        let p = Generator.password(o)
        XCTAssertEqual(p.count, 20)
        XCTAssertTrue(p.contains(where: \.isNumber))
        XCTAssertEqual(Generator.passphrase(PassphraseOptions()).split(separator: "-").count, 6)
        XCTAssertTrue(PasswordStrength.isWeak("Password123!"))
        XCTAssertTrue(PasswordStrength.isWeak("aaaaaaaa"))
        XCTAssertFalse(PasswordStrength.isWeak(p))
        XCTAssertFalse(PasswordStrength.isWeak("correct-horse-battery-staple-xyz"))
    }

    func testURLMatching() {
        XCTAssertTrue(URLMatcher.matches(LoginUri(uri: "https://accounts.google.com"), url: "https://mail.google.com/x"))
        XCTAssertFalse(URLMatcher.matches(LoginUri(uri: "https://google.com", match: .host), url: "https://mail.google.com"))
        XCTAssertEqual(URLMatcher.baseDomain("a.b.example.co.uk"), "example.co.uk")
        XCTAssertTrue(URLMatcher.matchesApp(LoginUri(uri: "https://slack.com"), bundleId: "com.tinyspeck.slackmacgap", appName: "Slack"))
    }

    func testCSV() throws {
        let r = try Importer.detect(Data("name,url,username,password,note\n\"A, B\",https://a.com,u,\"p\"\"q\",\"line1\nline2\"\n".utf8))
        XCTAssertEqual(r.ciphers.count, 1)
        XCTAssertEqual(r.ciphers[0].name, "A, B")
        XCTAssertEqual(r.ciphers[0].login?.password, "p\"q")
        XCTAssertEqual(r.ciphers[0].notes, "line1\nline2")
    }

    func testEncryptedExportRoundTrip() throws {
        var c = Cipher(type: .login); c.name = "x"; c.login?.password = "pw"
        let d = try Exporter.encryptedJSON(ciphers: [c], folders: [], password: "filepw", kdf: KdfConfig(type: 0, iterations: 5000))
        XCTAssertTrue(Importer.needsPassword(d))
        XCTAssertEqual(try Importer.detect(d, password: "filepw").ciphers.first?.login?.password, "pw")
        XCTAssertThrowsError(try Importer.detect(d, password: "nope"))
    }

    func testPublicSuffixMatching() {
        XCTAssertFalse(URLMatcher.matches(LoginUri(uri: "https://alice.github.io"), url: "https://evil.github.io"))
        XCTAssertFalse(URLMatcher.matches(LoginUri(uri: "https://bank.com.ua"), url: "https://evil.com.ua"))
        XCTAssertTrue(URLMatcher.matches(LoginUri(uri: "https://login.bank.com.ua"), url: "https://www.bank.com.ua"))
        XCTAssertEqual(URLMatcher.baseDomain("www.city.kawasaki.jp"), "city.kawasaki.jp")
        XCTAssertEqual(URLMatcher.baseDomain("a.b.kawasaki.jp"), "a.b.kawasaki.jp")
        XCTAssertEqual(URLMatcher.baseDomain("github.io"), "github.io")
    }

    func testLaunchURLSchemes() {
        XCTAssertNotNil(URLMatcher.launchURL("example.com/login"))
        XCTAssertNil(URLMatcher.launchURL("file:///Applications/Calculator.app"))
        XCTAssertNil(URLMatcher.launchURL("smb://attacker/share"))
    }

    func testRejectsUnsafeKdf() {
        XCTAssertThrowsError(try KeyDerivation.deriveKey(secret: "pw", salt: "s", kdf: KdfConfig(type: 0, iterations: 1)))
        XCTAssertThrowsError(try KeyDerivation.deriveKey(secret: "pw", salt: "s", kdf: KdfConfig(type: 1, iterations: 1, memory: 1, parallelism: 0)))
        XCTAssertNoThrow(try KdfConfig.argon2Default.validate())
    }

    func testRejectsMacStrippedEncString() throws {
        let k = SymmetricCryptoKey.generate()
        let e = try EncString.encrypt("secret", key: k)
        XCTAssertThrowsError(try EncString(type: 0, iv: e.iv, data: e.data, mac: nil).decrypt(key: k))
    }
}
