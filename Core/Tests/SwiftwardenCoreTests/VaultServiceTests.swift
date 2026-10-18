import Foundation
@testable import SwiftwardenCore
import XCTest

final class VaultServiceTests: StubbedTestCase {
    let acc = Account.shared

    final class Box: @unchecked Sendable { var blob = Data(); var json: [String: Any] = [:] }

    func sendKey(_ material: Data) throws -> SymmetricCryptoKey {
        try SymmetricCryptoKey(Primitives.hkdf(ikm: material, salt: "bitwarden-send", info: "send", length: 64))
    }

    // MARK: Auth

    func testLoginUnlocksUserKey() async throws {
        let acc = acc
        StubURLProtocol.handler = { r in
            guard r.form["password"] == acc.serverPasswordHash else {
                return .json(["error_description": "invalid_grant", "errorModel": ["message": "Username or password is incorrect."]], status: 400)
            }
            return .json(["access_token": "A", "refresh_token": "R", "Key": acc.protectedUserKey, "PrivateKey": acc.encryptedPrivateKey,
                          "TwoFactorToken": "remember-me"])
        }
        let api = client()
        let s = try await VaultService.login(api: api, email: " Alice@Example.com", password: acc.password, kdf: acc.kdf,
                                             twoFactor: (1, "123456", true), newDeviceOtp: "999")
        XCTAssertEqual(s.userKey, acc.userKey)
        XCTAssertEqual(s.protectedUserKey, acc.protectedUserKey)
        XCTAssertEqual(s.encryptedPrivateKey, acc.encryptedPrivateKey)
        XCTAssertEqual(s.twoFactorRememberToken, "remember-me")
        XCTAssertEqual(s.tokens.access, "A")
        let f = try XCTUnwrap(StubURLProtocol.log.first).form
        XCTAssertEqual(f["username"], "alice@example.com")
        XCTAssertEqual(f["twoFactorProvider"], "1")
        XCTAssertEqual(f["twoFactorToken"], "123456")
        XCTAssertEqual(f["twoFactorRemember"], "1")
        XCTAssertEqual(f["newDeviceOtp"], "999")
        XCTAssertFalse(String(decoding: StubURLProtocol.log[0].body, as: UTF8.self).contains("horse"))

        do {
            _ = try await VaultService.login(api: client(), email: acc.email, password: "wrong", kdf: acc.kdf)
            XCTFail("wrong password accepted")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Username or password is incorrect.")
        }

        StubURLProtocol.handler = { _ in .json(["access_token": "A"]) }
        await XCTAssertThrowsAsync(try await VaultService.login(api: client(), email: acc.email, password: acc.password, kdf: acc.kdf))
    }

    func testUnlockRequiresCorrectPassword() throws {
        XCTAssertEqual(try VaultService.unlock(password: acc.password, email: "ALICE@example.com ", kdf: acc.kdf, protectedUserKey: acc.protectedUserKey),
                       acc.userKey)
        XCTAssertThrowsError(try VaultService.unlock(password: "wrong", email: acc.email, kdf: acc.kdf, protectedUserKey: acc.protectedUserKey))
        XCTAssertThrowsError(try VaultService.unlock(password: acc.password, email: "bob@example.com", kdf: acc.kdf, protectedUserKey: acc.protectedUserKey))
    }

