import SwiftwardenCore
import XCTest

final class VaultListTests: AppTestCase {
    func passkey() throws -> Fido2Credential { try JSONDecoder().decode(Fido2Credential.self, from: Data("{}".utf8)) }

    func testSidebarSectionsFilterAndCount() throws {
        var shared = item("b", "gitlab", pw: "x", org: "org-1")
        shared.collectionIds = ["col-1"]
        shared.login?.fido2Credentials = [try passkey()]
        var card = item("c", "Visa", type: .card)
        card.card?.brand = "Visa"
        model.ciphers = [
            item("a", "GitHub", user: "octo", uri: "https://github.com", totp: "JBSWY3DPEHPK3PXP", fav: true, folder: "f1"),
            shared, card,
            item("d", "Old", deleted: true),
            item("e", "Wifi", type: .secureNote),
        ]
        let expected: [SidebarItem: Int] = [.all: 4, .trash: 1, .favorites: 1, .codes: 1, .passkeys: 1, .type(.login): 2, .type(.card): 1,
                                            .type(.secureNote): 1, .folder("f1"): 1, .folder(nil): 3, .collection("col-1"): 1,
                                            .organization("org-1"): 1, .personal: 3]
        for (s, n) in expected { XCTAssertEqual(model.count(s), n, "\(s)") }
        XCTAssertEqual(model.count(.security), 0)

        XCTAssertEqual(names(.all), ["GitHub", "gitlab", "Visa", "Wifi"])
        XCTAssertEqual(names(nil), names(.all))
        XCTAssertEqual(names(.trash), ["Old"])
        XCTAssertEqual(names(.favorites), ["GitHub"])
        XCTAssertEqual(names(.codes), ["GitHub"])
        XCTAssertEqual(names(.passkeys), ["gitlab"])
        XCTAssertEqual(names(.type(.card)), ["Visa"])
        XCTAssertEqual(names(.folder(nil)), ["gitlab", "Visa", "Wifi"])
        XCTAssertEqual(names(.collection("col-1")), ["gitlab"])
        XCTAssertEqual(names(.organization("org-1")), ["gitlab"])
        XCTAssertEqual(names(.personal), ["GitHub", "Visa", "Wifi"])
    }

    func testSearchMatchesEveryTermAcrossFields() async {
        var card = item("c", "Company card", type: .card)
        card.card?.brand = "Visa"; card.card?.number = "4111111111111111"
        var id = item("i", "Me", type: .identity)
        id.identity?.email = "ada@example.org"
        let list = [item("a", "GitHub", user: "octo", uri: "https://github.com"), item("b", "Mail", user: "octo@mail.com"),
                    card, id, item("d", "Old GitHub", deleted: true)]
        beginHealthScan()
        model.ciphers = Array(list.dropLast())
        model.upsert(list.last!)
        await healthScanFinished()
        model.search = "octo  git"
        XCTAssertEqual(names(.all), ["GitHub"])
        XCTAssertEqual(names(.all, "GITHUB.COM"), ["GitHub"])
        XCTAssertEqual(names(.all, "visa 1111"), ["Company card"])
        XCTAssertEqual(names(.all, "ada@example"), ["Me"])
        XCTAssertEqual(names(.all, "octo visa"), [])
        XCTAssertEqual(names(.type(.card), "octo"), [])
        XCTAssertEqual(names(.trash, "github"), ["Old GitHub"])
        XCTAssertEqual(names(.all, "  "), ["Company card", "GitHub", "Mail", "Me"])
    }

    func testListFollowsDataAndSortChanges() {
        var a = item("a", "Beta"), b = item("b", "alpha"), c = item("c", "Item 10"), d = item("d", "Item 9")
        a.revisionDate = "2026-03-01T00:00:00Z"; b.revisionDate = "2026-01-01T00:00:00Z"
        c.revisionDate = "2026-02-01T00:00:00Z"; d.revisionDate = "2025-12-01T00:00:00Z"
        a.creationDate = "2020-01-01T00:00:00Z"; b.creationDate = "2024-01-01T00:00:00Z"
        model.ciphers = [a, b, c, d]
        XCTAssertEqual(names(.all), ["alpha", "Beta", "Item 9", "Item 10"])
        model.sort = .modified
        XCTAssertEqual(names(.all), ["Beta", "Item 10", "alpha", "Item 9"])
        model.sort = .created
        XCTAssertEqual(names(.all).prefix(2), ["alpha", "Beta"])

        XCTAssertEqual(names(.favorites), [])
        model.ciphers[1].favorite = true
        XCTAssertEqual(names(.favorites), ["alpha"])
        model.ciphers.removeAll { $0.id == "b" }
        XCTAssertEqual(names(.favorites), [])
    }

