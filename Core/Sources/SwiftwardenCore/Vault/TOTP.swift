import Foundation

public struct TOTP: Sendable {
    public let secret: Data
    public let digits: Int
    public let period: Int
    public let algorithm: String
    public let steam: Bool

    static func base32(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = Data()
        for ch in s.uppercased() where ch != "=" && ch != " " && ch != "-" {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | i
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out.isEmpty ? nil : out
    }

    public init?(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var secretStr = s, digits = 6, period = 30, alg = "SHA1", steam = false
        if s.lowercased().hasPrefix("otpauth://") {
            guard let c = URLComponents(string: s) else { return nil }
            for q in c.queryItems ?? [] {
                switch q.name.lowercased() {
                case "secret": secretStr = q.value ?? ""
                case "digits": digits = Int(q.value ?? "") ?? 6
                case "period": period = Int(q.value ?? "") ?? 30
                case "algorithm": alg = (q.value ?? "SHA1").uppercased()
                default: break
                }
            }
            if c.host?.lowercased() == "steam" || (c.queryItems ?? []).contains(where: { $0.name == "encoder" && $0.value == "steam" }) { steam = true }
        } else if s.lowercased().hasPrefix("steam://") {
            secretStr = String(s.dropFirst(8)); steam = true
        }
        guard let d = Self.base32(secretStr.replacingOccurrences(of: " ", with: "")) else { return nil }
        secret = d
        self.digits = steam ? 5 : max(1, min(digits, 10))
        self.period = max(1, period)
        algorithm = alg
        self.steam = steam
    }

    public func code(at date: Date = Date()) -> String {
        var counter = UInt64(date.timeIntervalSince1970 / Double(period)).bigEndian
        let msg = Data(bytes: &counter, count: 8)
        let h = [UInt8](Primitives.hmac(algorithm, msg, key: secret))
        let off = Int(h[h.count - 1] & 0x0f)
        var bin = (Int(h[off] & 0x7f) << 24) | (Int(h[off + 1]) << 16) | (Int(h[off + 2]) << 8) | Int(h[off + 3])
        if steam {
            let chars = Array("23456789BCDFGHJKMNPQRTVWXY")
            var out = ""
            for _ in 0 ..< 5 { out.append(chars[bin % chars.count]); bin /= chars.count }
            return out
        }
        var m = 1
        for _ in 0 ..< digits { m *= 10 }
        let c = String(bin % m)
        return String(repeating: "0", count: max(0, digits - c.count)) + c
    }

    public func remaining(at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }
}