    func testRegistrationCreatesUsableAccountKeys() async throws {
        StubURLProtocol.handler = { _ in .text("") }
        let kdf = KdfConfig(type: 0, iterations: 5000)
        try await VaultService.register(api: client(), email: "New@Example.com", name: "N", password: "pw-123456", hint: "", kdf: kdf,
                                        token: "https://vault.test/#/finish-signup?token=TOK123&email=new%40example.com")
        let r = try XCTUnwrap(StubURLProtocol.log.last)
        XCTAssertEqual(r.url, "\(Self.server)/identity/accounts/register/finish")
        XCTAssertNil(r.header("Authorization"))
        let b = r.json
        XCTAssertEqual(b["email"] as? String, "new@example.com")
        XCTAssertEqual(b["emailVerificationToken"] as? String, "TOK123")
        XCTAssertTrue(b["masterPasswordHint"] is NSNull)
        XCTAssertEqual(b["kdfIterations"] as? Int, 5000)
        XCTAssertNil(b["kdfMemory"])

        let mk = try KeyDerivation.masterKey(password: "pw-123456", email: "new@example.com", kdf: kdf)
        XCTAssertEqual(b["masterPasswordHash"] as? String, try KeyDerivation.masterPasswordHash(password: "pw-123456", masterKey: mk))
        let uk = try KeyDerivation.decryptUserKey(try XCTUnwrap(b["userSymmetricKey"] as? String), with: mk)
        let keys = try XCTUnwrap(b["userAsymmetricKeys"] as? [String: String])
        let priv = try RSA.privateKey(der: EncString(XCTUnwrap(keys["encryptedPrivateKey"])).decrypt(key: uk))
        XCTAssertEqual(try RSA.publicSPKI(of: priv).base64EncodedString(), keys["publicKey"])
    }

    func testRegistrationRequestsEmailVerificationFirst() async throws {
        StubURLProtocol.handler = { r in r.path.hasSuffix("send-verification-email") ? .text("\"TOKEN\"") : .text("") }
        try await VaultService.register(api: client(), email: "New@Example.com", name: "N", password: "pw-123456", hint: "hint",
                                        kdf: KdfConfig(type: 0, iterations: 5000))
        XCTAssertEqual(StubURLProtocol.log.first?.json["email"] as? String, "new@example.com")
        XCTAssertEqual(StubURLProtocol.log.last?.json["emailVerificationToken"] as? String, "TOKEN")
        XCTAssertEqual(StubURLProtocol.log.last?.json["masterPasswordHint"] as? String, "hint")

        StubURLProtocol.handler = { _ in .text("") }
        do {
            try await VaultService.register(api: client(), email: "x@y.z", name: "", password: "p", hint: "", kdf: KdfConfig(type: 0, iterations: 5000))
            XCTFail("registered without verification")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Check your email"))
            XCTAssertEqual(StubURLProtocol.log.count, 1)
        }
    }

    func testAccountRecoveryRequestsProveMasterPassword() async throws {
        StubURLProtocol.handler = { _ in .text("") }
        let api = client(tokens: validTokens())
        try await VaultService.sendEmailCode(api: api, email: acc.email, password: acc.password, kdf: acc.kdf)
        try await VaultService.resendNewDeviceOtp(api: api, email: acc.email, password: acc.password, kdf: acc.kdf)
        try await VaultService.passwordHint(api: api, email: acc.email)
        let log = StubURLProtocol.log
        XCTAssertEqual(log.map(\.path), ["/api/two-factor/send-email-login", "/api/accounts/resend-new-device-otp", "/api/accounts/password-hint"])
        XCTAssertEqual(log[0].json["masterPasswordHash"] as? String, acc.serverPasswordHash)
        XCTAssertEqual(log[0].json["deviceIdentifier"] as? String, "device-1")
        XCTAssertEqual(log[1].json["masterPasswordHash"] as? String, acc.serverPasswordHash)
        XCTAssertNil(log[1].header("Authorization"))
        XCTAssertEqual(log[2].json["email"] as? String, acc.email)
        XCTAssertNil(log[2].header("Authorization"))
    }

    // MARK: Sync

