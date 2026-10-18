import Foundation
import LocalAuthentication
import Security
import SwiftwardenCore

struct StoredAccount: Codable, Equatable {
    var userId: String
    var email: String
    var name: String?
    var env: ServerEnvironment
    var kdf: KdfConfig
    var protectedUserKey: String
    var encryptedPrivateKey: String?
    var pinProtectedUserKey: String?
    var lastSync: Date?
}

enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Flavor.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }()

    static let caches: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(Flavor.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static var account: URL { support.appendingPathComponent("account.json") }
    static var syncCache: URL { support.appendingPathComponent("vault.json") }
    static var generatorHistory: URL { support.appendingPathComponent("generator-history") }
}

enum Store {
    static func loadAccount() -> StoredAccount? {
        guard let d = try? Data(contentsOf: Paths.account) else { return nil }
        return try? JSONDecoder().decode(StoredAccount.self, from: d)
    }

    static func save(_ a: StoredAccount?) {
        if let a, let d = try? JSONEncoder().encode(a) {
            try? d.write(to: Paths.account, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.account.path)
        } else {
            try? FileManager.default.removeItem(at: Paths.account)
        }
    }

    static var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: "deviceId") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "deviceId")
        return id
    }
}

enum Keychain {
    static let service = Flavor.bundleId

    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        delete(account)
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                  kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> Data? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                  kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(_ account: String) {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(q as CFDictionary)
    }

    static func setCodable(_ v: some Encodable, for account: String) {
        if let d = try? JSONEncoder().encode(v) { set(d, for: account) }
    }

    static func getCodable<T: Decodable>(_ t: T.Type, _ account: String) -> T? {
        get(account).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

enum Biometrics {
    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static func authenticate(_ reason: String) async -> Bool {
        let c = LAContext()
        c.localizedFallbackTitle = ""
        return (try? await c.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
    }
}
