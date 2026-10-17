import Foundation

public enum FieldKind: String, Sendable, CaseIterable {
    case password, username, email, totp, pin
    case cardNumber, cardCode, cardExpiry, cardExpMonth, cardExpYear, cardholder
    case firstName, middleName, lastName, fullName, phone, address1, address2, city, state, postalCode, country, company
    case unknown

    public var isLogin: Bool { [.password, .username, .email, .totp, .pin].contains(self) }
    public var isCard: Bool { [.cardNumber, .cardCode, .cardExpiry, .cardExpMonth, .cardExpYear, .cardholder].contains(self) }
    public var isIdentity: Bool {
        [.firstName, .middleName, .lastName, .fullName, .phone, .address1, .address2, .city, .state, .postalCode, .country, .company].contains(self)
    }
}

public struct FieldHints: Sendable {
    public var texts: [String]
    public var autocomplete: String?
    public var isSecure: Bool

    public init(texts: [String], autocomplete: String? = nil, isSecure: Bool = false) {
        self.texts = texts; self.autocomplete = autocomplete; self.isSecure = isSecure
    }
}

public enum FieldClassifier {
    public static func normalize(_ s: String) -> String {
        var out = ""
        var prev: Character = " "
        for ch in s {
            if ch.isUppercase, prev.isLowercase { out.append(" ") }
            if ch.isLetter || ch.isNumber { out.append(Character(ch.lowercased())) } else { out.append(" ") }
            prev = ch
        }
        return " " + out.split(separator: " ").joined(separator: " ") + " "
    }

    static let autocompleteMap: [String: FieldKind] = [
        "username": .username, "email": .email, "current-password": .password, "new-password": .password, "password": .password,
        "one-time-code": .totp, "cc-number": .cardNumber, "cc-csc": .cardCode, "cc-exp": .cardExpiry, "cc-exp-month": .cardExpMonth,
        "cc-exp-year": .cardExpYear, "cc-name": .cardholder, "given-name": .firstName, "additional-name": .middleName,
        "family-name": .lastName, "name": .fullName, "tel": .phone, "tel-national": .phone, "street-address": .address1,
        "address-line1": .address1, "address-line2": .address2, "address-level2": .city, "address-level1": .state,
        "postal-code": .postalCode, "country": .country, "country-name": .country, "organization": .company,
    ]

    static let rules: [(FieldKind, [String])] = [
        (.totp, ["one time code", "one time password", "onetimecode", "otp", "totp", "2fa", "mfa", "two factor", "2 factor", "verification code",
                 "verify code", "authenticator", "auth code", "authentication code", "otc", "einmalcode", "einmalpasswort", "bestatigungscode",
                 "bestätigungscode", "verifizierungscode", "authentifizierungscode", "sms code", "code from", "6 digit", "6 stelligen", "mfacode",
                 "totpcode", "otpcode", "twofactor"]),
        (.pin, ["pin", "pincode", "pin code", "passcode", "pin nummer", "geheimzahl"]),
        (.cardCode, ["cvc", "cvv", "cvv2", "cvc2", "csc", "card verification", "card code", "security code card", "kartenprufnummer",
                     "kartenprüfnummer", "prufnummer", "prüfnummer", "prufziffer", "prüfziffer", "cardcvc", "cardcvv", "cccsc", "cc csc"]),
        (.cardNumber, ["card number", "cardnumber", "credit card", "creditcard", "debit card", "ccnumber", "cc number", "ccnum", "cardnum",
                       "kartennummer", "kreditkartennummer", "kreditkarte", "pan"]),
        (.cardExpMonth, ["exp month", "expmonth", "expiry month", "expiration month", "cc month", "ccmonth", "ablaufmonat", "exp mm", "card month"]),
        (.cardExpYear, ["exp year", "expyear", "expiry year", "expiration year", "cc year", "ccyear", "ablaufjahr", "exp yy", "exp yyyy", "card year"]),
        (.cardExpiry, ["expiry", "expiration", "exp date", "expdate", "mm yy", "mm jj", "ablaufdatum", "gultig bis", "gültig bis", "valid thru",
                       "valid through", "ccexp", "cc exp", "ablauf"]),
        (.cardholder, ["cardholder", "card holder", "name on card", "nameoncard", "karteninhaber", "ccname", "cc name", "card name", "holder name"]),
    ]

