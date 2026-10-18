import AppKit
import Security

enum AppIdentity {
    static let pinnedTeams: [String: String] = [
        "com.apple.Safari": "apple",
        "com.google.Chrome": "EQHXZ8M8AV", "com.google.Chrome.beta": "EQHXZ8M8AV", "com.google.Chrome.dev": "EQHXZ8M8AV",
        "com.google.Chrome.canary": "EQHXZ8M8AV",
        "com.brave.Browser": "KL8N8XSYF4", "com.brave.Browser.beta": "KL8N8XSYF4",
        "com.microsoft.edgemac": "UBF8T346G9", "com.microsoft.edgemac.Beta": "UBF8T346G9",
        "org.mozilla.firefox": "43AQ936H96", "org.mozilla.firefoxdeveloperedition": "43AQ936H96", "org.mozilla.nightly": "43AQ936H96",
        "org.torproject.torbrowser": "MADPSAYN6T",
        "company.thebrowser.Browser": "A2P9LX4JPN",
        "net.imput.helium": "S4Q33XPHB4",
    ]

    struct Info { let signed: Bool; let team: String? }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [pid_t: (Date?, Info)] = [:]

    static func info(_ app: NSRunningApplication) -> Info {
        let pid = app.processIdentifier
        if let c = lock.withLock({ cache[pid] }), c.0 == app.launchDate { return c.1 }
        let i = inspect(pid)
        lock.withLock { cache[pid] = (app.launchDate, i) }
        return i
    }

    private static func inspect(_ pid: pid_t) -> Info {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess, let code else {
            return Info(signed: false, team: nil)
        }
        func passes(_ req: String) -> Bool {
            var r: SecRequirement?
            guard SecRequirementCreateWithString(req as CFString, [], &r) == errSecSuccess, let r else { return false }
            return SecCodeCheckValidity(code, [], r) == errSecSuccess
        }
        guard passes("anchor apple generic") else { return Info(signed: false, team: nil) }
        var team: String?
        var stat: SecStaticCode?
        var dict: CFDictionary?
        if SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat,
           SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &dict) == errSecSuccess {
            team = (dict as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        }
        if team == nil, passes("anchor apple") { team = "apple" }
        return Info(signed: true, team: team)
    }

    static func isSigned(_ app: NSRunningApplication) -> Bool { info(app).signed }

    static func isVerifiedBrowser(_ app: NSRunningApplication) -> Bool {
        guard let bid = app.bundleIdentifier,
              AutofillController.browsers.contains(bid) || AutofillController.chromiumBrowsers.contains(bid) else { return false }
        let i = info(app)
        guard i.signed, let team = i.team else { return false }
        if let pinned = pinnedTeams[bid] { return pinned == team }
        let key = "browserTeam.\(bid)"
        if let seen = UserDefaults.standard.string(forKey: key) { return seen == team }
        UserDefaults.standard.set(team, forKey: key)
        return true
    }
}


