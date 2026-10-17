import Foundation
@testable import SwiftwardenCore
import XCTest

final class LargeSeedTests: XCTestCase {
    static let domains = """
    google.com youtube.com facebook.com instagram.com twitter.com linkedin.com wikipedia.org amazon.com apple.com microsoft.com netflix.com
    github.com gitlab.com bitbucket.org stackoverflow.com reddit.com pinterest.com tumblr.com dropbox.com box.com slack.com zoom.us notion.so
    figma.com canva.com adobe.com spotify.com soundcloud.com twitch.tv discord.com paypal.com stripe.com shopify.com ebay.com etsy.com
    booking.com airbnb.com uber.com lyft.com doordash.com wolt.com lieferando.at hetzner.com digitalocean.com linode.com vultr.com cloudflare.com
    aws.amazon.com azure.microsoft.com heroku.com vercel.com netlify.com render.com fly.io supabase.com firebase.google.com mongodb.com
    atlassian.com jira.com trello.com asana.com monday.com clickup.com basecamp.com airtable.com zapier.com make.com hubspot.com salesforce.com
    mailchimp.com sendgrid.com twilio.com resend.com postmarkapp.com sentry.io datadoghq.com newrelic.com grafana.com elastic.co docker.com
    npmjs.com pypi.org rubygems.org crates.io jetbrains.com visualstudio.com openai.com anthropic.com perplexity.ai huggingface.co replicate.com
    medium.com substack.com wordpress.com wix.com squarespace.com webflow.com godaddy.com namecheap.com porkbun.com gandi.net ionos.com
    n26.com revolut.com wise.com paysafecard.com klarna.com coinbase.com binance.com kraken.com bitpanda.com raiffeisen.at erstebank.at
    a1.net magenta.at drei.at orf.at derstandard.at willhaben.at oebb.at wienerlinien.at post.at billa.at spar.at hofer.at ikea.com
    zalando.com aboutyou.com hm.com nike.com adidas.com decathlon.com mediamarkt.at saturn.at cyberport.at alternate.at geizhals.at
    steampowered.com epicgames.com ea.com ubisoft.com blizzard.com playstation.com xbox.com nintendo.com humblebundle.com gog.com itch.io
    duolingo.com coursera.org udemy.com khanacademy.org edx.org skillshare.com masterclass.com brilliant.org codecademy.com freecodecamp.org
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init)

    func testSeedLargeVault() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["SW_SEED_EMAIL"], let pw = env["SW_SEED_PASSWORD"], let n = Int(env["SW_LARGE"] ?? "") else { throw XCTSkip("off") }
        let api = APIClient(env: .selfHosted(env["SW_IT_SERVER"] ?? "http://localhost:8787"), deviceId: UUID().uuidString)
        let s = try await VaultService.login(api: api, email: email, password: pw, kdf: try await api.prelogin(email: email).config)
        let svc = VaultService(api: api, keys: KeyRing(userKey: s.userKey))
        _ = try svc.decryptVault(try await svc.fetchSync())
        var batch: [Cipher] = []
        for i in 0 ..< n {
            let d = Self.domains[i % Self.domains.count]
            var c = Cipher(type: .login)
            c.name = d.split(separator: ".").first.map { $0.capitalized + (i >= Self.domains.count ? " \(i / Self.domains.count)" : "") }
            c.login?.username = "user\(i)@example.com"
            c.login?.password = i % 9 == 0 ? "Summer2024!" : Generator.password(PasswordOptions())
            c.login?.uris = [LoginUri(uri: "https://" + d)]
            if i % 6 == 0 { c.login?.totp = "JBSWY3DPEHPK3PXP" }
            c.notes = i % 4 == 0 ? "Account note \(i)" : nil
            batch.append(c)
            if batch.count == 500 {
                try await svc.importVault(ciphers: batch, folders: [], relations: [])
                batch = []
            }
        }
        if !batch.isEmpty { try await svc.importVault(ciphers: batch, folders: [], relations: []) }
    }
}
