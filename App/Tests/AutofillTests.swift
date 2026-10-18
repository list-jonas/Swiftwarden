import AppKit
import SwiftwardenCore
import XCTest

final class AutofillTests: AppTestCase {
    func testScopeDecidesWhereAutofillRuns() {
        XCTAssertTrue(AutofillPolicy.allows("com.any"))
        AutofillPolicy.denied = [AppEntry(bundleId: "com.bad", name: "Bad")]
        AutofillPolicy.allowed = [AppEntry(bundleId: "com.good", name: "Good")]
        XCTAssertTrue(AutofillPolicy.allows("com.bad"))
        AutofillPolicy.scope = .except
        XCTAssertFalse(AutofillPolicy.allows("com.bad"))
        XCTAssertTrue(AutofillPolicy.allows("com.any"))
        AutofillPolicy.scope = .only
        XCTAssertTrue(AutofillPolicy.allows("com.good"))
        XCTAssertFalse(AutofillPolicy.allows("com.any"))
        XCTAssertFalse(AutofillPolicy.allows(nil))
    }

    func testBrowserRecognition() {
        XCTAssertTrue(AutofillPolicy.isBrowser("com.apple.Safari"))
        XCTAssertTrue(AutofillPolicy.isBrowser("com.google.Chrome"))
        XCTAssertFalse(AutofillPolicy.isBrowser("com.example.browser"))
        XCTAssertFalse(AutofillPolicy.isBrowser(nil))
        XCTAssertFalse(AutofillPolicy.isBrowser(""))
        AutofillPolicy.trustedBrowsers = [AppEntry(bundleId: "com.example.browser", name: "Ex", team: "TEAM1")]
        XCTAssertTrue(AutofillPolicy.isBrowser("com.example.browser"))
        XCTAssertEqual(AutofillPolicy.trustedTeam("com.example.browser"), "TEAM1")
        AutofillPolicy.trustedBrowsers = [AppEntry(bundleId: "com.example.unsigned", name: "Ex")]
        XCTAssertFalse(AutofillPolicy.isBrowser("com.example.unsigned"))
    }

    func testAddressBarTextBecomesURL() {
        XCTAssertEqual(AutofillController.normalizedURL(" example.com/login "), "https://example.com/login")
        XCTAssertEqual(AutofillController.normalizedURL("http://intranet.local"), "http://intranet.local")
        XCTAssertEqual(AutofillController.normalizedURL("localhost:3000"), "https://localhost:3000")
        XCTAssertNil(AutofillController.normalizedURL("how to reset password"))
        XCTAssertNil(AutofillController.normalizedURL("bitwarden"))
        XCTAssertNil(AutofillController.normalizedURL(""))
    }

    func testPinFieldValue() {
        var c = item("a", "Bank")
        c.fields = [Field(name: "Remember PIN", value: "true", type: .boolean), Field(name: "Customer No", value: "C-1"),
                    Field(name: "PIN", value: "4711", type: .hidden)]
        XCTAssertEqual(AutofillController.pinValue(c, hints: FieldHints(texts: ["Enter customer no"])), "C-1")
        XCTAssertEqual(AutofillController.pinValue(c, hints: FieldHints(texts: ["Remember PIN"])), "4711")
        XCTAssertEqual(AutofillController.pinValue(c, hints: nil), "4711")
        XCTAssertNil(AutofillController.pinValue(item("b", "None"), hints: nil))
    }

    func target(_ url: String?, kind: FieldKind = .password, signed: Bool = true, app: NSRunningApplication = .current) -> FillTarget {
        FillTarget(app: app, element: AXUIElementCreateSystemWide(), kind: kind, frame: .zero, url: url, verifiedBrowser: url != nil, signed: signed)
    }

    func nativeApp() throws -> NSRunningApplication {
        let apps = NSWorkspace.shared.runningApplications
        return try XCTUnwrap(apps.first { $0.bundleIdentifier == "com.apple.finder" }
            ?? apps.first { ($0.bundleIdentifier ?? "").hasPrefix("com.apple.") && !AutofillPolicy.isBrowser($0.bundleIdentifier) })
    }

    func testCandidatesFitTheFocusedField() {
        var pin = item("pin", "Bank PIN", uri: "https://bank.com")
        pin.fields = [Field(name: "PIN", value: "4711", type: .hidden)]
        var card = item("card", "Visa", type: .card)
        card.card?.number = "4111"
        model.ciphers = [item("plain", "Bank", pw: "pw", uri: "https://bank.com"),
                         item("otp", "Bank 2FA", uri: "https://login.bank.com", totp: "JBSWY3DPEHPK3PXP"),
                         pin, card, item("id", "Me", type: .identity), item("other", "Other", uri: "https://other.com")]
        let ac = AutofillController.shared
        func ids(_ t: FillTarget) -> [String] { ac.candidates(t).map(\.id).sorted() }
        XCTAssertEqual(ids(target("https://www.bank.com/login")), [])
        model.phase = .unlocked
        XCTAssertEqual(ids(target("https://www.bank.com/login")), ["otp", "pin", "plain"])
        XCTAssertEqual(ids(target("https://www.bank.com/login", kind: .totp)), ["otp"])
        XCTAssertEqual(ids(target("https://www.bank.com/login", kind: .pin)), ["pin"])
        XCTAssertEqual(ids(target("https://other.com", kind: .totp)), ["other"])
        XCTAssertEqual(ids(target(nil, kind: .cardNumber)), ["card"])
        XCTAssertEqual(ids(target(nil, kind: .postalCode)), ["id"])
    }

    func testOffersToRememberOnlyNewPlaces() throws {
        let ac = AutofillController.shared
        let app = try nativeApp()
        let bid = try XCTUnwrap(app.bundleIdentifier)
        XCTAssertEqual(ac.rememberURI(for: target("http://intranet.local:8080/login?x=1")), "http://intranet.local")
        XCTAssertEqual(ac.rememberPlace(for: target("https://www.github.com/login")), "www.github.com")
        XCTAssertEqual(ac.rememberURI(for: target(nil, app: app)), "macapp://" + bid)
        XCTAssertNil(ac.rememberURI(for: target(nil, signed: false, app: app)))

        model.phase = .unlocked
        var readOnly = item("ro", "Shared", uri: "https://example.com")
        readOnly.edit = false
        let github = item("gh", "GitHub", uri: "https://github.com")
        let other = item("ex", "Example", uri: "https://example.com")
        model.ciphers = [github, other, readOnly]
        let t = target("https://github.com/login")
        XCTAssertFalse(ac.shouldOfferToRemember(github, t))
        XCTAssertTrue(ac.shouldOfferToRemember(other, t))
        XCTAssertFalse(ac.shouldOfferToRemember(readOnly, t))
        XCTAssertFalse(ac.shouldOfferToRemember(item("n", "Note", type: .secureNote), t))
        XCTAssertFalse(ac.shouldOfferToRemember(other, target(nil, signed: false, app: app)))
        XCTAssertTrue(ac.shouldOfferToRemember(other, target(nil, app: app)))
        var remembered = other
        remembered.login?.uris?.append(LoginUri(uri: "MACAPP://" + bid))
        XCTAssertFalse(ac.shouldOfferToRemember(remembered, target(nil, app: app)))

        AutofillPolicy.trustedBrowsers = [AppEntry(bundleId: bid, name: "Me", team: "T")]
        XCTAssertNil(ac.rememberURI(for: target(nil, app: app)))
    }
}
