import Foundation

public enum APIError: LocalizedError {
    case http(Int, String)
    case twoFactorRequired(providers: [Int], info: [String: JSONValue])
    case newDeviceVerification
    case captcha
    case unauthorized
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case let .http(code, msg): msg.isEmpty ? "Server error (\(code))" : msg
        case .twoFactorRequired: "Two-step login required"
        case .newDeviceVerification: "New device verification required. Check your email for a code."
        case .captcha: "Captcha required"
        case .unauthorized: "Session expired. Please log in again."
        case .invalidResponse: "Invalid server response"
        }
    }
}

public struct PreloginResponse: Codable, Sendable {
    public var kdf: Int
    public var kdfIterations: Int
    public var kdfMemory: Int?
    public var kdfParallelism: Int?
    public var config: KdfConfig { KdfConfig(type: kdf, iterations: kdfIterations, memory: kdfMemory, parallelism: kdfParallelism) }
}

public struct TokenResponse: Codable, Sendable {
    public var accessToken: String
    public var expiresIn: Int?
    public var refreshToken: String?
    public var key: String?
    public var privateKey: String?
    public var kdf: Int?
    public var kdfIterations: Int?
    public var kdfMemory: Int?
    public var kdfParallelism: Int?
    public var twoFactorToken: String?
    public var forcePasswordReset: Bool?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", expiresIn = "expires_in", refreshToken = "refresh_token"
        case key, privateKey, kdf, kdfIterations, kdfMemory, kdfParallelism, twoFactorToken, forcePasswordReset
    }
}

public struct Tokens: Codable, Sendable {
    public var access: String
    public var refresh: String?
    public var expires: Date
    public var clientId: String?
    public var clientSecret: String?
}

public struct ErrorBody: Codable {
    var message: String?
    var error: String?
    var errorDescription: String?
    var errorModel: Inner?
    var validationErrors: [String: [String]]?
    var twoFactorProviders2: [String: JSONValue]?
    var twoFactorProviders: [JSONValue]?
    struct Inner: Codable { var message: String? }

    enum CodingKeys: String, CodingKey {
        case message, error, errorDescription = "error_description", errorModel, validationErrors, twoFactorProviders2, twoFactorProviders
    }

    var text: String {
        if let v = validationErrors?.values.flatMap({ $0 }).first, !v.isEmpty { return v }
        return errorModel?.message ?? message ?? errorDescription ?? error ?? ""
    }
}

