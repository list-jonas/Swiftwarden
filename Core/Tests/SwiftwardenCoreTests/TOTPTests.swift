@testable import SwiftwardenCore
import XCTest

final class TOTPTests: XCTestCase {
    func t(_ s: String) throws -> TOTP { try XCTUnwrap(TOTP(s)) }

    func testRFC6238Vectors() throws {
        let sha1 = try t("otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8")
        XCTAssertEqual(sha1.code(at: Date(timeIntervalSince1970: 59)), "94287082")
        XCTAssertEqual(sha1.code(at: Date(timeIntervalSince1970: 1_111_111_109)), "07081804")
        let sha256 = try t("otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA&digits=8&algorithm=sha256")
        XCTAssertEqual(sha256.code(at: Date(timeIntervalSince1970: 59)), "46119246")
        let sha512 = try t("otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA&digits=8&algorithm=SHA512")
        XCTAssertEqual(sha512.code(at: Date(timeIntervalSince1970: 59)), "90693936")
    }

    func testBareSecretsAndFormatting() throws {
        XCTAssertEqual(try t("gezd gnbv-gy3t qojq gezd gnbv gy3t qojq").code(at: Date(timeIntervalSince1970: 1_111_111_109)), "081804")
        XCTAssertNil(TOTP("not base32!"))
        XCTAssertNil(TOTP(""))
        XCTAssertEqual(try t("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=12").code().count, 10)
    }

    func testPeriod() throws {
        let o = try t("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&period=60")
        XCTAssertEqual(o.remaining(at: Date(timeIntervalSince1970: 61)), 59)
        XCTAssertEqual(o.code(at: Date(timeIntervalSince1970: 60)), o.code(at: Date(timeIntervalSince1970: 119)))
        XCTAssertNotEqual(o.code(at: Date(timeIntervalSince1970: 60)), o.code(at: Date(timeIntervalSince1970: 120)))
    }

    func testSteamGuard() throws {
        let alphabet = Set("23456789BCDFGHJKMNPQRTVWXY")
        for uri in ["steam://JBSWY3DPEHPK3PXP", "otpauth://totp/Steam:me?secret=JBSWY3DPEHPK3PXP&encoder=steam&digits=8",
                    "otpauth://steam/me?secret=JBSWY3DPEHPK3PXP"] {
            let o = try t(uri)
            let code = o.code(at: Date(timeIntervalSince1970: 1_700_000_000))
            XCTAssertEqual(code.count, 5, uri)
            XCTAssertTrue(code.allSatisfy(alphabet.contains), uri)
            XCTAssertEqual(code, try t("steam://JBSWY3DPEHPK3PXP").code(at: Date(timeIntervalSince1970: 1_700_000_000)))
        }
    }
}
