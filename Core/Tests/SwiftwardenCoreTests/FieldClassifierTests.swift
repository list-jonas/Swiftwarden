@testable import SwiftwardenCore
import XCTest

final class FieldClassifierTests: XCTestCase {
    func k(_ texts: String..., secure: Bool = false, ac: String? = nil) -> FieldKind {
        FieldClassifier.classify(FieldHints(texts: texts, autocomplete: ac, isSecure: secure))
    }

    func testLogin() {
        XCTAssertEqual(k("Email or username"), .username)
        XCTAssertEqual(k("loginEmail"), .username)
        XCTAssertEqual(k("E-Mail-Adresse"), .email)
        XCTAssertEqual(k("Benutzername"), .username)
        XCTAssertEqual(k("user_login"), .username)
        XCTAssertEqual(k("Apple ID"), .username)
        XCTAssertEqual(k("Password", secure: true), .password)
        XCTAssertEqual(k("", secure: true), .password)
        XCTAssertEqual(k("Passwort"), .password)
        XCTAssertEqual(k("whatever", ac: "username"), .username)
        XCTAssertEqual(k("x", secure: true, ac: "current-password"), .password)
    }

    func testCodes() {
        XCTAssertEqual(k("Enter the 6-digit code from your authenticator app"), .totp)
        XCTAssertEqual(k("otp-input"), .totp)
        XCTAssertEqual(k("Bestätigungscode"), .totp)
        XCTAssertEqual(k("Security code"), .totp)
        XCTAssertEqual(k("x", ac: "one-time-code"), .totp)
        XCTAssertEqual(k("PIN", secure: true), .pin)
        XCTAssertEqual(k("pinCode"), .pin)
        XCTAssertEqual(k("Shipping address"), .address1)
        XCTAssertEqual(k("spinner"), .unknown)
        XCTAssertEqual(k("code"), .totp)
        XCTAssertEqual(k("Promo code"), .unknown)
        XCTAssertEqual(k("Postal code"), .postalCode)
    }

    func testCard() {
        XCTAssertEqual(k("Card number"), .cardNumber)
        XCTAssertEqual(k("Kartennummer"), .cardNumber)
        XCTAssertEqual(k("CVC"), .cardCode)
        XCTAssertEqual(k("Card security code"), .cardCode)
        XCTAssertEqual(k("MM / YY"), .cardExpiry)
        XCTAssertEqual(k("Gültig bis"), .cardExpiry)
        XCTAssertEqual(k("expMonth"), .cardExpMonth)
        XCTAssertEqual(k("Name on card"), .cardholder)
        XCTAssertEqual(k("cc-number field", ac: "cc-number"), .cardNumber)
    }

    func testIdentity() {
        XCTAssertEqual(k("Vorname"), .firstName)
        XCTAssertEqual(k("lastName"), .lastName)
        XCTAssertEqual(k("Telefonnummer"), .phone)
        XCTAssertEqual(k("PLZ"), .postalCode)
        XCTAssertEqual(k("Straße und Hausnummer"), .address1)
        XCTAssertEqual(k("City"), .city)
        XCTAssertEqual(k("Firma"), .company)
        XCTAssertEqual(k("Full name"), .fullName)
        XCTAssertEqual(k("Search"), .unknown)
        XCTAssertEqual(k("Message"), .unknown)
    }

    func testCustomField() {
        XCTAssertTrue(FieldClassifier.customFieldMatches("Customer No", hints: FieldHints(texts: ["customerNo"])))
        XCTAssertTrue(FieldClassifier.customFieldMatches("PIN", hints: FieldHints(texts: ["Enter PIN"])))
        XCTAssertFalse(FieldClassifier.customFieldMatches("PIN", hints: FieldHints(texts: ["Shipping"])))
    }
}

