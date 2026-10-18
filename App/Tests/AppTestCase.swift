import AppKit
import SwiftwardenCore
import XCTest

@MainActor
class AppTestCase: XCTestCase {
    var model: AppModel { AppModel.shared }

    override func setUp() async throws {
        guard !Flavor.bundleId.hasPrefix("com.listjonas.swiftwarden"), !Flavor.name.hasPrefix("Swiftwarden") else {
            XCTFail("Refusing to run: tests would read and write the real app's data (\(Flavor.bundleId))")
            throw XCTSkip()
        }
        _ = NSApplication.shared
        Prefs.d.set(false, forKey: Prefs.autofillEnabled)
        reset()
    }

    override func tearDown() async throws { reset() }

    func reset() {
        let m = model
        m.logout()
        m.health = HealthReport()
        m.hiddenWarnings = []
        m.showHiddenWarnings = false
        m.search = ""
        m.sort = .name
        m.sidebar = .all
        m.errorMessage = nil
        for k in ["pinFailures", Prefs.defaultUriMatch, Prefs.timeoutAction, AutofillPolicy.scopeKey, AutofillPolicy.deniedKey,
                  AutofillPolicy.allowedKey, AutofillPolicy.trustedKey] {
            Prefs.d.removeObject(forKey: k)
        }
        SidebarLayout.shared.reset()
    }

    func item(_ id: String, _ name: String, type: CipherType = .login, user: String? = nil, pw: String? = nil, uri: String? = nil,
              totp: String? = nil, fav: Bool = false, folder: String? = nil, org: String? = nil, deleted: Bool = false) -> Cipher {
        var c = Cipher(type: type)
        c.id = id; c.name = name; c.favorite = fav; c.folderId = folder; c.organizationId = org
        c.login?.username = user; c.login?.password = pw; c.login?.totp = totp
        c.login?.uris = uri.map { [LoginUri(uri: $0)] }
        if deleted { c.deletedDate = "2026-01-01T00:00:00Z" }
        return c
    }

    func names(_ s: SidebarItem?, _ q: String? = nil) -> [String] { model.items(for: s, query: q).map(\.displayName) }

    func beginHealthScan() { model.health.unsecured.insert("__pending") }

    func healthScanFinished() async {
        let m = model
        await waitUntil { !m.health.unsecured.contains("__pending") }
    }

    func waitUntil(_ cond: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0 ..< 300 {
            if cond() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out", file: file, line: line)
    }

    func assertThrows<T>(_ e: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await e(); XCTFail("expected error", file: file, line: line) } catch {}
    }
}
