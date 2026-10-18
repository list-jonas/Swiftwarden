import Foundation
@testable import SwiftwardenCore
import XCTest

final class APIClientTests: StubbedTestCase {
    func testServerEnvironmentURLs() {
        let s = ServerEnvironment.selfHosted("https://bw.example.com// ")
        XCTAssertEqual(s.apiURL, "https://bw.example.com/api")
        XCTAssertEqual(s.identityURL, "https://bw.example.com/identity")
        XCTAssertEqual(s.iconsURL, "https://bw.example.com/icons")
        XCTAssertEqual(s.webVaultURL, "https://bw.example.com")
        XCTAssertEqual(s.label, "bw.example.com")
        let custom = ServerEnvironment(base: "https://bw.example.com", api: "https://api.example.com/", identity: " ")
        XCTAssertEqual(custom.apiURL, "https://api.example.com")
        XCTAssertEqual(custom.identityURL, "https://bw.example.com/identity")
        XCTAssertEqual(ServerEnvironment().apiURL, ServerEnvironment.us.apiURL)
        XCTAssertEqual(ServerEnvironment().webVaultURL, ServerEnvironment.us.webVaultURL)
        XCTAssertEqual(ServerEnvironment().iconsURL, ServerEnvironment.us.iconsURL)
        XCTAssertEqual(ServerEnvironment.us.label, "bitwarden.com")
        XCTAssertEqual(ServerEnvironment.eu.label, "bitwarden.eu")
    }

    func testPreloginFallsBackToAPIOnOlderServers() async throws {
        StubURLProtocol.handler = { r in
            r.path == "/identity/accounts/prelogin" ? .text("", status: 404)
                : .json(["kdf": 1, "kdfIterations": 3, "kdfMemory": 64, "kdfParallelism": 4])
        }
        let pre = try await client().prelogin(email: "a@b.c")
        XCTAssertEqual(pre.config, KdfConfig(type: 1, iterations: 3, memory: 64, parallelism: 4))
        XCTAssertEqual(StubURLProtocol.log.map(\.path), ["/identity/accounts/prelogin", "/api/accounts/prelogin"])
        XCTAssertEqual(StubURLProtocol.log.last?.json["email"] as? String, "a@b.c")
        XCTAssertEqual(StubURLProtocol.log.last?.header("Device-Type"), "7")

        StubURLProtocol.handler = { _ in .text("", status: 404) }
        await XCTAssertThrowsAsync(try await client().prelogin(email: "a@b.c"))
    }

    func testServerErrorsMapToUserFacingErrors() async {
        let cases: [(StubURLProtocol.Reply, (Error) -> Bool)] = [
            (.text("", status: 401), { if case .unauthorized = $0 as? APIError { true } else { false } }),
            (.json(["validationErrors": ["Name": ["Name is too long."]], "message": "fallback"], status: 400), { $0.localizedDescription == "Name is too long." }),
            (.json(["errorModel": ["message": "Item not found."]], status: 404), { $0.localizedDescription == "Item not found." }),
            (.json(["error": "device_error"], status: 400), { if case .newDeviceVerification = $0 as? APIError { true } else { false } }),
            (.json(["twoFactorProviders2": ["1": NSNull(), "0": ["Email": "a***@b.c"]]], status: 400), {
                if case let .twoFactorRequired(p, info) = $0 as? APIError { p == [0, 1] && info["0"] != nil } else { false }
            }),
            (.text("<html>Bad Gateway</html>", status: 502), { $0.localizedDescription == "<html>Bad Gateway</html>" }),
            (.text("", status: 500), { $0.localizedDescription == "Server error (500)" }),
        ]
        let api = client(tokens: validTokens())
        for (i, (reply, check)) in cases.enumerated() {
            StubURLProtocol.handler = { _ in reply }
            do {
                _ = try await api.raw("GET", "/sync", auth: false)
                XCTFail("case \(i) did not throw")
            } catch {
                XCTAssertTrue(check(error), "case \(i): \(error)")
            }
        }
    }

