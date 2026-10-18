import AppKit
import Security

struct AppEntry: Codable, Hashable, Identifiable {
    var bundleId: String
    var name: String
    var path: String?
    var team: String?
    var id: String { bundleId }

    var icon: NSImage {
        if let p = path, FileManager.default.fileExists(atPath: p) { return NSWorkspace.shared.icon(forFile: p) }
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) { return NSWorkspace.shared.icon(forFile: u.path) }
        return NSWorkspace.shared.icon(for: .application)
    }
}

enum AutofillScope: String, CaseIterable, Identifiable {
    case all, except, only
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All apps"
        case .except: "All apps except…"
        case .only: "Only in…"
        }
    }
}

enum AutofillPolicy {
    static let scopeKey = "autofillScope"
    static let deniedKey = "autofillDeniedApps"
    static let allowedKey = "autofillAllowedApps"
    static let trustedKey = "trustedBrowsers"

    static var scope: AutofillScope {
        get { AutofillScope(rawValue: Prefs.d.string(forKey: scopeKey) ?? "") ?? .all }
        set { Prefs.d.set(newValue.rawValue, forKey: scopeKey) }
    }
    static var denied: [AppEntry] {
        get { Prefs.codable(deniedKey, default: []) }
        set { Prefs.setCodable(deniedKey, newValue) }
    }
    static var allowed: [AppEntry] {
        get { Prefs.codable(allowedKey, default: []) }
        set { Prefs.setCodable(allowedKey, newValue) }
    }
    static var trustedBrowsers: [AppEntry] {
        get { Prefs.codable(trustedKey, default: []) }
        set { Prefs.setCodable(trustedKey, newValue) }
    }

    static func allows(_ bundleId: String?) -> Bool {
        switch scope {
        case .all: return true
        case .except: return !denied.contains { $0.bundleId == bundleId }
        case .only: return allowed.contains { $0.bundleId == bundleId }
        }
    }

    static func isBuiltInBrowser(_ bid: String) -> Bool {
        AutofillController.browsers.contains(bid) || AutofillController.chromiumBrowsers.contains(bid)
    }

    static func trustedTeam(_ bid: String) -> String? {
        trustedBrowsers.first { $0.bundleId == bid }?.team
    }

    static func isBrowser(_ bid: String?) -> Bool {
        guard let bid, !bid.isEmpty else { return false }
        return isBuiltInBrowser(bid) || trustedTeam(bid) != nil
    }

    static func entry(at url: URL) -> AppEntry? {
        guard let b = Bundle(url: url), let bid = b.bundleIdentifier else { return nil }
        let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AppEntry(bundleId: bid, name: name, path: url.path, team: AppIdentity.staticTeam(url))
    }

    static var builtInInstalled: [AppEntry] {
        (AutofillController.browsers.union(AutofillController.chromiumBrowsers)).compactMap { bid in
            guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return nil }
            return AppEntry(bundleId: bid, name: FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: ""), path: u.path)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static var runningApps: [AppEntry] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app -> AppEntry? in
                guard let bid = app.bundleIdentifier, seen.insert(bid).inserted else { return nil }
                return AppEntry(bundleId: bid, name: app.localizedName ?? bid, path: app.bundleURL?.path)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
