import Foundation

enum Flavor {
    static let bundleId = Bundle.main.bundleIdentifier ?? "com.listjonas.swiftwarden"
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Swiftwarden"
    static let isDev = bundleId.hasSuffix(".dev")
}
