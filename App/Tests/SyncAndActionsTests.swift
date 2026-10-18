import Foundation
import SwiftwardenCore
import XCTest

final class SyncAndActionsTests: AppTestCase {
    let userKey = SymmetricCryptoKey.generate()

    override func tearDown() async throws {
        AppModel.pwnedConfiguration = { .ephemeral }
        StubURLProtocol.handler = nil
        beginHealthScan()
        model.computeHealth()
        await healthScanFinished()
        try await super.tearDown()
    }

    func tokens(refresh: String?) -> Tokens {
        var o: [String: Any] = ["access": "a", "expires": Date().addingTimeInterval(3600).timeIntervalSinceReferenceDate]
        o["refresh"] = refresh
        return try! JSONDecoder().decode(Tokens.self, from: json(o))
    }

    func connect(refresh: String? = "r") {
        let env = ServerEnvironment.selfHosted("https://vault.test")
        let acc = StoredAccount(userId: "u", email: "a@b.c", env: env, kdf: KdfConfig(type: 0, iterations: 5000), protectedUserKey: "stale-key")
        model.account = acc
        Store.save(acc)
        let api = APIClient(env: env, deviceId: "d", tokens: tokens(refresh: refresh), configuration: StubURLProtocol.configuration())
        model.service = VaultService(api: api, keys: KeyRing(userKey: userKey))
        model.phase = .unlocked
    }

    func syncBody(_ names: [String]) throws -> Data {
        let ciphers = try names.enumerated().map { i, n in
            ["id": "c\(i)", "type": 1, "name": try EncString.encrypt(n, key: userKey).description] as [String: Any]
        }
        return json(["profile": ["id": "u", "email": "a@b.c", "key": "rotated-key"], "ciphers": ciphers])
    }

    func echo(_ r: StubURLProtocol.Recorded, id: String) -> (Int, Data) {
        var o = r.json
        o["id"] = id
        o["revisionDate"] = "2026-05-01T00:00:00Z"
        return (200, json(o))
    }

    func testSyncUpdatesVaultCacheAndRotatedKey() async throws {
        connect()
        final class Server: @unchecked Sendable { var body = Data(); var revision = "100" }
        let server = Server()
        server.body = try syncBody(["One"])
        StubURLProtocol.handler = { r in r.line.hasSuffix("/revision-date") ? (200, Data(server.revision.utf8)) : (200, server.body) }

        await model.sync()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.ciphers.map(\.name), ["One"])
        XCTAssertEqual(try Data(contentsOf: Paths.syncCache), server.body)
        XCTAssertEqual(Store.loadAccount()?.protectedUserKey, "rotated-key")
        XCTAssertNotNil(Store.loadAccount()?.lastSync)

        StubURLProtocol.clearLog()
        await model.syncIfChanged()
        XCTAssertEqual(StubURLProtocol.log.map(\.line), ["GET /api/accounts/revision-date"])

