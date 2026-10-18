import Foundation
@testable import SwiftwardenCore
import XCTest

final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var body = Data()
        var delay: TimeInterval = 0

        static func json(_ o: Any, status: Int = 200) -> Reply {
            Reply(status: status, body: try! JSONSerialization.data(withJSONObject: o, options: [.fragmentsAllowed]))
        }

        static func text(_ s: String, status: Int = 200) -> Reply { Reply(status: status, body: Data(s.utf8)) }
    }

    struct Recorded {
        let request: URLRequest
        let body: Data
        var method: String { request.httpMethod ?? "GET" }
        var path: String { request.url?.path ?? "" }
        var url: String { request.url?.absoluteString ?? "" }
        func header(_ h: String) -> String? { request.value(forHTTPHeaderField: h) }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var form: [String: String] {
            var out: [String: String] = [:]
            for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                out[kv[0]] = kv.count > 1 ? kv[1].removingPercentEncoding : ""
            }
            return out
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((Recorded) -> Reply)?
    nonisolated(unsafe) private static var _log: [Recorded] = []

    static var handler: ((Recorded) -> Reply)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue; _log = [] } }
    }

    static var log: [Recorded] { lock.withLock { _log } }

    static func session() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return c
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            s.close()
        }
        let rec = Recorded(request: request, body: body)
        let reply = Self.lock.withLock { () -> Reply in
            Self._log.append(rec)
            return Self._handler?(rec) ?? Reply(status: 599, body: Data("no stub for \(rec.method) \(rec.path)".utf8))
        }
        let finish = { [self] in
            let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: finish) } else { finish() }
    }
}

class StubbedTestCase: XCTestCase {
    static let server = "https://vault.test"

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func client(_ env: ServerEnvironment = .selfHosted(server), tokens: Tokens? = nil) -> APIClient {
        APIClient(env: env, deviceId: "device-1", tokens: tokens, configuration: StubURLProtocol.session())
    }

    func validTokens(access: String = "access-1", refresh: String? = "refresh-1") -> Tokens {
        Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(3600))
    }
}

struct Account {
    let email = "alice@example.com"
    let password = "correct horse battery"
    let kdf = KdfConfig(type: 0, iterations: 5000)
    let userId = "user-1"
    let userKey = SymmetricCryptoKey.generate()
    let orgKey = SymmetricCryptoKey.generate()
    let rsa: (privatePKCS8: Data, publicSPKI: Data)
    let masterKey: Data
    let protectedUserKey: String
    let encryptedPrivateKey: String
    let serverPasswordHash: String

    static let shared = try! Account()

    init() throws {
        rsa = try RSA.generate()
        masterKey = try KeyDerivation.masterKey(password: password, email: email, kdf: kdf)
        protectedUserKey = try KeyDerivation.protectUserKey(userKey, with: masterKey)
        encryptedPrivateKey = try EncString.encrypt(rsa.privatePKCS8, key: userKey).description
        serverPasswordHash = try Primitives.pbkdf2(password: masterKey, salt: Data(password.utf8), iterations: 1).base64EncodedString()
    }

    func enc(_ s: String, _ key: SymmetricCryptoKey? = nil) -> String { try! EncString.encrypt(s, key: key ?? userKey).description }
    func dec(_ s: Any?, _ key: SymmetricCryptoKey? = nil) -> String? {
        (s as? String).flatMap { try? EncString($0).decryptString(key: key ?? userKey) }
    }

    func profile(orgs: [[String: Any]] = []) -> [String: Any] {
        ["id": userId, "email": email, "name": "Alice", "key": protectedUserKey, "privateKey": encryptedPrivateKey, "organizations": orgs]
    }

    func orgEntry(_ id: String = "org-1", name: String = "Acme") throws -> [String: Any] {
        let wrapped = try RSA.encrypt(orgKey.data, publicKey: RSA.publicKey(der: rsa.publicSPKI)).description
        return ["id": id, "name": name, "key": wrapped, "enabled": true]
    }

    func service(_ api: APIClient, withPrivateKey: Bool = true) throws -> VaultService {
        let svc = VaultService(api: api, keys: KeyRing(userKey: userKey))
        if withPrivateKey {
            let p = try JSON.decoder.decode(Profile.self, from: JSONSerialization.data(withJSONObject: profile(orgs: [orgEntry()])))
            svc.loadKeys(profile: p, encryptedPrivateKey: nil)
        }
        return svc
    }
}

extension StubURLProtocol.Recorded {
    func echoCipher(id: String) -> StubURLProtocol.Reply {
        var o = json
        if let inner = o["cipher"] as? [String: Any] { o = inner }
        o["id"] = id
        o["revisionDate"] = "2026-01-01T00:00:00Z"
        return .json(o)
    }
}
