import Foundation
@testable import SwiftwardenCore
import XCTest

final class ModelTests: XCTestCase {
    func testCipherCopiesAreIndependent() {
        var a = Cipher(type: .login)
        a.login?.password = "one"
        var b = a
        XCTAssertEqual(a, b)
        b.login?.password = "two"
        b.fields = [Field(name: "x")]
        XCTAssertEqual(a.login?.password, "one")
        XCTAssertNil(a.fields)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(Set([a, b]).count, 1)
    }

    func testDecodesServerPayloadsLeniently() throws {
        let json = """
        {"Id":"1","Type":99,"Name":"n","Favorite":true,"Reprompt":1,
         "Login":{"Username":"u","Uris":[{"Uri":"https://a.com","Match":null}],"Fido2Credentials":[{"CredentialId":"c"}]},
         "Attachments":[{"Id":"a1","Size":1024},{"Id":"a2","Size":"2048"}]}
        """
        let c = try JSON.decoder.decode(Cipher.self, from: Data(json.utf8))
        XCTAssertEqual(c.type, .secureNote)
        XCTAssertEqual(c.login?.uris?.first?.uri, "https://a.com")
        XCTAssertEqual(c.attachments?.map(\.size), ["1024", "2048"])
        XCTAssertTrue(c.isFavorite && c.needsReprompt && c.hasPasskey)
        XCTAssertTrue(c.canEdit && c.canViewPassword)
        XCTAssertEqual(try JSON.decoder.decode(Cipher.self, from: Data("{}".utf8)).id, "")

        let t = try JSON.decoder.decode(TokenResponse.self, from: Data(#"{"access_token":"a","Key":"k","expires_in":5}"#.utf8))
        XCTAssertEqual(t.accessToken, "a")
        XCTAssertEqual(t.key, "k")
        XCTAssertEqual(t.expiresIn, 5)

        let s = try JSON.decoder.decode(Send.self, from: Data(#"{"Type":1,"File":{"FileName":"f","Size":12}}"#.utf8))
        XCTAssertEqual(s.file?.size, "12")
        XCTAssertFalse(s.disabled)
    }

    func testCipherEncodingRoundTrips() throws {
        var c = Cipher(type: .identity)
        c.id = "i"; c.name = "Me"; c.identity?.firstName = "Ada"; c.fields = [Field(name: "n", value: "v", type: .boolean)]
        let back = try JSON.decoder.decode(Cipher.self, from: JSON.encoder.encode(c))
        XCTAssertEqual(back.identity?.firstName, "Ada")
        XCTAssertEqual(back.fields?.first?.type, .boolean)
        XCTAssertFalse(String(decoding: try JSON.encoder.encode(c), as: UTF8.self).contains("localId"))
    }

    func testJSONValue() throws {
        let v = try JSONDecoder().decode([JSONValue].self, from: Data(#"[true, 3, "4", "x", [1], {"a": null}, null]"#.utf8))
        XCTAssertEqual(v[0].bool, true)
        XCTAssertEqual(v[1].int, 3)
        XCTAssertNil(v[1].bool)
        XCTAssertEqual(v[2].int, 4)
        XCTAssertEqual(v[3].string, "x")
        XCTAssertNil(v[3].int)
        XCTAssertEqual(v[5], .object(["a": .null]))
        XCTAssertEqual(try JSONDecoder().decode([JSONValue].self, from: JSONEncoder().encode(v)), v)
    }

    func testDisplayText() {
        var login = Cipher(type: .login)
        XCTAssertEqual(login.displayName, "(no name)")
        XCTAssertEqual(login.subtitle, "no username")
        login.login?.username = "me"
        XCTAssertEqual(login.subtitle, "me")

        var card = Cipher(type: .card)
        card.card?.brand = "Visa"; card.card?.number = "4111111111111111"
        XCTAssertEqual(card.subtitle, "Visa, *1111")
        card.card?.brand = nil; card.card?.number = "12"
        XCTAssertEqual(card.subtitle, "")

        var id = Cipher(type: .identity)
        id.identity?.title = "Dr"; id.identity?.firstName = "Ada"; id.identity?.middleName = ""; id.identity?.lastName = "Lovelace"
        XCTAssertEqual(id.subtitle, "Dr Ada Lovelace")

        var note = Cipher(type: .secureNote)
        note.notes = "a\nb" + String(repeating: "x", count: 100)
        XCTAssertEqual(note.subtitle.count, 60)
        XCTAssertTrue(note.subtitle.hasPrefix("a b"))

        var ssh = Cipher(type: .sshKey)
        ssh.sshKey?.keyFingerprint = "SHA256:abc"
        XCTAssertEqual(ssh.subtitle, "SHA256:abc")
    }

    func testPrimaryHostSkipsNonWebURIs() {
        var c = Cipher(type: .login)
        c.login?.uris = [LoginUri(uri: "androidapp://com.x"), LoginUri(uri: nil), LoginUri(uri: "https://Example.com/login")]
        XCTAssertEqual(c.primaryHost, "example.com")
        XCTAssertNil(Cipher(type: .card).primaryHost)
    }

    func testPasswordHistory() {
        var old = Cipher(type: .login)
        old.login?.password = "first"
        old.fields = [Field(name: "PIN", value: "1234", type: .hidden), Field(name: "Note", value: "a")]

        var same = old
        same.recordHistory(from: old)
        XCTAssertEqual(same.passwordHistory?.count, 0)

        var new = old
        new.login?.password = "second"
        new.fields = [Field(name: "PIN", value: "5678", type: .hidden), Field(name: "Note", value: "b")]
        new.recordHistory(from: old)
        XCTAssertEqual(new.passwordHistory?.map(\.password), ["PIN: 1234", "first"])
        XCTAssertNotNil(new.login?.passwordRevisionDate)
        XCTAssertNotNil(Dates.parse(new.passwordHistory?.first?.lastUsedDate))

        var removed = old
        removed.fields = []
        removed.recordHistory(from: old)
        XCTAssertEqual(removed.passwordHistory?.map(\.password), ["PIN: 1234"])

        var c = old
        for i in 0 ..< 8 {
            let prev = c
            c.login?.password = "pw\(i)"
            c.recordHistory(from: prev)
        }
        XCTAssertEqual(c.passwordHistory?.count, 5)
        XCTAssertEqual(c.passwordHistory?.first?.password, "pw6")

        var note = Cipher(type: .secureNote)
        note.recordHistory(from: Cipher(type: .secureNote))
        XCTAssertNil(note.passwordHistory)
        var fresh = Cipher(type: .login)
        fresh.recordHistory(from: nil)
        XCTAssertNil(fresh.passwordHistory)
    }

    func testDatesParseServerFormats() throws {
        let expected = Date(timeIntervalSince1970: 1_767_323_045.123)
        for s in ["2026-01-02T03:04:05.123Z", "2026-01-02T03:04:05.1234567Z", "2026-01-02T03:04:05.123", "2026-01-02T03:04:05.123+00:00"] {
            XCTAssertEqual(try XCTUnwrap(Dates.parse(s), s).timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001, s)
        }
        XCTAssertEqual(Dates.parse("2026-01-02T03:04:05Z")?.timeIntervalSince1970, 1_767_323_045)
        XCTAssertNil(Dates.parse(nil))
        XCTAssertNil(Dates.parse("yesterday"))
        XCTAssertEqual(Dates.parse(Dates.string(expected))?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 0.001)
    }
}
