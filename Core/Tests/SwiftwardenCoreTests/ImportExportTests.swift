import Foundation
@testable import SwiftwardenCore
import XCTest

final class ImportExportTests: XCTestCase {
    func login(_ name: String, user: String? = nil, pw: String? = nil, uris: [String] = [], folder: String? = nil) -> Cipher {
        var c = Cipher(type: .login)
        c.name = name; c.login?.username = user; c.login?.password = pw; c.folderId = folder
        c.login?.uris = uris.map { LoginUri(uri: $0) }
        return c
    }

    func testCSVParsingQuotesAndNewlines() throws {
        let r = try Importer.detect(Data("name,url,username,password,note\r\n\"A, B\",https://a.com,u,\"p\"\"q\",\"line1\nline2\"\r\n\n".utf8))
        XCTAssertEqual(r.ciphers.count, 1)
        XCTAssertEqual(r.ciphers[0].name, "A, B")
        XCTAssertEqual(r.ciphers[0].login?.password, "p\"q")
        XCTAssertEqual(r.ciphers[0].notes, "line1\nline2")
    }

    func testCSVExportImportRoundTrip() throws {
        var a = login("Mail, \"work\"", user: "me@x.com", pw: "p,w\"1", uris: ["https://a.com", "https://b.com"], folder: "f1")
        a.notes = "line1\nline2"; a.favorite = true; a.login?.totp = "JBSWY3DPEHPK3PXP"
        a.fields = [Field(name: "PIN", value: "1234", type: .hidden), Field(name: "Customer", value: "a: b")]
        var note = Cipher(type: .secureNote)
        note.name = "Wifi"; note.notes = "SSID: x"
        var card = Cipher(type: .card); card.name = "Visa"
        var gone = login("Old"); gone.deletedDate = "2026-01-01T00:00:00Z"
        let csv = Exporter.csv(ciphers: [a, note, card, gone], folders: [Folder(id: "f1", name: "Work")])

        let r = try Importer.detect(Data(csv.utf8))
        XCTAssertEqual(r.ciphers.map(\.name), ["Mail, \"work\"", "Wifi"])
        let x = r.ciphers[0]
        XCTAssertEqual(x.login?.username, "me@x.com")
        XCTAssertEqual(x.login?.password, "p,w\"1")
        XCTAssertEqual(x.login?.totp, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(x.login?.uris?.compactMap(\.uri), ["https://a.com", "https://b.com"])
        XCTAssertEqual(x.notes, "line1\nline2")
        XCTAssertTrue(x.isFavorite)
        XCTAssertEqual(x.fields?.map(\.name), ["PIN", "Customer"])
        XCTAssertEqual(x.fields?.map(\.value), ["1234", "a: b"])
        XCTAssertEqual(r.ciphers[1].type, .secureNote)
        XCTAssertNil(r.ciphers[1].login)
        XCTAssertEqual(r.folders, ["Work"])
        XCTAssertEqual(r.relations.map(\.cipher), [0])
    }

    func testCSVFromOtherManagers() throws {
        let lastPass = "url,username,password,totp,extra,name,grouping,fav\nhttps://github.com/login,octo,pw,,n,GitHub,Dev,1\nhttps://gitlab.com,,pw2,,,,Dev,0\n"
        let r = try Importer.detect(Data(lastPass.utf8))
        XCTAssertEqual(r.ciphers.map(\.name), ["GitHub", "gitlab.com"])
        XCTAssertEqual(r.ciphers.map(\.isFavorite), [true, false])
        XCTAssertEqual(r.folders, ["Dev"])
        XCTAssertEqual(r.relations.map(\.folder), [0, 0])

        let onePassword = "Title,Website,Username,Password,OTPAuth,Notes\nBank,bank.com,me,secret,otpauth://totp/x?secret=JBSWY3DPEHPK3PXP,\n"
        let o = try Importer.detect(Data(onePassword.utf8)).ciphers[0]
        XCTAssertEqual(o.name, "Bank")
        XCTAssertEqual(o.login?.password, "secret")
        XCTAssertNotNil(o.login?.totp)
        XCTAssertNil(o.notes)

        let latin1 = try XCTUnwrap("name,password\nCaf\u{e9},x\n".data(using: .isoLatin1))
        XCTAssertEqual(try Importer.detect(latin1).ciphers.first?.name, "Café")
    }

    func testRejectsUnknownFiles() {
        XCTAssertThrowsError(try Importer.detect(Data("a,b,c\n1,2,3\n".utf8)))
        XCTAssertThrowsError(try Importer.detect(Data()))
        let restricted = try! JSONSerialization.data(withJSONObject: ["encrypted": true, "data": "2.x|y|z"])
        XCTAssertThrowsError(try Importer.detect(restricted)) { XCTAssertEqual($0 as? ImportExportError, .accountRestricted) }
        XCTAssertFalse(Importer.needsPassword(restricted))
        XCTAssertFalse(Importer.needsPassword(Data("name,password".utf8)))
    }

    func testJSONExportImportRoundTrip() throws {
        var a = login("GitHub", user: "octo", pw: "pw", uris: ["https://github.com"], folder: "f1")
        a.id = "server-id"; a.key = "2.k|k|k"; a.revisionDate = "2026-01-01T00:00:00Z"; a.organizationId = "org"; a.collectionIds = ["c"]
        a.fields = [Field(name: "PIN", value: "1", type: .hidden)]
        var card = Cipher(type: .card)
        card.name = "Visa"; card.card?.number = "4111111111111111"
        var gone = login("Old"); gone.deletedDate = "2026-01-01T00:00:00Z"
        let data = try Exporter.json(ciphers: [a, card, gone], folders: [Folder(id: "f1", name: "Work")])

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try XCTUnwrap(root["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items[0]["key"])
        XCTAssertNil(items[0]["revisionDate"])
        XCTAssertTrue(items[1]["folderId"] is NSNull)
        XCTAssertFalse(Importer.needsPassword(data))

        let r = try Importer.detect(data)
        XCTAssertEqual(r.ciphers.map(\.name), ["GitHub", "Visa"])
        let x = r.ciphers[0]
        XCTAssertEqual(x.id, "")
        XCTAssertNil(x.organizationId)
        XCTAssertNil(x.folderId)
        XCTAssertNil(x.collectionIds)
        XCTAssertEqual(x.login?.password, "pw")
        XCTAssertEqual(x.fields?.first?.type, .hidden)
        XCTAssertEqual(r.ciphers[1].card?.number, "4111111111111111")
        XCTAssertEqual(r.folders, ["Work"])
        XCTAssertEqual(r.relations.map(\.cipher), [0])
    }

    func testPasswordProtectedExport() throws {
        let c = login("x", pw: "pw")
        for kdf in [KdfConfig(type: 0, iterations: 5000), KdfConfig(type: 1, iterations: 2, memory: 16, parallelism: 1)] {
            let d = try Exporter.encryptedJSON(ciphers: [c], folders: [], password: "filepw", kdf: kdf)
            XCTAssertFalse(String(decoding: d, as: UTF8.self).contains("\"pw\""))
            XCTAssertTrue(Importer.needsPassword(d))
            XCTAssertEqual(try Importer.detect(d, password: "filepw").ciphers.first?.login?.password, "pw")
            XCTAssertThrowsError(try Importer.detect(d, password: "nope")) { XCTAssertEqual($0 as? ImportExportError, .wrongPassword) }
            XCTAssertThrowsError(try Importer.detect(d)) { XCTAssertEqual($0 as? ImportExportError, .wrongPassword) }
        }
    }
}
