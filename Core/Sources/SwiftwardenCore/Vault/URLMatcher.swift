import Foundation

enum PublicSuffix {
    struct Rules { var exact = Set<String>(); var wildcard = Set<String>(); var exception = Set<String>() }

    static let rules: Rules = {
        var r = Rules()
        guard let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return r }
        for line in s.split(whereSeparator: \.isNewline) {
            let rule = line.lowercased()
            if rule.hasPrefix("!") { r.exception.insert(String(rule.dropFirst())) }
            else if rule.hasPrefix("*.") { r.wildcard.insert(String(rule.dropFirst(2))) }
            else { r.exact.insert(rule) }
        }
        return r
    }()

    static func suffixLabelCount(_ labels: [Substring]) -> Int {
        let r = rules, n = labels.count
        for i in 0 ..< n {
            let cand = labels[i...].joined(separator: ".")
            if r.exception.contains(cand) { return n - i - 1 }
            if r.exact.contains(cand) { return n - i }
            if i + 1 < n, r.wildcard.contains(labels[(i + 1)...].joined(separator: ".")) { return n - i }
        }
        return 1
    }
}

public enum URLMatcher {
    static let launchSchemes: Set<String> = ["http", "https", "ssh", "ftp", "sftp", "irc", "vnc"]

    public static func launchURL(_ uri: String?) -> URL? {
        guard let s = uri?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
              let u = URL(string: s.contains("://") ? s : "https://" + s),
              let scheme = u.scheme?.lowercased(), launchSchemes.contains(scheme), u.host?.isEmpty == false else { return nil }
        return u
    }

    public static func host(of uri: String) -> String? {
        var s = uri.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return u.host?.lowercased()
    }

    public static func baseDomain(_ host: String) -> String {
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return host }
        let labels = host.lowercased().split(separator: ".")
        guard labels.count > 1 else { return host }
        let keep = PublicSuffix.suffixLabelCount(labels) + 1
        return keep >= labels.count ? labels.joined(separator: ".") : labels.suffix(keep).joined(separator: ".")
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

    public static func matchesApp(_ u: LoginUri, bundleId: String, appName: String, heuristics: Bool = true) -> Bool {
        guard let raw = u.uri?.lowercased(), !raw.isEmpty else { return false }
        let bid = bundleId.lowercased()
        for prefix in ["macapp://", "iosapp://", "androidapp://", "app://"] where raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count)) == bid
        }
        if raw == bid { return true }
        guard heuristics else { return false }
        let name = appName.lowercased().replacingOccurrences(of: " ", with: "")
        guard name.count >= 3, let h = host(of: raw) else { return false }
        let label = baseDomain(h).split(separator: ".").first.map(String.init) ?? ""
        let generic: Set<String> = ["com", "org", "net", "io", "app", "apple", "google", "microsoft", "mac", "macos", "desktop", "client", "osx"]
        let parts = bid.split(separator: ".").map(String.init).dropFirst(2).filter { !generic.contains($0) }
        return label == name || (label.count >= 3 && !generic.contains(label) && parts.contains(label))
    }
}

