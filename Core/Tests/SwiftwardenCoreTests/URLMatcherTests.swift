@testable import SwiftwardenCore
import XCTest

final class URLMatcherTests: XCTestCase {
    func m(_ uri: String, _ url: String, _ match: UriMatch? = nil, def: UriMatch = .domain, eq: [[String]] = []) -> Bool {
        URLMatcher.matches(LoginUri(uri: uri, match: match), url: url, defaultMatch: def, equivalents: eq)
    }

    func testBaseDomainMatching() {
        XCTAssertTrue(m("https://accounts.google.com", "https://mail.google.com/x"))
        XCTAssertTrue(m("google.com", "https://www.google.com"))
        XCTAssertFalse(m("https://google.com", "https://google.com.evil.io"))
        XCTAssertTrue(m("https://apple.com", "https://icloud.com", eq: [["apple.com", "icloud.com"]]))
        XCTAssertFalse(m("https://apple.com", "https://icloud.com", eq: [["apple.com"], ["icloud.com"]]))
        XCTAssertFalse(m("ftp://files.example.com", "https://example.com"))
        XCTAssertFalse(m("", "https://example.com"))
    }

    func testPublicSuffixBoundaries() {
        XCTAssertFalse(m("https://alice.github.io", "https://evil.github.io"))
        XCTAssertFalse(m("https://bank.com.ua", "https://evil.com.ua"))
        XCTAssertTrue(m("https://login.bank.com.ua", "https://www.bank.com.ua"))
        XCTAssertEqual(URLMatcher.baseDomain("a.b.example.co.uk"), "example.co.uk")
        XCTAssertEqual(URLMatcher.baseDomain("www.city.kawasaki.jp"), "city.kawasaki.jp")
        XCTAssertEqual(URLMatcher.baseDomain("a.b.kawasaki.jp"), "a.b.kawasaki.jp")
        XCTAssertEqual(URLMatcher.baseDomain("github.io"), "github.io")
        XCTAssertEqual(URLMatcher.baseDomain("localhost"), "localhost")
        XCTAssertEqual(URLMatcher.baseDomain("nas.home.zzunlisted"), "home.zzunlisted")
        XCTAssertTrue(m("https://nas.home.zzunlisted", "https://router.home.zzunlisted"))
    }

    func testIPAddressesMatchOnlyThemselves() {
        XCTAssertEqual(URLMatcher.baseDomain("192.168.1.1"), "192.168.1.1")
        XCTAssertTrue(m("https://192.168.1.1", "https://192.168.1.1/admin"))
        XCTAssertFalse(m("https://192.168.1.1", "https://10.0.1.1"))
    }

    func testExplicitMatchModes() {
        XCTAssertFalse(m("https://google.com", "https://mail.google.com", .host))
        XCTAssertTrue(m("https://example.com:8443", "https://example.com:8443/a", .host))
        XCTAssertFalse(m("https://example.com:8443", "https://example.com/a", .host))
        XCTAssertTrue(m("https://example.com/app", "https://example.com/app/login", .startsWith))
        XCTAssertFalse(m("https://example.com/app", "https://example.com/other", .startsWith))
        XCTAssertTrue(m("https://example.com/a", "https://example.com/a", .exact))
        XCTAssertFalse(m("https://example.com/a", "https://example.com/a?x", .exact))
        XCTAssertTrue(m("^https://(www\\.)?EXAMPLE\\.com/", "https://www.example.com/x", .regex))
        XCTAssertFalse(m("([", "https://example.com", .regex))
        XCTAssertFalse(m("https://example.com", "https://example.com", .never))
    }

    func testDefaultMatchAppliesOnlyWithoutPerUriSetting() {
        XCTAssertFalse(m("https://example.com", "https://www.example.com", def: .host))
        XCTAssertTrue(m("https://example.com", "https://www.example.com", .domain, def: .host))
    }

    func testAppMatching() {
        func app(_ uri: String, _ bid: String, _ name: String, heuristics: Bool = true) -> Bool {
            URLMatcher.matchesApp(LoginUri(uri: uri), bundleId: bid, appName: name, heuristics: heuristics)
        }
        XCTAssertTrue(app("macapp://com.example.Tool", "com.example.tool", "Tool"))
        XCTAssertFalse(app("macapp://com.example.tool", "com.example.toolkit", "Toolkit"))
        XCTAssertTrue(app("iosapp://com.example.tool", "com.example.tool", "Tool"))
        XCTAssertTrue(app("com.example.tool", "com.example.tool", "Tool"))
        XCTAssertTrue(app("https://slack.com", "com.tinyspeck.slackmacgap", "Slack"))
        XCTAssertTrue(app("https://discord.com", "com.hnc.Discord", "Discord Canary"))
        XCTAssertFalse(app("https://slack.com", "com.tinyspeck.slackmacgap", "Slack", heuristics: false))
        XCTAssertFalse(app("https://apple.com", "com.apple.Notes", "Notes"))
        XCTAssertFalse(app("https://x.com", "com.x.x", "X"))
    }

    func testHostAndLaunchURLs() {
        XCTAssertEqual(URLMatcher.host(of: " Example.COM/path "), "example.com")
        XCTAssertNil(URLMatcher.host(of: "androidapp://com.x"))
        XCTAssertNil(URLMatcher.host(of: ""))
        XCTAssertEqual(URLMatcher.launchURL("example.com/login")?.absoluteString, "https://example.com/login")
        XCTAssertNotNil(URLMatcher.launchURL("ssh://host"))
        XCTAssertNil(URLMatcher.launchURL("file:///Applications/Calculator.app"))
        XCTAssertNil(URLMatcher.launchURL("smb://attacker/share"))
        XCTAssertNil(URLMatcher.launchURL("javascript:alert(1)"))
        XCTAssertNil(URLMatcher.launchURL("   "))
    }
}