    static let passwordWords = ["password", "passwort", "kennwort", "passwd", "pwd", "pass"]
    static let usernameWords = ["user", "username", "user name", "login", "login name", "account", "account name", "benutzer", "benutzername",
                                "anmeldename", "nutzername", "userid", "user id", "loginid", "login id", "identifier", "kundennummer",
                                "customer number", "member", "mitgliedsnummer", "handle", "nickname", "screen name", "sign in", "signin", "anmelden",
                                "uname", "usr", "konto", "kennung", "id"]
    static let emailWords = ["email", "e mail", "mail", "emailaddress", "mailaddress", "e mail adresse", "mailadresse"]

    static let identityRules: [(FieldKind, [String])] = [
        (.firstName, ["first name", "firstname", "given name", "givenname", "fname", "forename", "vorname"]),
        (.middleName, ["middle name", "middlename", "mname", "zweiter vorname"]),
        (.lastName, ["last name", "lastname", "surname", "family name", "familyname", "lname", "nachname", "familienname"]),
        (.fullName, ["full name", "fullname", "your name", "dein name", "ihr name", "vollständiger name", "name"]),
        (.phone, ["phone", "telephone", "tel", "mobile", "cell", "handy", "telefon", "telefonnummer", "mobilnummer", "phonenumber", "mobilephone"]),
        (.address2, ["address2", "address 2", "address line 2", "addressline2", "apartment", "apt", "suite", "adresszusatz", "zusatz"]),
        (.address1, ["street", "address", "addr", "address1", "address line 1", "addressline1", "adresse", "straße", "strasse", "anschrift", "hausnummer"]),
        (.postalCode, ["zip", "zipcode", "zip code", "postal", "postcode", "postal code", "postalcode", "plz", "postleitzahl"]),
        (.city, ["city", "town", "stadt", "ort", "wohnort", "locality", "gemeinde"]),
        (.state, ["state", "province", "region", "bundesland", "county", "kanton"]),
        (.country, ["country", "land", "staat", "countrycode"]),
        (.company, ["company", "organization", "organisation", "firma", "unternehmen", "firmenname", "business name"]),
    ]

    static func has(_ norm: String, _ words: [String]) -> Bool {
        words.contains { norm.contains(" " + normalize($0).trimmingCharacters(in: .whitespaces) + " ") }
    }

    public static func classify(_ h: FieldHints) -> FieldKind {
        if let ac = h.autocomplete?.lowercased() {
            for part in ac.split(separator: " ").reversed() {
                if let k = autocompleteMap[String(part)] { return h.isSecure && !k.isLogin && k != .cardCode ? .password : k }
            }
        }
        let norm = normalize(h.texts.joined(separator: " "))
        let cardContext = has(norm, ["card", "karte", "kreditkarte", "cc", "credit", "kredit"])
        if has(norm, ["security code", "sicherheitscode"]) { return cardContext ? .cardCode : .totp }
        for (kind, words) in rules where has(norm, words) {
            if kind == .pin, has(norm, ["spin", "shipping", "pinterest"]) { continue }
            if kind == .cardNumber, !cardContext, !has(norm, words.filter { $0 != "pan" }) { continue }
            return kind
        }
        if h.isSecure { return .password }
        if has(norm, passwordWords) { return .password }
        let user = has(norm, usernameWords.filter { $0 != "id" }) || (has(norm, ["id"]) && norm.split(separator: " ").count <= 3)
        if user { return .username }
        if has(norm, emailWords) { return .email }
        for (kind, words) in identityRules where has(norm, words) { return kind }
        if has(norm, ["code", "token", "verification", "verify", "bestatigung", "bestätigung", "verifizierung", "auth"]),
           !has(norm, ["promo", "promotion", "coupon", "gutschein", "rabatt", "discount", "voucher", "area", "country", "invite", "invitation",
                       "referral", "einladung", "gift", "source", "qr"]) {
            return .totp
        }
        return .unknown
    }

    public static func customFieldMatches(_ fieldName: String, hints: FieldHints) -> Bool {
        let name = normalize(fieldName).trimmingCharacters(in: .whitespaces)
        guard name.count >= 2 else { return false }
        let norm = normalize(hints.texts.joined(separator: " "))
        if norm.contains(" " + name + " ") { return true }
        let squashed = name.replacingOccurrences(of: " ", with: "")
        return squashed.count >= 5 && norm.replacingOccurrences(of: " ", with: "").contains(squashed)
    }
}



