import Foundation
@testable import SwiftwardenCore
import XCTest

final class PerformanceTests: XCTestCase {
    static func makeVault(_ n: Int, key: SymmetricCryptoKey) throws -> Data {
        func e(_ s: String) throws -> String { try EncString.encrypt(s, key: key).description }
        var ciphers: [[String: Any]] = []
        for i in 0 ..< n {
            ciphers.append([
                "id": UUID().uuidString, "type": 1, "name": try e("Site \(i)"), "notes": try e("note \(i)"),
                "favorite": i % 10 == 0, "revisionDate": "2026-01-01T00:00:00Z",
                "login": ["username": try e("user\(i)@example.com"), "password": try e(i % 7 == 0 ? "password\(i % 3)" : "Xk3!vQ9#mZ\(i)rT"),
                          "uris": [["uri": try e("https://site\(i).example.com"), "match": NSNull()]]],
                "fields": [["name": try e("pin"), "value": try e("1234"), "type": 1]],
            ])
        }
        let root: [String: Any] = ["profile": ["id": "u", "email": "a@b.c", "key": "x"], "folders": [], "collections": [], "ciphers": ciphers]
        return try JSONSerialization.data(withJSONObject: root)
    }

    func testLargeVault() throws {
        guard ProcessInfo.processInfo.environment["SW_PERF"] != nil else { throw XCTSkip("perf off") }
        let key = SymmetricCryptoKey.generate()
        let n = 5000
        let data = try Self.makeVault(n, key: key)
        let svc = VaultService(api: APIClient(env: .us, deviceId: "x"), keys: KeyRing(userKey: key))
        var t = Date()
        let v = try svc.decryptVault(data)
        let decrypt = Date().timeIntervalSince(t)
        XCTAssertEqual(v.ciphers.count, n)
        t = Date()
        var weak = 0
        for c in v.ciphers where PasswordStrength.isWeak(c.login?.password ?? "", userInputs: ["user"]) { weak += 1 }
        let health = Date().timeIntervalSince(t)
        print(String(format: "PERF items=%d json=%.1fMB decrypt=%.0fms strength=%.0fms weak=%d", n, Double(data.count) / 1e6, decrypt * 1000, health * 1000, weak))
    }
}
