import Foundation
@testable import SwiftwardenCore
import XCTest

final class IntegrationTests: XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }

    func makeService(_ email: String, _ pw: String) async throws -> (VaultService, DecryptedVault) {
        let api = APIClient(env: .selfHosted(env["SW_IT_SERVER"] ?? "http://localhost:8787"), deviceId: UUID().uuidString)
        let pre = try await api.prelogin(email: email)
        let s = try await VaultService.login(api: api, email: email, password: pw, kdf: pre.config)
        let svc = VaultService(api: api, keys: KeyRing(userKey: s.userKey))
        let v = try svc.decryptVault(try await svc.fetchSync())
        return (svc, v)
    }

    func testPhase1RegisterAndWrite() async throws {
        guard let email = env["SW_IT_EMAIL"], env["SW_IT_PHASE"] == "1" else { throw XCTSkip("integration off") }
        let pw = env["SW_IT_PASSWORD"]!
        let api = APIClient(env: .selfHosted(env["SW_IT_SERVER"] ?? "http://localhost:8787"), deviceId: UUID().uuidString)
        try await VaultService.register(api: api, email: email, name: "IT", password: pw, hint: "",
                                        kdf: KdfConfig(type: 1, iterations: 3, memory: 16, parallelism: 4))
        let (svc, v) = try await makeService(email, pw)
        XCTAssertEqual(v.ciphers.count, 0)
        XCTAssertNotNil(svc.fingerprintPhrase())
        let folder = try await svc.saveFolder(id: nil, name: "Work")
        var c = Cipher(type: .login)
        c.name = "Swift Item"; c.folderId = folder.id
        c.login?.username = "swift@user"; c.login?.password = "s3cr3t-Pa55"
        c.login?.uris = [LoginUri(uri: "https://example.com")]
        c.login?.totp = "JBSWY3DPEHPK3PXP"
        c.fields = [Field(name: "pin", value: "1234", type: .hidden)]
        c.notes = "multi\nline"
        let saved = try await svc.save(c)
        XCTAssertEqual(saved.login?.password, "s3cr3t-Pa55")
        var edited = saved
        edited.login?.password = "new-pass"
        edited.recordHistory(from: saved)
        let saved2 = try await svc.save(edited)
        XCTAssertEqual(saved2.passwordHistory?.first?.password, "s3cr3t-Pa55")
        try await svc.uploadAttachment(cipher: saved2, fileName: "hello.txt", data: Data("attachment body".utf8))
        var s = Send(type: 0)
        s.name = "Swift Send"; s.text = SendText(text: "send text", hidden: false)
        s.deletionDate = Dates.string(Date().addingTimeInterval(86400))
        let ss = try await svc.saveSend(s, newPassword: nil)
        XCTAssertEqual(ss.text?.text, "send text")
        print("SENDLINK", svc.sendLink(ss))
        let v2 = try svc.decryptVault(try await svc.fetchSync())
        let item = try XCTUnwrap(v2.ciphers.first { $0.name == "Swift Item" })
        XCTAssertEqual(item.attachments?.first?.fileName, "hello.txt")
        let body = try await svc.downloadAttachment(cipher: item, attachment: item.attachments!.first!)
        XCTAssertEqual(String(data: body, encoding: .utf8), "attachment body")
    }

    func testPhase2ReadForeign() async throws {
        guard let email = env["SW_IT_EMAIL"], env["SW_IT_PHASE"] == "2" else { throw XCTSkip("integration off") }
        let (svc, v) = try await makeService(email, env["SW_IT_PASSWORD"]!)
        let cli = try XCTUnwrap(v.ciphers.first { $0.name == "CLI Item" })
        XCTAssertEqual(cli.login?.password, "cli-pass")
        XCTAssertEqual(cli.login?.username, "cli@user")
        let card = try XCTUnwrap(v.ciphers.first { $0.type == .card })
        XCTAssertEqual(card.card?.number, "4111111111111111")
        let r = try Importer.detect(Data("name,url,username,password\nImp,https://imp.com,iu,ip\n".utf8))
        try await svc.importVault(ciphers: r.ciphers, folders: ["Imported"], relations: [(0, 0)])
        let tr = try XCTUnwrap(v.ciphers.first { $0.name == "Swift Item" })
        try await svc.trash(tr.id)
        let v2 = try svc.decryptVault(try await svc.fetchSync())
        XCTAssertNotNil(v2.ciphers.first { $0.name == "Imp" })
        XCTAssertNotNil(v2.ciphers.first { $0.name == "Swift Item" }?.deletedDate)
        try await svc.restore(tr.id)
    }
}
