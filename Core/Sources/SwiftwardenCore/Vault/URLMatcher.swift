import Foundation

public enum URLMatcher {
    static let secondLevel: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "com.au", "net.au", "org.au", "edu.au", "co.nz", "org.nz",
        "co.jp", "ne.jp", "or.jp", "com.br", "net.br", "co.at", "or.at", "gv.at", "ac.at", "co.za", "com.tr", "com.mx", "com.cn",
        "com.hk", "com.sg", "com.tw", "co.in", "co.kr", "co.il", "com.ar", "com.co", "com.pl", "co.id", "com.my", "com.ph",
    ]

    public static func host(of uri: String) -> String? {
        var s = uri.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return u.host?.lowercased()
    }

    public static func baseDomain(_ host: String) -> String {
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return host }
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        let last2 = parts.suffix(2).joined(separator: ".")
        if secondLevel.contains(last2) { return parts.suffix(3).joined(separator: ".") }
        return last2
    }

    public static func matches(_ u: LoginUri, url: String, defaultMatch: UriMatch = .domain, equivalents: [[String]] = []) -> Bool {
        guard let raw = u.uri, !raw.isEmpty else { return false }
        switch u.match ?? defaultMatch {
        case .never: return false
        case .exact: return raw == url
        case .startsWith: return url.hasPrefix(raw)
        case .regex: return (try? NSRegularExpression(pattern: raw, options: [.caseInsensitive]))
            .map { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil } ?? false
        case .host:
            guard let a = host(of: raw), let b = host(of: url) else { return false }
            let pa = URL(string: raw.contains("://") ? raw : "https://" + raw)?.port
            let pb = URL(string: url)?.port
            return a == b && pa == pb
        case .domain:
            guard let a = host(of: raw), let b = host(of: url) else { return false }
            let da = baseDomain(a), db = baseDomain(b)
            if da == db { return true }
            return equivalents.contains { $0.contains(da) && $0.contains(db) }
        }
    }

    public static func matchesApp(_ u: LoginUri, bundleId: String, appName: String) -> Bool {
        guard let raw = u.uri?.lowercased(), !raw.isEmpty else { return false }
        let bid = bundleId.lowercased()
        for prefix in ["macapp://", "iosapp://", "androidapp://", "app://"] where raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count)) == bid
        }
        if raw == bid { return true }
        let name = appName.lowercased().replacingOccurrences(of: " ", with: "")
        guard name.count >= 3, let h = host(of: raw) else { return false }
        let label = baseDomain(h).split(separator: ".").first.map(String.init) ?? ""
        let generic: Set<String> = ["com", "org", "net", "io", "app", "apple", "google", "microsoft", "mac", "macos", "desktop", "client", "osx"]
        let parts = bid.split(separator: ".").map(String.init).dropFirst(2).filter { !generic.contains($0) }
        return label == name || (label.count >= 3 && !generic.contains(label) && parts.contains(label))
    }
}

