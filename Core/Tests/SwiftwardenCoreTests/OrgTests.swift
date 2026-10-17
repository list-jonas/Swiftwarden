import Foundation
@testable import SwiftwardenCore
import XCTest

final class OrgTests: XCTestCase {
    func testOrganizationRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["SW_SEED_EMAIL"], let pw = env["SW_SEED_PASSWORD"] else { throw XCTSkip("seed off") }
        let api = APIClient(env: .selfHosted(env["SW_IT_SERVER"] ?? "http://localhost:8787"), deviceId: UUID().uuidString)
        let pre = try await api.prelogin(email: email)
        let s = try await VaultService.login(api: api, email: email, password: pw, kdf: pre.config)
        let svc = VaultService(api: api, keys: KeyRing(userKey: s.userKey))
        var v = try svc.decryptVault(try await svc.fetchSync())
        if v.organizations.isEmpty {
            let orgKey = SymmetricCryptoKey.generate()
            let pub = try RSA.publicSPKI(of: XCTUnwrap(svc.keys.privateKey))
            let rsa = try RSA.generate()
            let body: [String: JSONValue] = [
                "name": .string("SimpliServ"), "billingEmail": .string(email), "planType": .number(0),
                "key": .string(try RSA.encrypt(orgKey.data, publicKey: RSA.publicKey(der: pub)).description),
                "collectionName": .string(try EncString.encrypt("Infrastructure", key: orgKey).description),
                "keys": .object(["publicKey": .string(rsa.publicSPKI.base64EncodedString()),
                                 "encryptedPrivateKey": .string(try EncString.encrypt(rsa.privatePKCS8, key: orgKey).description)]),
            ]
            _ = try await api.raw("POST", "/organizations", body: try JSON.encoder.encode(body))
            v = try svc.decryptVault(try await svc.fetchSync())
        }
        let org = try XCTUnwrap(v.organizations.first)
        XCTAssertEqual(org.name, "SimpliServ")
        XCTAssertNotNil(svc.keys.orgKeys[org.id])
        let col = try XCTUnwrap(v.collections.first { $0.organizationId == org.id })
        XCTAssertEqual(col.name, "Infrastructure")
        var c = Cipher(type: .login)
        c.organizationId = org.id
        c.name = "Shared Router"; c.login?.username = "admin"; c.login?.password = "shared-pw"
        c.login?.uris = [LoginUri(uri: "https://router.local")]
        let saved = try await svc.save(c, collectionIds: [col.id])
        XCTAssertEqual(saved.login?.password, "shared-pw")
        let mine = try XCTUnwrap(v.ciphers.first { $0.name == "Fiskaly" })
        let shared = try await svc.share(mine, organizationId: org.id, collectionIds: [col.id])
        XCTAssertEqual(shared.organizationId, org.id)
        let v2 = try svc.decryptVault(try await svc.fetchSync())
        XCTAssertEqual(v2.ciphers.first { $0.name == "Shared Router" }?.login?.password, "shared-pw")
        XCTAssertEqual(v2.ciphers.first { $0.name == "Fiskaly" }?.organizationId, org.id)
        XCTAssertEqual(v2.ciphers.first { $0.name == "Fiskaly" }?.collectionIds, [col.id])
    }
}