    func testPasswordGrantSendsDeviceInfoAndStoresTokens() async throws {
        StubURLProtocol.handler = { _ in .json(["access_token": "A1", "refresh_token": "R1", "expires_in": 3600, "Key": "k"]) }
        let api = client()
        var changed: [Tokens?] = []
        api.onTokensChanged = { changed.append($0) }
        let t = try await api.token(["grant_type": "password", "password": "a+b=c&d"], email: "Me@Example.com")
        XCTAssertEqual(t.key, "k")
        let req = try XCTUnwrap(StubURLProtocol.log.first)
        XCTAssertEqual(req.url, "\(Self.server)/identity/connect/token")
        XCTAssertEqual(req.form["password"], "a+b=c&d")
        XCTAssertEqual(req.form["deviceIdentifier"], "device-1")
        XCTAssertEqual(req.form["deviceType"], "7")
        XCTAssertEqual(req.header("Auth-Email"), Data("Me@Example.com".utf8).base64URL)
        XCTAssertEqual(api.tokens?.access, "A1")
        XCTAssertEqual(api.tokens?.refresh, "R1")
        XCTAssertGreaterThan(api.tokens!.expires, Date().addingTimeInterval(3500))
        XCTAssertEqual(changed.count, 1)
    }

    func testAPIKeyLoginKeepsCredentialsForLaterRefresh() async throws {
        StubURLProtocol.handler = { _ in .json(["access_token": "A1", "expires_in": 1]) }
        let api = client()
        _ = try await VaultService.loginAPIKey(api: api, clientId: "user.abc", clientSecret: "s3cret")
        XCTAssertEqual(StubURLProtocol.log.first?.form["grant_type"], "client_credentials")
        XCTAssertEqual(api.tokens?.clientId, "user.abc")
        XCTAssertNil(api.tokens?.refresh)

        StubURLProtocol.handler = { r in r.path.hasSuffix("/connect/token") ? .json(["access_token": "A2"]) : .json([String: Any]()) }
        _ = try await api.raw("GET", "/sync")
        let token = try XCTUnwrap(StubURLProtocol.log.first)
        XCTAssertEqual(token.form["client_secret"], "s3cret")
        XCTAssertEqual(StubURLProtocol.log.last?.header("Authorization"), "Bearer A2")
        XCTAssertEqual(api.tokens?.clientId, "user.abc")
    }

    func testTokenEndpointErrors() async {
        let cases: [(Any, (Error) -> Bool)] = [
            (["twoFactorProviders2": ["0": NSNull()]], { if case .twoFactorRequired(let p, _) = $0 as? APIError { p == [0] } else { false } }),
            (["error_description": "New device verification required"], { if case .newDeviceVerification = $0 as? APIError { true } else { false } }),
            (["error_description": "invalid_grant", "errorModel": ["message": "Username or password is incorrect. Try again."]],
             { $0.localizedDescription == "Username or password is incorrect. Try again." }),
            ([String: Any](), { $0.localizedDescription == "Login failed" }),
        ]
        for (i, (body, check)) in cases.enumerated() {
            StubURLProtocol.handler = { _ in .json(body, status: 400) }
            do {
                _ = try await client().token(["grant_type": "password"])
                XCTFail("case \(i) did not throw")
            } catch {
                XCTAssertTrue(check(error), "case \(i): \(error)")
            }
        }
    }

    func testBearerTokenIsOnlySentToOwnServer() async throws {
        StubURLProtocol.handler = { _ in .text("ok") }
        let api = client(tokens: validTokens())
        _ = try await api.raw("GET", "/sync")
        _ = try await api.raw("GET", "https://attacker.example/steal")
        _ = try await api.raw("GET", "\(Self.server)/api.evil.com/x")
        _ = try await api.raw("POST", "/accounts/password-hint", body: Data("{}".utf8), auth: false)
        _ = try await api.download("https://files.example/blob")
        XCTAssertEqual(StubURLProtocol.log.map { $0.header("Authorization") }, ["Bearer access-1", nil, nil, nil, nil])
        XCTAssertEqual(StubURLProtocol.log[3].header("Content-Type"), "application/json")
    }

    func testExpiringTokenIsRefreshedBeforeRequest() async throws {
        StubURLProtocol.handler = { r in r.path.hasSuffix("/connect/token") ? .json(["access_token": "fresh", "refresh_token": "R2"]) : .text("ok") }
        let api = client(tokens: Tokens(access: "stale", refresh: "R1", expires: Date().addingTimeInterval(30)))
        _ = try await api.raw("GET", "/sync")
        XCTAssertEqual(StubURLProtocol.log.map(\.path), ["/identity/connect/token", "/api/sync"])
        XCTAssertEqual(StubURLProtocol.log[0].form["grant_type"], "refresh_token")
        XCTAssertEqual(StubURLProtocol.log[0].form["refresh_token"], "R1")
        XCTAssertEqual(StubURLProtocol.log[1].header("Authorization"), "Bearer fresh")
        XCTAssertEqual(api.tokens?.refresh, "R2")
    }