struct FirstLowerKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) {
        if let f = stringValue.first, f.isUppercase, !stringValue.contains("_") {
            self.stringValue = f.lowercased() + stringValue.dropFirst()
        } else {
            self.stringValue = stringValue
        }
    }
    init(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

public enum JSON {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { FirstLowerKey(stringValue: $0.last!.stringValue) }
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

public final class APIClient: @unchecked Sendable {
    public var env: ServerEnvironment
    public let deviceId: String
    public var tokens: Tokens?
    public var onTokensChanged: ((Tokens?) -> Void)?
    let session: URLSession
    private let lock = NSLock()
    private var refreshTask: Task<Void, Error>?

    public static let clientName = "desktop"
    public static let clientVersion = "2025.10.0"
    public static let deviceType = 7

    public init(env: ServerEnvironment, deviceId: String, tokens: Tokens? = nil) {
        self.env = env
        self.deviceId = deviceId
        self.tokens = tokens
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.httpAdditionalHeaders = ["Bitwarden-Client-Name": Self.clientName, "Bitwarden-Client-Version": Self.clientVersion,
                                     "Device-Type": String(Self.deviceType)]
        session = URLSession(configuration: cfg)
    }

    func check(_ data: Data, _ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = try? JSON.decoder.decode(ErrorBody.self, from: data)
            if http.statusCode == 401 { throw APIError.unauthorized }
            if let p = body?.twoFactorProviders2 {
                throw APIError.twoFactorRequired(providers: p.keys.compactMap(Int.init).sorted(), info: p)
            }
            if body?.error == "device_error" || (body?.errorDescription ?? "").localizedCaseInsensitiveContains("new device verification") {
                throw APIError.newDeviceVerification
            }
            throw APIError.http(http.statusCode, body?.text ?? String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
    }

    public func prelogin(email: String) async throws -> PreloginResponse {
        for base in [env.identityURL + "/accounts/prelogin", env.apiURL + "/accounts/prelogin"] {
            var req = URLRequest(url: URL(string: base)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSON.encoder.encode(["email": email])
            let (data, resp) = try await session.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 404 { continue }
            try check(data, resp)
            return try JSON.decoder.decode(PreloginResponse.self, from: data)
        }
        throw APIError.invalidResponse
    }

    static func form(_ f: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(f.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }

    public func token(_ fields: [String: String], email: String? = nil) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: env.identityURL + "/connect/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let email { req.setValue(Data(email.utf8).base64URL, forHTTPHeaderField: "Auth-Email") }
        var f = fields
        f["deviceType"] = String(Self.deviceType)
        f["deviceIdentifier"] = deviceId
        f["deviceName"] = "macos"
        req.httpBody = Self.form(f)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 400 || http.statusCode == 401 {
            let body = try? JSON.decoder.decode(ErrorBody.self, from: data)
            if let p = body?.twoFactorProviders2 {
                throw APIError.twoFactorRequired(providers: p.keys.compactMap(Int.init).sorted(), info: p)
            }
            let d = (body?.errorDescription ?? "") + (body?.errorModel?.message ?? "")
            if d.localizedCaseInsensitiveContains("new device") || d.localizedCaseInsensitiveContains("device verification") {
                throw APIError.newDeviceVerification
            }
            throw APIError.http(http.statusCode, body?.errorModel?.message ?? body?.errorDescription ?? "Login failed")
        }
        try check(data, resp)
        let t = try JSON.decoder.decode(TokenResponse.self, from: data)
        setTokens(Tokens(access: t.accessToken, refresh: t.refreshToken ?? tokens?.refresh,
                         expires: Date().addingTimeInterval(TimeInterval(t.expiresIn ?? 3600)),
                         clientId: fields["grant_type"] == "client_credentials" ? fields["client_id"] : tokens?.clientId,
                         clientSecret: fields["grant_type"] == "client_credentials" ? fields["client_secret"] : tokens?.clientSecret))
        return t
    }

    func setTokens(_ t: Tokens?) {
        tokens = t
        onTokensChanged?(t)
    }

    public func refresh() async throws {
        if let existing = lock.withLock({ refreshTask }) { return try await existing.value }
        let task = Task {
            guard let t = tokens else { throw APIError.unauthorized }
            if let r = t.refresh {
                _ = try await token(["grant_type": "refresh_token", "client_id": Self.clientName, "refresh_token": r])
            } else if let id = t.clientId, let secret = t.clientSecret {
                _ = try await token(["grant_type": "client_credentials", "client_id": id, "client_secret": secret, "scope": "api"])
            } else {
                throw APIError.unauthorized
            }
        }
        lock.withLock { refreshTask = task }
        defer { lock.withLock { refreshTask = nil } }
        try await task.value
    }

    public func raw(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json", auth: Bool = true) async throws -> Data {
        if auth, let t = tokens, t.expires < Date().addingTimeInterval(60) { try? await refresh() }
        func make() -> URLRequest {
            var req = URLRequest(url: URL(string: path.hasPrefix("http") ? path : env.apiURL + path)!)
            req.httpMethod = method
            if let body { req.httpBody = body; req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            if auth, let a = tokens?.access { req.setValue("Bearer \(a)", forHTTPHeaderField: "Authorization") }
            return req
        }
        var (data, resp) = try await session.data(for: make())
        if auth, (resp as? HTTPURLResponse)?.statusCode == 401 {
            try await refresh()
            (data, resp) = try await session.data(for: make())
        }
        try check(data, resp)
        return data
    }

    public func send<T: Decodable>(_ method: String, _ path: String, _ body: (some Encodable)? = nil as String?, as: T.Type = T.self) async throws -> T {
        let d = try await raw(method, path, body: try body.map { try JSON.encoder.encode($0) })
        return try JSON.decoder.decode(T.self, from: d)
    }

    public func call(_ method: String, _ path: String, _ body: (some Encodable)? = nil as String?) async throws {
        _ = try await raw(method, path, body: try body.map { try JSON.encoder.encode($0) })
    }

    public func multipart(_ path: String, fileName: String, data: Data) async throws {
        let boundary = "----swiftwarden" + UUID().uuidString
        var body = Data()
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"data\"; filename=\"\(fileName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body += data
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        _ = try await raw("POST", path, body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }

    public func upload(url: String, data: Data, azure: Bool, fileName: String, fallbackPath: String) async throws {
        if azure {
            var req = URLRequest(url: URL(string: url)!)
            req.httpMethod = "PUT"
            req.httpBody = data
            req.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
            req.setValue("2020-04-08", forHTTPHeaderField: "x-ms-version")
            let (d, r) = try await session.data(for: req)
            try check(d, r)
        } else {
            try await multipart(fallbackPath, fileName: fileName, data: data)
        }
    }

    public func download(_ url: String) async throws -> Data {
        let (d, r) = try await session.data(from: URL(string: url)!)
        try check(d, r)
        return d
    }
}
