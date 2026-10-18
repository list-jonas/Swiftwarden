@testable import SwiftwardenCore
import XCTest

final class GeneratorTests: XCTestCase {
    func testPasswordHonorsOptions() {
        for _ in 0 ..< 50 {
            var o = PasswordOptions()
            o.length = 20; o.special = true; o.minNumbers = 4; o.minSpecial = 3
            let p = Generator.password(o)
            XCTAssertEqual(p.count, 20)
            XCTAssertGreaterThanOrEqual(p.filter(\.isNumber).count, 4)
            XCTAssertGreaterThanOrEqual(p.filter { "!@#$%^&*".contains($0) }.count, 3)
            XCTAssertTrue(p.contains(where: \.isUppercase) && p.contains(where: \.isLowercase))

            var amb = PasswordOptions()
            amb.length = 64; amb.avoidAmbiguous = true
            XCTAssertFalse(Generator.password(amb).contains { "0O1lI".contains($0) })

            var digits = PasswordOptions()
            digits.uppercase = false; digits.lowercase = false; digits.length = 8
            XCTAssertTrue(Generator.password(digits).allSatisfy(\.isNumber))
        }
    }

    func testPasswordNeverShorterThanItsRules() {
        var o = PasswordOptions()
        o.length = 1; o.special = true; o.minNumbers = 4; o.minSpecial = 3
        XCTAssertEqual(Generator.password(o).count, 9)
        var none = PasswordOptions()
        none.uppercase = false; none.lowercase = false; none.numbers = false; none.length = 3
        let p = Generator.password(none)
        XCTAssertEqual(p.count, 5)
        XCTAssertTrue(p.allSatisfy(\.isLowercase))
    }

    func testPassphraseOptions() {
        XCTAssertEqual(Generator.passphrase(PassphraseOptions()).split(separator: "-").count, 6)
        var o = PassphraseOptions()
        o.words = 1; o.separator = "_"; o.capitalize = true; o.includeNumber = true
        let p = Generator.passphrase(o)
        let words = p.split(separator: "_")
        XCTAssertEqual(words.count, 3)
        XCTAssertTrue(words.allSatisfy { $0.first!.isUppercase })
        XCTAssertEqual(p.filter(\.isNumber).count, 1)
        let w = Generator.randomWord(capitalize: true, includeNumber: true)
        XCTAssertTrue(w.first!.isUppercase)
        XCTAssertTrue(w.suffix(4).allSatisfy(\.isNumber))
    }

    func testEmailAliases() {
        let plus = Generator.plusAddressed("me@example.com")
        XCTAssertTrue(plus.hasPrefix("me+") && plus.hasSuffix("@example.com"))
        XCTAssertEqual(plus.count, "me+12345678@example.com".count)
        XCTAssertEqual(Generator.plusAddressed("not-an-email"), "not-an-email")
        let catchAll = Generator.catchAll(" @example.com ")
        XCTAssertTrue(catchAll.hasSuffix("@example.com"))
        XCTAssertEqual(catchAll.split(separator: "@").first?.count, 8)
    }

    func testStrength() {
        XCTAssertTrue(PasswordStrength.isWeak(""))
        XCTAssertTrue(PasswordStrength.isWeak("Password123!"))
        XCTAssertTrue(PasswordStrength.isWeak("P@ssw0rd"))
        XCTAssertTrue(PasswordStrength.isWeak("aaaaaaaa"))
        XCTAssertTrue(PasswordStrength.isWeak("qwertyuiop12345"))
        XCTAssertTrue(PasswordStrength.isWeak("abcdefghijklmnop"))
        XCTAssertFalse(PasswordStrength.isWeak("correct-horse-battery-staple-xyz"))
        XCTAssertFalse(PasswordStrength.isWeak(Generator.password(PasswordOptions())))
        XCTAssertEqual(PasswordStrength.score(Generator.password({ var o = PasswordOptions(); o.length = 24; o.special = true; return o }())), 4)
    }

    func testStrengthPenalizesPersonalInfo() {
        let pw = "jonaslist#77"
        XCTAssertFalse(PasswordStrength.isWeak(pw))
        XCTAssertTrue(PasswordStrength.isWeak(pw, userInputs: ["JonasList"]))
        XCTAssertFalse(PasswordStrength.isWeak(pw, userInputs: ["jo"]))
    }
}
