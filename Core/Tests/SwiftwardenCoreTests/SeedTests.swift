import Foundation
@testable import SwiftwardenCore
import XCTest

final class SeedTests: XCTestCase {
    func testSeedDemoVault() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["SW_SEED_EMAIL"], let pw = env["SW_SEED_PASSWORD"] else { throw XCTSkip("seed off") }
        let api = APIClient(env: .selfHosted(env["SW_IT_SERVER"] ?? "http://localhost:8787"), deviceId: UUID().uuidString)
        try? await VaultService.register(api: api, email: email, name: "Demo", password: pw, hint: "", kdf: .pbkdf2Default)
        let pre = try await api.prelogin(email: email)
        let s = try await VaultService.login(api: api, email: email, password: pw, kdf: pre.config)
        let svc = VaultService(api: api, keys: KeyRing(userKey: s.userKey))
        _ = try svc.decryptVault(try await svc.fetchSync())
        let work = try await svc.saveFolder(id: nil, name: "Work")
        let personal = try await svc.saveFolder(id: nil, name: "Personal")
        let items: [(String, String, String, String, Bool)] = [
            ("AWS", "contact@example.com", "https://signin.aws.amazon.com", "JBSWY3DPEHPK3PXP", true),
            ("Amazon Business", "contact@example.com", "https://business.amazon.com", "", false),
            ("amazon.de", "contact@example.com", "https://amazon.de", "", false),
            ("apify.com", "contact@example.com", "https://apify.com", "", false),
            ("Azure", "contact@example.com", "https://portal.azure.com", "GEZDGNBVGY3TQOJQ", false),
            ("backblaze.com", "contact@example.com", "https://backblaze.com", "", false),
            ("Canva", "jonas@example.com", "https://canva.com", "", true),
            ("GitHub", "list-jonas", "https://github.com/login", "KRSXG5CTMVRXEZLU", true),
            ("Figma", "jonas@example.com", "https://figma.com", "", false),
            ("Fiskaly", "jonas", "https://fiskaly.com", "", false),
            ("FortiGate", "admin", "https://192.168.1.1", "", false),
            ("Google", "jonas@gmail.com", "https://accounts.google.com", "MFRGGZDFMZTWQ2LK", true),
            ("Hetzner", "jonas@example.com", "https://accounts.hetzner.com", "", false),
            ("Netflix", "jonas@example.com", "https://netflix.com", "", false),
            ("Slack", "jonas@example.com", "https://slack.com", "", false),
            ("Stripe", "billing@example.com", "https://dashboard.stripe.com", "ONSWG4TFOQ", false),
            ("Old Forum", "jonas", "http://forum.example.org", "", false),
        ]
        for (i, it) in items.enumerated() {
            var c = Cipher(type: .login)
            c.name = it.0
            c.login?.username = it.1
            c.login?.uris = [LoginUri(uri: it.2)]
            c.login?.totp = it.3.isEmpty ? nil : it.3
            c.login?.password = i % 5 == 0 ? "Password123!" : i % 7 == 0 ? "reused-Secret-42" : Generator.password(PasswordOptions())
            if i == 3 || i == 10 { c.login?.password = "reused-Secret-42" }
            c.favorite = it.4
            c.folderId = i % 2 == 0 ? work.id : personal.id
            c.notes = i == 0 ? "Root account. MFA required." : nil
            _ = try await svc.save(c)
        }
        var card = Cipher(type: .card)
        card.name = "Visa Business"; card.card?.cardholderName = "Jonas List"; card.card?.brand = "Visa"
        card.card?.number = "4111111111111111"; card.card?.expMonth = "8"; card.card?.expYear = "2029"; card.card?.code = "123"
        _ = try await svc.save(card)
        var id = Cipher(type: .identity)
        id.name = "Personal ID"; id.identity?.firstName = "Jonas"; id.identity?.lastName = "List"; id.identity?.email = "jonas@example.com"
        id.identity?.city = "Vienna"; id.identity?.country = "AT"
        _ = try await svc.save(id)
        var note = Cipher(type: .secureNote)
        note.name = "Wi-Fi Office"; note.notes = "SSID: office\nPassword: correct-horse-battery"
        _ = try await svc.save(note)
        var ssh = Cipher(type: .sshKey)
        ssh.name = "Deploy key"; ssh.sshKey = SSHKeyGen.ed25519(comment: "deploy@swiftwarden")
        _ = try await svc.save(ssh)
    }
}