    func testRevokedTokenIsRefreshedAndRequestRetried() async throws {
        StubURLProtocol.handler = { r in
            if r.path.hasSuffix("/connect/token") { return .json(["access_token": "fresh"]) }
            return r.header("Authorization") == "Bearer fresh" ? .text("data") : .text("", status: 401)
        }
        let api = client(tokens: validTokens())
        let d = try await api.raw("GET", "/sync")
        XCTAssertEqual(String(decoding: d, as: UTF8.self), "data")
        XCTAssertEqual(StubURLProtocol.log.map(\.path), ["/api/sync", "/identity/connect/token", "/api/sync"])
        XCTAssertEqual(api.tokens?.refresh, "refresh-1")
    }

    func testRefreshWithoutCredentialsFails() async {
        StubURLProtocol.handler = { _ in .text("", status: 401) }
        let none = client()
        await XCTAssertThrowsAsync(try await none.refresh())
        let noRefresh = client(tokens: validTokens(refresh: nil))
        await XCTAssertThrowsAsync(try await noRefresh.raw("GET", "/sync"))
        XCTAssertEqual(StubURLProtocol.log.count, 1)
    }

    func testConcurrentRefreshesShareOneTokenRequest() async throws {
        StubURLProtocol.handler = { _ in var r = StubURLProtocol.Reply.json(["access_token": "fresh"]); r.delay = 0.2; return r }
        let api = client(tokens: validTokens())
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0 ..< 8 { g.addTask { try await api.refresh() } }
            try await g.waitForAll()
        }
        XCTAssertEqual(StubURLProtocol.log.count, 1)
        XCTAssertEqual(api.tokens?.access, "fresh")
    }

    func testFileUploads() async throws {
        StubURLProtocol.handler = { _ in .text("") }
        let api = client(tokens: validTokens())
        try await api.upload(url: "https://blob.core.windows.net/x?sig=1", data: Data([1, 2]), azure: true, fileName: "f", fallbackPath: "/unused")
        let azure = try XCTUnwrap(StubURLProtocol.log.first)
        XCTAssertEqual(azure.method, "PUT")
        XCTAssertEqual(azure.header("x-ms-blob-type"), "BlockBlob")
        XCTAssertNil(azure.header("Authorization"))
        XCTAssertEqual(azure.body, Data([1, 2]))

        StubURLProtocol.handler = { _ in .text("") }
        try await api.upload(url: "", data: Data("BODY".utf8), azure: false, fileName: "2.enc|name|mac", fallbackPath: "/ciphers/c/attachment/a")
        let mp = try XCTUnwrap(StubURLProtocol.log.first)
        XCTAssertEqual(mp.path, "/api/ciphers/c/attachment/a")
        XCTAssertEqual(mp.header("Authorization"), "Bearer access-1")
        let boundary = try XCTUnwrap(mp.header("Content-Type")?.components(separatedBy: "boundary=").last)
        let text = String(decoding: mp.body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--\(boundary)\r\n"))
        XCTAssertTrue(text.contains("filename=\"2.enc|name|mac\""))
        XCTAssertTrue(text.contains("\r\n\r\nBODY\r\n--\(boundary)--"))
    }

    func testTypedRequests() async throws {
        struct Echo: Codable, Equatable { var name: String }
        StubURLProtocol.handler = { r in .json(["Name": (r.json["name"] as? String ?? "") + "!"]) }
        let api = client(tokens: validTokens())
        let out: Echo = try await api.send("POST", "/echo", Echo(name: "hi"))
        XCTAssertEqual(out, Echo(name: "hi!"))
        try await api.call("DELETE", "/thing")
        XCTAssertEqual(StubURLProtocol.log.last?.method, "DELETE")
        XCTAssertTrue(StubURLProtocol.log.last?.body.isEmpty ?? false)
    }
}

func XCTAssertThrowsAsync<T>(_ e: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await e(); XCTFail("expected error", file: file, line: line) } catch {}
}