    func testSecurityListPutsWorstProblemsFirstAndGroupsReuse() {
        model.ciphers = [
            item("r2", "A shop", pw: "pwB"), item("r1", "B bank", pw: "pwA"), item("w", "C weak", pw: "123"),
            item("r4", "D forum", pw: "pwB"), item("x", "E leaked", pw: "pwX"), item("r3", "F mail", pw: "pwA"),
            item("u", "G http", pw: "fine"), item("ok", "H fine", pw: "fine2"), item("gone", "I gone", pw: "123", deleted: true),
        ]
        var h = HealthReport()
        h.exposed = ["x": 12]
        h.reused = ["r1": 2, "r2": 2, "r3": 2, "r4": 2]
        h.weak = ["w", "x", "gone"]
        h.unsecured = ["u", "w"]
        model.health = h
        XCTAssertEqual(names(.security), ["E leaked", "A shop", "D forum", "B bank", "F mail", "C weak", "G http"])
        XCTAssertEqual(model.count(.security), 7)
        XCTAssertEqual(h.flaggedCount, 8)
        XCTAssertEqual(model.issues(model.cipher("w")!), [.weak, .unsecured])
        XCTAssertEqual(model.issues(model.cipher("x")!).first, .exposed(12))
        XCTAssertEqual(model.reusedWith(model.cipher("r1")!).map(\.id), ["r3"])

        model.setHidden("w", true)
        XCTAssertFalse(names(.security).contains("C weak"))
        XCTAssertEqual(model.count(.security), 6)
        XCTAssertEqual(model.hiddenFlaggedCount, 1)
        model.showHiddenWarnings = true
        XCTAssertTrue(names(.security).contains("C weak"))
        model.setHidden("w", false)
        XCTAssertEqual(model.hiddenFlaggedCount, 0)
    }

    func testHealthScanFindsWeakReusedAndUnsecuredLogins() async {
        let strong = "Xk3!vQ9#mZ2rT8wL"
        var hidden = item("hid", "Hidden", pw: "123")
        hidden.viewPassword = false
        var card = item("card", "Card", type: .card)
        card.card?.code = "123"
        model.health.exposed = ["old": 3]
        model.health.exposedChecked = true
        beginHealthScan()
        model.ciphers = [
                item("personal", "Mail", user: "jonas.list", pw: "jonaslist#77"),
                item("strong", "Bank", user: "me", pw: "Zp4%Kd8&Wq1^Ty6*"),
                item("dup1", "Shop", pw: strong), item("dup2", "Forum", pw: strong), item("dup3", "Gone", pw: strong, deleted: true),
                item("http", "Router", pw: "Rt5$Lm2@Vn8!Qs4#", uri: "HTTP://192.168.1.1"),
                item("empty", "No password"), hidden, card,
        ]
        model.computeHealth()
        await healthScanFinished()
        let h = model.health
        XCTAssertEqual(h.weak, ["personal"])
        XCTAssertEqual(h.reused, ["dup1": 2, "dup2": 2])
        XCTAssertEqual(h.unsecured, ["http"])
        XCTAssertEqual(h.exposed, ["old": 3])
        XCTAssertTrue(h.exposedChecked)
        XCTAssertEqual(model.count(.security), 4)
    }

    func testAutofillMatchesFollowDefaultMatchSetting() {
        model.ciphers = [
            item("gh", "GitHub", uri: "https://github.com"), item("old", "Old", uri: "https://github.com", deleted: true),
            item("slack", "Slack", uri: "https://slack.com"), item("note", "Note", type: .secureNote),
        ]
        XCTAssertEqual(model.matches(url: "https://gist.github.com/x").map(\.id), ["gh"])
        Prefs.d.set(UriMatch.host.rawValue, forKey: Prefs.defaultUriMatch)
        XCTAssertEqual(model.matches(url: "https://gist.github.com/x").map(\.id), [])
        XCTAssertEqual(model.matches(url: "https://github.com/login").map(\.id), ["gh"])
        XCTAssertEqual(model.matches(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack", heuristics: true).map(\.id), ["slack"])
        XCTAssertEqual(model.matches(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack", heuristics: false).map(\.id), [])
    }
}
