import Foundation

public struct ServerEnvironment: Codable, Hashable, Sendable {
    public var base: String?
    public var api: String?
    public var identity: String?
    public var icons: String?
    public var webVault: String?

    public init(base: String? = nil, api: String? = nil, identity: String? = nil, icons: String? = nil, webVault: String? = nil) {
        self.base = base; self.api = api; self.identity = identity; self.icons = icons; self.webVault = webVault
    }

    public static let us = ServerEnvironment(api: "https://api.bitwarden.com", identity: "https://identity.bitwarden.com",
                                             icons: "https://icons.bitwarden.net", webVault: "https://vault.bitwarden.com")
    public static let eu = ServerEnvironment(api: "https://api.bitwarden.eu", identity: "https://identity.bitwarden.eu",
                                             icons: "https://icons.bitwarden.eu", webVault: "https://vault.bitwarden.eu")
    public static func selfHosted(_ url: String) -> ServerEnvironment { ServerEnvironment(base: url) }

    private func trimmed(_ s: String?) -> String? {
        guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public var apiURL: String { trimmed(api) ?? (trimmed(base).map { $0 + "/api" } ?? "https://api.bitwarden.com") }
    public var identityURL: String { trimmed(identity) ?? (trimmed(base).map { $0 + "/identity" } ?? "https://identity.bitwarden.com") }
    public var iconsURL: String { trimmed(icons) ?? (trimmed(base).map { $0 + "/icons" } ?? "https://icons.bitwarden.net") }
    public var webVaultURL: String { trimmed(webVault) ?? trimmed(base) ?? "https://vault.bitwarden.com" }

    public var label: String {
        if self == .us { return "bitwarden.com" }
        if self == .eu { return "bitwarden.eu" }
        return URL(string: webVaultURL)?.host ?? webVaultURL
    }
}
