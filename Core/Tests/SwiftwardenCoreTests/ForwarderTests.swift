import Foundation
@testable import SwiftwardenCore
import XCTest

final class ForwarderTests: XCTestCase {
    override func setUp() { URLProtocol.registerClass(StubURLProtocol.self) }
    override func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.handler = nil
    }

    func testEachServiceCreatesAlias() async throws {
        let cases: [(Forwarder, String, String, Any, String)] = [
            (.addy, "https://app.addy.io/api/v1/aliases", "Bearer KEY", ["data": ["email": "a1@addy.io"]], "a1@addy.io"),
            (.simpleLogin, "https://app.simplelogin.io/api/alias/random/new?hostname=github.com", "KEY", ["alias": "s1@sl.co"], "s1@sl.co"),
            (.duckDuckGo, "https://quack.duckduckgo.com/api/email/addresses", "Bearer KEY", ["address": "quack"], "quack@duck.com"),
            (.firefoxRelay, "https://relay.firefox.com/api/v1/relayaddresses/", "Token KEY", ["full_address": "r1@relay.firefox.com"], "r1@relay.firefox.com"),
            (.forwardEmail, "https://api.forwardemail.net/v1/domains/me.com/aliases", "Basic " + Data("KEY:".utf8).base64EncodedString(),
             ["name": "fe1", "domain": ["name": "me.com"]], "fe1@me.com"),
        ]
        for (fwd, url, auth, reply, expected) in cases {
            StubURLProtocol.handler = { _ in .json(reply) }
            let alias = try await fwd.generate(apiKey: "KEY", domain: "me.com", website: "github.com")
            XCTAssertEqual(alias, expected, fwd.label)
            let r = try XCTUnwrap(StubURLProtocol.log.first)
            XCTAssertEqual(r.url, url, fwd.label)
            XCTAssertEqual(r.method, "POST", fwd.label)
            XCTAssertEqual(r.header(fwd == .simpleLogin ? "Authentication" : "Authorization"), auth, fwd.label)
            if fwd != .duckDuckGo { XCTAssertTrue(String(decoding: r.body, as: UTF8.self).contains("github.com"), fwd.label) }
        }
        XCTAssertEqual(Forwarder.allCases.filter(\.needsDomain), [.addy, .forwardEmail])
    }

    func testServiceErrorsAreReported() async {
        StubURLProtocol.handler = { _ in .text("invalid token", status: 401) }
        do {
            _ = try await Forwarder.addy.generate(apiKey: "bad", domain: "d", website: nil)
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "addy.io: invalid token")
        }
        StubURLProtocol.handler = { _ in .json(["unexpected": true]) }
        await XCTAssertThrowsAsync(try await Forwarder.simpleLogin.generate(apiKey: "k", domain: "", website: nil))
        XCTAssertNil(StubURLProtocol.log.first?.request.url?.query)
    }
}