    func testDecryptsFullVault() throws {
        let itemKey = SymmetricCryptoKey.generate()
        let material = Primitives.random(16)
        let sk = try sendKey(material)
        let wrappedItemKey = try EncString.encrypt(itemKey.data, key: acc.userKey).description
        let sendKeyWrapped = try EncString.encrypt(material, key: acc.userKey).description
        let org = try acc.orgEntry()
        let ciphers: [[String: Any]] = [
            ["id": "p1", "type": 1, "name": acc.enc("Personal"), "notes": acc.enc("note"), "folderId": "f1",
             "login": ["username": acc.enc("me"), "password": acc.enc("pw"), "totp": acc.enc("JBSWY3DPEHPK3PXP"),
                       "uris": [["uri": acc.enc("https://a.com"), "match": NSNull()]],
                       "fido2Credentials": [["credentialId": acc.enc("cred"), "rpId": acc.enc("a.com")]]],
             "fields": [["name": acc.enc("PIN"), "value": acc.enc("1234"), "type": 1]],
             "passwordHistory": [["password": acc.enc("old"), "lastUsedDate": "2026-01-01T00:00:00Z"]],
             "attachments": [["id": "a1", "fileName": acc.enc("doc.pdf"), "size": 10]]],
            ["id": "o1", "type": 3, "organizationId": "org-1", "collectionIds": ["col-1"], "name": acc.enc("Corp card", acc.orgKey),
             "card": ["number": acc.enc("4111111111111111", acc.orgKey), "code": acc.enc("123", acc.orgKey)]],
            ["id": "k1", "type": 4, "key": wrappedItemKey,
             "name": acc.enc("Me", itemKey), "identity": ["firstName": acc.enc("Ada", itemKey), "passportNumber": acc.enc("X1", itemKey)]],
            ["id": "s1", "type": 5, "name": acc.enc("Deploy"), "sshKey": ["privateKey": acc.enc("-----BEGIN"), "keyFingerprint": acc.enc("SHA256:x")]],
            ["id": "x1", "type": 1, "organizationId": "org-gone", "name": "2.AAAA|AAAA|AAAA", "notes": "secret?", "login": ["password": "2.x|y|z"]],
            ["id": "bad", "type": 2, "name": acc.enc("Broken"), "notes": "2.AAAA|AAAA|AAAA"],
        ]
        let sync: [String: Any] = [
            "profile": acc.profile(orgs: [org, ["id": "org-bad", "key": "4.AAAA"]]),
            "folders": [["id": "f2", "name": acc.enc("Folder 10")], ["id": "f1", "name": acc.enc("Folder 2")]],
            "collections": [["id": "col-1", "organizationId": "org-1", "name": acc.enc("Engineering", acc.orgKey)]],
            "ciphers": ciphers,
            "sends": [["id": "send-1", "type": 0, "key": sendKeyWrapped,
                       "name": acc.enc("Wifi", sk), "text": ["text": acc.enc("hunter2", sk), "hidden": true]],
                      ["id": "send-2", "type": 0, "name": "2.x|y|z"]],
            "policies": [["id": "pol", "type": 1, "enabled": true, "data": ["minLength": 12]]],
        ]
        let svc = VaultService(api: client(), keys: KeyRing(userKey: acc.userKey))
        XCTAssertNil(svc.fingerprintPhrase())
        let v = try svc.decryptVault(JSONSerialization.data(withJSONObject: sync))
        let byId = Dictionary(uniqueKeysWithValues: v.ciphers.map { ($0.id, $0) })

        let p = try XCTUnwrap(byId["p1"])
        XCTAssertEqual(p.name, "Personal")
        XCTAssertEqual(p.notes, "note")
        XCTAssertEqual(p.login?.username, "me")
        XCTAssertEqual(p.login?.password, "pw")
        XCTAssertEqual(p.login?.totp, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(p.login?.uris?.first?.uri, "https://a.com")
        XCTAssertEqual(p.login?.fido2Credentials?.first?.rpId, "a.com")
        XCTAssertEqual(p.fields?.first?.value, "1234")
        XCTAssertEqual(p.passwordHistory?.first?.password, "old")
        XCTAssertEqual(p.attachments?.first?.fileName, "doc.pdf")

        XCTAssertEqual(byId["o1"]?.name, "Corp card")
        XCTAssertEqual(byId["o1"]?.card?.number, "4111111111111111")
        XCTAssertEqual(byId["k1"]?.identity?.passportNumber, "X1")
        XCTAssertEqual(byId["k1"]?.subtitle, "Ada")
        XCTAssertEqual(byId["s1"]?.sshKey?.keyFingerprint, "SHA256:x")

        let locked = try XCTUnwrap(byId["x1"])
        XCTAssertEqual(locked.name, "[locked: missing key]")
        XCTAssertNil(locked.notes)
        XCTAssertNil(locked.login)
        XCTAssertEqual(byId["bad"]?.name, "Broken")
        XCTAssertEqual(byId["bad"]?.notes, VaultService.decryptionError)

        XCTAssertEqual(v.folders.map(\.name), ["Folder 2", "Folder 10"])
        XCTAssertEqual(v.collections.first?.name, "Engineering")
        XCTAssertEqual(v.sends.first?.name, "Wifi")
        XCTAssertEqual(v.sends.first?.text?.text, "hunter2")
        XCTAssertEqual(v.sends.first?.key, material.base64URL)
        XCTAssertEqual(v.sends.last?.name, "2.x|y|z")
        XCTAssertEqual(v.policies.first?.data?["minLength"]?.int, 12)
        XCTAssertEqual(v.organizations.count, 2)
        XCTAssertEqual(Set(svc.keys.orgKeys.keys), ["org-1"])
        XCTAssertEqual(svc.keys.orgKeys["org-1"], acc.orgKey)
        XCTAssertEqual(svc.fingerprintPhrase(), Fingerprint.phrase(userId: acc.userId, publicKey: acc.rsa.publicSPKI))
    }

    func testLargeVaultDecryptionKeepsOrder() throws {
        let svc = VaultService(api: client(), keys: KeyRing(userKey: acc.userKey))
        let list = (0 ..< 300).map { i -> Cipher in
            var c = Cipher(type: .login)
            c.id = "\(i)"; c.name = acc.enc("Item \(i)"); c.login?.password = acc.enc("pw\(i)")
            return c
        }
        let out = svc.decryptAll(list)
        XCTAssertEqual(out.map(\.name), (0 ..< 300).map { "Item \($0)" })
        XCTAssertEqual(out.last?.login?.password, "pw299")
    }

    func testSyncEndpoints() async throws {
        StubURLProtocol.handler = { r in r.path.hasSuffix("revision-date") ? .text("1767323045123") : .text("{}") }
        let svc = try acc.service(client(tokens: validTokens()), withPrivateKey: false)
        _ = try await svc.fetchSync()
        XCTAssertEqual(StubURLProtocol.log.last?.url, "\(Self.server)/api/sync?excludeDomains=true")
        let rev = try await svc.revisionDate()
        XCTAssertEqual(rev, 1_767_323_045_123)
    }

    // MARK: Writes

    func testSaveEncryptsAndRoutesNewAndExistingItems() async throws {
        StubURLProtocol.handler = { r in
            switch (r.method, r.path) {
            case ("POST", "/api/ciphers"): r.echoCipher(id: "new-1")
            case ("POST", "/api/ciphers/create"): r.echoCipher(id: "new-2")
            case ("PUT", "/api/ciphers/c1"): r.echoCipher(id: "c1")
            default: .text("", status: 404)
            }
        }
        let svc = try acc.service(client(tokens: validTokens()))
        var c = Cipher(type: .login)
        c.name = "GitHub"; c.login?.username = "octo"; c.login?.password = "pw"
        c.login?.uris = [LoginUri(uri: "https://github.com"), LoginUri(uri: "")]
        c.fields = [Field(name: "PIN", value: "1", type: .hidden), Field()]
        c.card = Card(); c.card?.number = "leak"

        let saved = try await svc.save(c)
        XCTAssertEqual(saved.id, "new-1")
        XCTAssertEqual(saved.name, "GitHub")
        XCTAssertEqual(saved.login?.password, "pw")
        XCTAssertEqual(saved.login?.uris?.count, 1)
        XCTAssertEqual(saved.fields?.count, 1)
        let body = StubURLProtocol.log[0].json
        XCTAssertNotEqual(body["name"] as? String, "GitHub")
        XCTAssertEqual(acc.dec(body["name"]), "GitHub")
        XCTAssertEqual(body["encryptedFor"] as? String, acc.userId)
        XCTAssertNil(body["card"])
        let uri = try XCTUnwrap((body["login"] as? [String: Any])?["uris"] as? [[String: Any]]).first
        XCTAssertEqual(acc.dec(uri?["uriChecksum"]), Primitives.sha256(Data("https://github.com".utf8)).base64EncodedString())

        var org = c
        org.organizationId = "org-1"
        let orgSaved = try await svc.save(org, collectionIds: ["col-1"])
        XCTAssertEqual(orgSaved.name, "GitHub")
        let create = StubURLProtocol.log[1].json
        XCTAssertEqual(create["collectionIds"] as? [String], ["col-1"])
        let inner = try XCTUnwrap(create["cipher"] as? [String: Any])
        XCTAssertEqual(acc.dec(inner["name"], acc.orgKey), "GitHub")
        XCTAssertNil(acc.dec(inner["name"]))

        var edit = saved
        edit.id = "c1"; edit.login?.password = "pw2"
        let updated = try await svc.save(edit)
        XCTAssertEqual(updated.login?.password, "pw2")
        XCTAssertEqual(StubURLProtocol.log[2].json["lastKnownRevisionDate"] as? String, "2026-01-01T00:00:00Z")
    }

    func testShareReencryptsWithOrganizationKey() async throws {
        StubURLProtocol.handler = { r in r.echoCipher(id: "c1") }
        let svc = try acc.service(client(tokens: validTokens()))
        var c = Cipher(type: .login)
        c.id = "c1"; c.name = "Router"; c.login?.password = "admin"; c.folderId = "f1"
        c.key = try EncString.encrypt(SymmetricCryptoKey.generate().data, key: acc.userKey).description
        let shared = try await svc.share(c, organizationId: "org-1", collectionIds: ["col-1"])
        XCTAssertEqual(shared.organizationId, "org-1")
        XCTAssertEqual(shared.login?.password, "admin")
        let r = try XCTUnwrap(StubURLProtocol.log.first)
        XCTAssertEqual(r.method + " " + r.path, "PUT /api/ciphers/c1/share")
        let inner = try XCTUnwrap(r.json["cipher"] as? [String: Any])
        XCTAssertNil(inner["key"])
        XCTAssertEqual(acc.dec((inner["login"] as? [String: Any])?["password"], acc.orgKey), "admin")
        XCTAssertEqual(r.json["collectionIds"] as? [String], ["col-1"])
    }

    func testRefusesToOverwriteDataItCouldNotDecrypt() async throws {
        StubURLProtocol.handler = { r in r.echoCipher(id: "c1") }
        let svc = try acc.service(client(tokens: validTokens()))
        var c = Cipher(type: .login)
        c.id = "c1"; c.name = "x"; c.login?.password = VaultService.decryptionError
        await XCTAssertThrowsAsync(try await svc.save(c))
        XCTAssertTrue(StubURLProtocol.log.isEmpty)

        c.login?.password = "fine"
        c.attachments = try JSONDecoder().decode([Attachment].self, from: Data(#"[{"id":"a","fileName":"[decryption error]"}]"#.utf8))
        XCTAssertNoThrow(try svc.encrypt(c))

        c.organizationId = "org-unknown"
        XCTAssertThrowsError(try svc.encrypt(c))
    }

    func testSimpleMutationsHitBitwardenRoutes() async throws {
        StubURLProtocol.handler = { r in r.path.contains("/folders") && r.method != "DELETE" ? .json(["id": "f9", "name": r.json["name"] ?? ""]) : .text("") }
        let svc = try acc.service(client(tokens: validTokens()))
        try await svc.trash("c1")
        try await svc.restore("c1")
        try await svc.deletePermanently("c1")
        try await svc.updateCollections("c1", collectionIds: ["col-1"])
        try await svc.partial("c1", folderId: nil, favorite: true)
        try await svc.deleteAttachment(cipherId: "c1", attachmentId: "a1")
        try await svc.removeSendPassword("s1")
        try await svc.deleteSend("s1")
        let created = try await svc.saveFolder(id: nil, name: "Work")
        _ = try await svc.saveFolder(id: "f9", name: "Play")
        try await svc.deleteFolder("f9")
        let log = StubURLProtocol.log
        XCTAssertEqual(log.map { "\($0.method) \($0.path)" }, [
            "PUT /api/ciphers/c1/delete", "PUT /api/ciphers/c1/restore", "DELETE /api/ciphers/c1", "PUT /api/ciphers/c1/collections",
            "PUT /api/ciphers/c1/partial", "DELETE /api/ciphers/c1/attachment/a1", "PUT /api/sends/s1/remove-password", "DELETE /api/sends/s1",
            "POST /api/folders", "PUT /api/folders/f9", "DELETE /api/folders/f9",
        ])
        XCTAssertEqual(log[3].json["collectionIds"] as? [String], ["col-1"])
        XCTAssertTrue(log[4].json["folderId"] is NSNull)
        XCTAssertEqual(log[4].json["favorite"] as? Bool, true)
        XCTAssertEqual(created.name, "Work")
        XCTAssertEqual(acc.dec(log[8].json["name"]), "Work")
        XCTAssertEqual(acc.dec(log[9].json["name"]), "Play")
    }

    func testAttachmentRoundTrip() async throws {
        let box = Box()
        StubURLProtocol.handler = { r in
            switch (r.method, r.path) {
            case ("POST", "/api/ciphers/c1/attachment/v2"):
                box.json = r.json
                return .json(["attachmentId": "a1", "url": "", "fileUploadType": 0])
            case ("POST", "/api/ciphers/c1/attachment/a1"):
                let text = r.body
                let start = text.range(of: Data("\r\n\r\n".utf8))!.upperBound
                let end = text.range(of: Data("\r\n--".utf8), in: start ..< text.endIndex)!.lowerBound
                box.blob = text[start ..< end]
                return .text("")
            case ("GET", "/api/ciphers/c1/attachment/a1"): return .json(["url": "https://files.test/a1"])
            case ("GET", "/a1"): return StubURLProtocol.Reply(body: box.blob)
            default: return .text("", status: 404)
            }
        }
        let svc = try acc.service(client(tokens: validTokens()))
        var c = Cipher(type: .login)
        c.id = "c1"
        let payload = Data((0 ..< 5000).map { UInt8($0 % 251) })
        try await svc.uploadAttachment(cipher: c, fileName: "secret.pdf", data: payload)
        XCTAssertEqual(acc.dec(box.json["fileName"]), "secret.pdf")
        XCTAssertEqual(box.json["fileSize"] as? Int, box.blob.count)
        XCTAssertNil(box.blob.range(of: payload.prefix(64)))

        let meta: [String: Any] = ["id": "a1", "key": box.json["key"]!, "fileName": "secret.pdf"]
        let att = try JSONDecoder().decode(Attachment.self, from: JSONSerialization.data(withJSONObject: meta))
        let downloaded = try await svc.downloadAttachment(cipher: c, attachment: att)
        XCTAssertEqual(downloaded, payload)

        let blob = box.blob
        StubURLProtocol.handler = { r in r.path == "/legacy" ? StubURLProtocol.Reply(body: blob) : .text("", status: 404) }
        var legacy = meta
        legacy["url"] = "https://files.test/legacy"
        let att2 = try JSONDecoder().decode(Attachment.self, from: JSONSerialization.data(withJSONObject: legacy))
        let fromLegacy = try await svc.downloadAttachment(cipher: c, attachment: att2)
        XCTAssertEqual(fromLegacy, payload)
        await XCTAssertThrowsAsync(try await svc.downloadAttachment(cipher: c, attachment: att))
    }

    func testTextSendRoundTrip() async throws {
        StubURLProtocol.handler = { r in
            var o = r.json
            o["id"] = "s1"; o["accessId"] = "acc1"
            return .json(o)
        }
        let svc = try acc.service(client(tokens: validTokens()))
        var s = Send(type: 0)
        s.name = "Wifi"; s.text = SendText(text: "hunter2", hidden: true); s.notes = "private"
        let saved = try await svc.saveSend(s, newPassword: "open sesame")

        let body = StubURLProtocol.log[0].json
        XCTAssertEqual(StubURLProtocol.log[0].path, "/api/sends")
        let material = try EncString(XCTUnwrap(body["key"] as? String)).decrypt(key: acc.userKey)
        XCTAssertEqual(material.count, 16)
        let sk = try sendKey(material)
        XCTAssertEqual(acc.dec(body["name"], sk), "Wifi")
        XCTAssertEqual(acc.dec((body["text"] as? [String: Any])?["text"], sk), "hunter2")
        XCTAssertEqual(body["password"] as? String,
                       try Primitives.pbkdf2(password: Data("open sesame".utf8), salt: material, iterations: 100_000).base64EncodedString())
        XCTAssertNil(body["file"])
        XCTAssertEqual(saved.name, "Wifi")
        XCTAssertEqual(saved.notes, "private")
        XCTAssertEqual(saved.text?.text, "hunter2")
        XCTAssertEqual(saved.key, material.base64URL)
        XCTAssertEqual(svc.sendLink(saved), "\(Self.server)/#/send/acc1/\(material.base64URL)")
        XCTAssertEqual(VaultService(api: client(.us), keys: svc.keys).sendLink(saved), "https://send.bitwarden.com/#acc1/\(material.base64URL)")

        var edit = saved
        edit.name = "Wifi 2"
        let edited = try await svc.saveSend(edit, newPassword: nil)
        let put = StubURLProtocol.log[1]
        XCTAssertEqual(put.method + " " + put.path, "PUT /api/sends/s1")
        XCTAssertNil(put.json["password"])
        XCTAssertEqual(edited.key, saved.key)
        XCTAssertEqual(edited.name, "Wifi 2")
    }

    func testFileSendCanBeOpenedWithLinkKey() async throws {
        let box = Box()
        StubURLProtocol.handler = { r in
            switch r.path {
            case "/api/sends/file/v2":
                box.json = r.json
                var send = r.json
                send["id"] = "s2"; send["accessId"] = "acc2"
                send["file"] = ["id": "f1", "fileName": (r.json["file"] as? [String: Any])?["fileName"] ?? ""]
                return .json(["url": "", "fileUploadType": 0, "sendResponse": send])
            case "/api/sends/s2/file/f1":
                let start = r.body.range(of: Data("\r\n\r\n".utf8))!.upperBound
                let end = r.body.range(of: Data("\r\n--".utf8), in: start ..< r.body.endIndex)!.lowerBound
                box.blob = r.body[start ..< end]
                return .text("")
            default: return .text("", status: 404)
            }
        }
        let svc = try acc.service(client(tokens: validTokens()))
        var s = Send(type: 1)
        s.name = "doc"; s.file = SendFile(fileName: "doc.pdf")
        let payload = Data("pdf bytes".utf8)
        let saved = try await svc.saveSend(s, newPassword: nil, fileData: payload)
        XCTAssertEqual(saved.file?.fileName, "doc.pdf")
        XCTAssertNil(box.json["text"])
        XCTAssertEqual(box.json["fileLength"] as? Int, box.blob.count)
        let linkKey = try sendKey(XCTUnwrap(Data(base64URL: XCTUnwrap(saved.key))))
        XCTAssertEqual(try EncFile.decrypt(box.blob, key: linkKey), payload)
    }

    func testImportStripsServerIdentity() async throws {
        StubURLProtocol.handler = { _ in .text("") }
        let svc = try acc.service(client(tokens: validTokens()))
        var c = Cipher(type: .login)
        c.id = "old"; c.organizationId = "org-1"; c.key = "2.k|k|k"; c.revisionDate = "2020-01-01T00:00:00Z"; c.name = "Imported"
        try await svc.importVault(ciphers: [c], folders: ["Work"], relations: [(0, 0)])
        let b = try XCTUnwrap(StubURLProtocol.log.first).json
        let item = try XCTUnwrap((b["ciphers"] as? [[String: Any]])?.first)
        XCTAssertNil(item["organizationId"])
        XCTAssertNil(item["key"])
        XCTAssertNil(item["lastKnownRevisionDate"])
        XCTAssertEqual(acc.dec(item["name"]), "Imported")
        XCTAssertEqual(acc.dec((b["folders"] as? [[String: Any]])?.first?["name"]), "Work")
        XCTAssertEqual(b["folderRelationships"] as? [[String: Int]], [["key": 0, "value": 0]])
    }
}
