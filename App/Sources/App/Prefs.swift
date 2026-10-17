import Foundation

enum Prefs {
    static let timeoutMinutes = "vaultTimeoutMinutes"
    static let timeoutAction = "vaultTimeoutAction"
    static let lockOnSleep = "lockOnSleep"
    static let lockOnScreenLock = "lockOnScreenLock"
    static let biometricUnlock = "biometricUnlock"
    static let clearClipboard = "clearClipboardSeconds"
    static let showIcons = "showWebsiteIcons"
    static let autofillEnabled = "autofillEnabled"
    static let autofillSuggestions = "autofillSuggestions"
    static let fillMethod = "fillMethod"
    static let autoSubmit = "autofillSubmit"
    static let copyTotpAfterFill = "copyTotpAfterFill"
    static let hotkey = "autofillHotkey"
    static let menuBarIcon = "menuBarIcon"
    static let pinRequireMasterOnRestart = "pinRequireMasterOnRestart"
    static let defaultUriMatch = "defaultUriMatch"
    static let passwordOptions = "generatorPasswordOptions"
    static let passphraseOptions = "generatorPassphraseOptions"
    static let generatorType = "generatorType"
    static let usernameType = "generatorUsernameType"
    static let usernameEmail = "generatorUsernameEmail"
    static let usernameDomain = "generatorUsernameDomain"
    static let appearance = "appearance"
    static let lastServer = "lastServer"
    static let lastEmail = "lastEmail"
    static let detectCompromised = "detectCompromised"

    static func register() {
        UserDefaults.standard.register(defaults: [
            timeoutMinutes: 15, timeoutAction: "lock", lockOnSleep: true, lockOnScreenLock: true, biometricUnlock: false,
            clearClipboard: 30, showIcons: true, autofillEnabled: true, autofillSuggestions: true, fillMethod: "type",
            autoSubmit: false, copyTotpAfterFill: true, hotkey: "cmdShiftL", menuBarIcon: true, pinRequireMasterOnRestart: false,
            defaultUriMatch: 0, detectCompromised: true, generatorType: "password", usernameType: "word", appearance: "system",
        ])
    }

    static var d: UserDefaults { .standard }

    static func codable<T: Codable>(_ key: String, default v: T) -> T {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? v
    }

    static func setCodable(_ key: String, _ v: some Codable) {
        d.set(try? JSONEncoder().encode(v), forKey: key)
    }
}