        server.body = try syncBody(["One", "Two"])
        server.revision = "200"
        await model.syncIfChanged()
        XCTAssertEqual(model.ciphers.map(\.name), ["One", "Two"])
    }

    func testSyncFailuresAreExplained() async {
        connect(refresh: nil)
        StubURLProtocol.handler = { _ in (401, Data()) }
        await model.sync()
        XCTAssertEqual(model.errorMessage, "Session expired. Log out and log in again to sync.")
        StubURLProtocol.handler = { _ in (500, Data()) }
        await model.sync()
        XCTAssertEqual(model.errorMessage, "Sync failed: Server error (500)")
        XCTAssertFalse(model.syncing)
    }

    func testItemActionsUpdateTheList() async {
        connect()
        StubURLProtocol.handler = { _ in (200, Data()) }
        model.ciphers = [item("a", "Alpha", pw: "x"), item("b", "Beta", deleted: true), item("c", "Gamma", deleted: true)]
        model.selectedId = "b"

        model.trash(model.cipher("a")!)
        await waitUntil { self.model.cipher("a")?.isDeleted == true }
        model.restore(model.cipher("a")!)
        await waitUntil { self.model.cipher("a")?.isDeleted == false }
        model.toggleFavorite(model.cipher("a")!)
        await waitUntil { self.model.cipher("a")?.isFavorite == true }
        model.move(model.cipher("a")!, toFolder: "f1")
        await waitUntil { self.model.cipher("a")?.folderId == "f1" }
        model.trash(model.cipher("b")!)
        await waitUntil { self.model.cipher("b") == nil }
        XCTAssertNil(model.selectedId)
        model.emptyTrash()
        await waitUntil { self.model.cipher("c") == nil }

        XCTAssertEqual(StubURLProtocol.log.map(\.line), ["PUT /api/ciphers/a/delete", "PUT /api/ciphers/a/restore", "PUT /api/ciphers/a/partial",
                                                        "PUT /api/ciphers/a/partial", "DELETE /api/ciphers/b", "DELETE /api/ciphers/c"])
        XCTAssertEqual(StubURLProtocol.log[2].json["favorite"] as? Bool, true)
        XCTAssertEqual(StubURLProtocol.log[3].json["folderId"] as? String, "f1")
        XCTAssertEqual(StubURLProtocol.log[3].json["favorite"] as? Bool, true)
        XCTAssertEqual(model.ciphers.map(\.id), ["a"])

        StubURLProtocol.handler = { _ in (500, Data()) }
        model.errorMessage = nil
        model.trash(model.cipher("a")!)
        await waitUntil { self.model.errorMessage != nil }
        XCTAssertEqual(model.errorMessage, "Delete failed: Server error (500)")
        XCTAssertFalse(model.cipher("a")!.isDeleted)
    }

    func testSavingKeepsOldPasswordInHistory() async throws {
        connect()
        StubURLProtocol.handler = { r in self.echo(r, id: r.line == "POST /api/ciphers" ? "new" : "a") }
        model.ciphers = [item("a", "GitHub", pw: "old-pw")]
        var edited = model.cipher("a")!
        edited.login?.password = "new-pw"
        let saved = try await model.save(edited)
        XCTAssertEqual(saved.passwordHistory?.first?.password, "old-pw")
        XCTAssertEqual(model.cipher("a")?.login?.password, "new-pw")
        let sent = try XCTUnwrap((StubURLProtocol.log.first?.json["passwordHistory"] as? [[String: Any]])?.first?["password"] as? String)
        XCTAssertEqual(try EncString(sent).decryptString(key: userKey), "old-pw")

        let created = try await model.save(item("", "New", pw: "pw"))
        XCTAssertEqual(StubURLProtocol.log.last?.line, "POST /api/ciphers")
        XCTAssertNil(created.passwordHistory?.first)
        XCTAssertEqual(model.ciphers.count, 2)

        model.service = nil
        await assertThrows(try await model.save(edited))
    }

    func testLeakCheckSendsOnlyHashPrefixes() async {
        AppModel.pwnedConfiguration = { StubURLProtocol.configuration() }
        StubURLProtocol.handler = { r in
            r.request.url?.lastPathComponent == "F3BBB"
                ? (200, Data("0018A45C4D1DEF81644B54AB7F969B88D65:1\r\nD66A63D4BF1747940578EC3D0103530E21D:2844\r\n".utf8))
                : (200, Data("0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n".utf8))
        }
        model.ciphers = [item("a", "A", pw: "hunter2"), item("b", "B", pw: "hunter2"), item("c", "C", pw: "Xk3!vQ9#mZ2rT8wL"),
                         item("d", "D", pw: "hunter2", deleted: true), item("e", "E")]
        await model.checkExposed()
        XCTAssertEqual(model.health.exposed, ["a": 2844, "b": 2844])
        XCTAssertTrue(model.health.exposedChecked)
        XCTAssertFalse(model.checkingExposed)
        let urls = StubURLProtocol.log.compactMap { $0.request.url?.absoluteString }
        XCTAssertEqual(urls.count, 2)
        for u in urls {
            XCTAssertTrue(u.hasPrefix("https://api.pwnedpasswords.com/range/"))
            XCTAssertEqual(URL(string: u)?.lastPathComponent.count, 5)
            XCTAssertFalse(u.contains("hunter2"))
        }
        XCTAssertEqual(model.issues(model.cipher("a")!).first, .exposed(2844))
    }
}
