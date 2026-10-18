import Foundation

final class StubURLProtocol: URLProtocol {
    struct Recorded {
        let request: URLRequest
        let body: Data
        var line: String { "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")" }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((Recorded) -> (Int, Data))?
    nonisolated(unsafe) private static var _log: [Recorded] = []

    static var handler: ((Recorded) -> (Int, Data))? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue; _log = [] } }
    }

    static var log: [Recorded] { lock.withLock { _log } }
    static func clearLog() { lock.withLock { _log = [] } }

    static func configuration() -> URLSessionConfiguration {
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
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            s.close()
        }
        let rec = Recorded(request: request, body: body)
        let (status, data) = Self.lock.withLock { () -> (Int, Data) in
            Self._log.append(rec)
            return Self._handler?(rec) ?? (599, Data())
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o, options: [.fragmentsAllowed]) }
