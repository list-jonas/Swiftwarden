import Foundation
import SwiftwardenCore
import XCTest

final class LockTests: AppTestCase {
    let password = "master-pw"
    var userKey = SymmetricCryptoKey.generate()

    func signIn() throws {
        let kdf = KdfConfig(type: 0, iterations: 5000)
        let mk = try KeyDerivation.masterKey(password: password, email: "a@b.c", kdf: kdf)
        let acc = StoredAccount(userId: "u-test", email: "a@b.c", env: .selfHosted("http://127.0.0.1:9"), kdf: kdf,
                                protectedUserKey: try KeyDerivation.protectUserKey(userKey, with: mk))
        model.account = acc
        Store.save(acc)
        model.service = VaultService(api: APIClient(env: acc.env, deviceId: "d"), keys: KeyRing(userKey: userKey))
        model.phase = .unlocked
    }

    func testPinIsWipedAfterFiveWrongAttempts() async throws {
        try signIn()
        try await model.setPIN("4711", requireMasterOnRestart: false)
        XCTAssertNotNil(Store.loadAccount()?.pinProtectedUserKey)
        model.ciphers = [item("a", "x")]
        model.lock()
        XCTAssertEqual(model.phase, .locked)
        XCTAssertNil(model.service)
        XCTAssertTrue(model.ciphers.isEmpty)

        for i in 1 ... 4 {
            await assertThrows(try await model.unlock(pin: "0000"))
            XCTAssertEqual(model.pinAttemptsLeft, 5 - i)
            XCTAssertTrue(model.pinEnabled)
        }
        await assertThrows(try await model.unlock(pin: "0000"))
        XCTAssertFalse(model.pinEnabled)
        XCTAssertNil(Store.loadAccount()?.pinProtectedUserKey)
        XCTAssertEqual(model.pinAttemptsLeft, 5)
        await assertThrows(try await model.unlock(pin: "4711"))
        XCTAssertEqual(model.phase, .locked)

        let wrong = await model.verifyMasterPassword("nope")
        let right = await model.verifyMasterPassword(password)
        XCTAssertFalse(wrong)
        XCTAssertTrue(right)
        await assertThrows(try await model.unlock(password: "nope"))
        try await model.unlock(password: password)
        XCTAssertEqual(model.phase, .unlocked)
        XCTAssertEqual(model.service?.keys.userKey, userKey)
    }

    func testPinUnlockRestoresCachedVaultAndGeneratorHistory() async throws {
        try signIn()
        try await model.setPIN("4711", requireMasterOnRestart: false)
        for i in 0 ..< 105 { model.recordGenerated("Gen-Secret-\(i)") }
        XCTAssertEqual(model.generatorHistory.count, 100)
        let onDisk = try String(contentsOf: Paths.generatorHistory, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("Gen-Secret"))
        XCTAssertNoThrow(try EncString(onDisk).decrypt(key: userKey))

        let sync: [String: Any] = ["profile": ["id": "u-test", "email": "a@b.c"],
                                   "ciphers": [["id": "c1", "type": 1, "name": try EncString.encrypt("Cached", key: userKey).description]]]
        try JSONSerialization.data(withJSONObject: sync).write(to: Paths.syncCache)

        model.lock()
        XCTAssertTrue(model.generatorHistory.isEmpty)
        await assertThrows(try await model.unlock(pin: "1234"))
        XCTAssertEqual(model.pinAttemptsLeft, 4)
        try await model.unlock(pin: "4711")
        XCTAssertEqual(model.phase, .unlocked)
        XCTAssertEqual(model.pinAttemptsLeft, 5)
        XCTAssertEqual(model.ciphers.map(\.name), ["Cached"])
        XCTAssertEqual(model.generatorHistory.first?.password, "Gen-Secret-104")
        XCTAssertEqual(model.generatorHistory.count, 100)

        model.clearGeneratorHistory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.generatorHistory.path))
    }

    func testPinCanBeKeptOutOfStorageUntilRestart() async throws {
        try signIn()
        try await model.setPIN("4711", requireMasterOnRestart: true)
        XCTAssertNil(Store.loadAccount()?.pinProtectedUserKey)
        XCTAssertTrue(model.pinEnabled)
        model.lock()
        try await model.unlock(pin: "4711")
        XCTAssertEqual(model.phase, .unlocked)

        try await model.setPIN(nil, requireMasterOnRestart: false)
        XCTAssertFalse(model.pinEnabled)
    }

    func testLogoutTimeoutActionWipesLocalData() async throws {
        try signIn()
        model.recordGenerated("secret")
        try Data("{}".utf8).write(to: Paths.syncCache)
        Prefs.d.set("logout", forKey: Prefs.timeoutAction)
        model.lock()
        XCTAssertEqual(model.phase, .loggedOut)
        XCTAssertNil(model.account)
        XCTAssertNil(Store.loadAccount())
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.syncCache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.generatorHistory.path))
        XCTAssertTrue(model.generatorHistory.isEmpty)
    }
}
