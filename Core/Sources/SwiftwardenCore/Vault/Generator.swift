import Foundation

public struct PasswordOptions: Codable, Hashable, Sendable {
    public var length = 14
    public var uppercase = true
    public var lowercase = true
    public var numbers = true
    public var special = false
    public var minNumbers = 1
    public var minSpecial = 0
    public var avoidAmbiguous = false
    public init() {}
}

public struct PassphraseOptions: Codable, Hashable, Sendable {
    public var words = 6
    public var separator = "-"
    public var capitalize = false
    public var includeNumber = false
    public init() {}
}

public enum Generator {
    public static func password(_ o: PasswordOptions) -> String {
        let upper = o.avoidAmbiguous ? "ABCDEFGHJKLMNPQRSTUVWXYZ" : "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let lower = o.avoidAmbiguous ? "abcdefghijkmnopqrstuvwxyz" : "abcdefghijklmnopqrstuvwxyz"
        let nums = o.avoidAmbiguous ? "23456789" : "0123456789"
        let special = "!@#$%^&*"
        var sets: [String] = []
        var required: [String] = []
        if o.uppercase { sets.append(upper); required.append(upper) }
        if o.lowercase { sets.append(lower); required.append(lower) }
        if o.numbers { sets.append(nums); required += Array(repeating: nums, count: max(1, o.minNumbers)) }
        if o.special { sets.append(special); required += Array(repeating: special, count: max(1, o.minSpecial)) }
        if sets.isEmpty { sets = [lower]; required = [lower] }
        let all = sets.joined()
        let len = max(o.length, required.count, 5)
        var pools = required
        while pools.count < len { pools.append(all) }
        pools.shuffle(using: &secureRNG)
        return String(pools.map { p in let a = Array(p); return a[Primitives.randomInt(a.count)] })
    }

    nonisolated(unsafe) static var secureRNG = SystemRandomNumberGenerator()

    public static func passphrase(_ o: PassphraseOptions) -> String {
        let list = Fingerprint.wordlist
        guard !list.isEmpty else { return "" }
        var words = (0 ..< max(3, o.words)).map { _ in list[Primitives.randomInt(list.count)] }
        if o.capitalize { words = words.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
        if o.includeNumber {
            let i = Primitives.randomInt(words.count)
            words[i] += String(Primitives.randomInt(10))
        }
        return words.joined(separator: o.separator)
    }

    public static func randomWord(capitalize: Bool = false, includeNumber: Bool = false) -> String {
        let list = Fingerprint.wordlist
        guard !list.isEmpty else { return "" }
        var w = list[Primitives.randomInt(list.count)]
        if capitalize { w = w.prefix(1).uppercased() + w.dropFirst() }
        if includeNumber { w += String(format: "%04d", Primitives.randomInt(10000)) }
        return w
    }

    static func randomString(_ n: Int) -> String {
        let a = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0 ..< n).map { _ in a[Primitives.randomInt(a.count)] })
    }

    public static func plusAddressed(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        return email[..<at] + "+" + randomString(8) + email[at...]
    }

    public static func catchAll(_ domain: String) -> String {
        randomString(8) + "@" + domain.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
    }
}

public enum PasswordStrength {
    static let common: Set<String> = [
        "password", "123456", "12345678", "qwerty", "abc123", "monkey", "letmein", "dragon", "111111", "baseball", "iloveyou",
        "trustno1", "1234567", "sunshine", "master", "123123", "welcome", "shadow", "ashley", "football", "jesus", "michael",
        "ninja", "mustang", "password1", "admin", "root", "login", "passw0rd", "starwars", "hello", "freedom", "whatever",
        "qazwsx", "secret", "summer", "winter", "spring", "autumn", "princess", "solo", "access", "flower", "hottie", "loveme",
        "zaq1zaq1", "1q2w3e4r", "qwertyuiop", "asdfgh", "zxcvbn", "000000", "654321", "superman", "batman", "pokemon", "google",
        "computer", "internet", "test", "guest", "changeme", "default", "pass", "user", "love", "money", "lovely", "family",
    ]

    static let wordSet = Set(Fingerprint.wordlist)

    static let sequences = ["abcdefghijklmnopqrstuvwxyz", "01234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"]

    public static func score(_ pw: String, userInputs: [String] = []) -> Int {
        guard !pw.isEmpty else { return 0 }
        let lower = pw.lowercased()
        let leet = String(lower.map { ["0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i"][$0] ?? $0 })
        let core = leet.trimmingCharacters(in: CharacterSet.letters.inverted)
        if common.contains(lower) || common.contains(core) || common.contains(leet) { return 0 }
        var pool = 0
        if pw.rangeOfCharacter(from: .lowercaseLetters) != nil { pool += 26 }
        if pw.rangeOfCharacter(from: .uppercaseLetters) != nil { pool += 26 }
        if pw.rangeOfCharacter(from: .decimalDigits) != nil { pool += 10 }
        if pw.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { pool += 33 }
        let chars = Array(lower)
        var effective = 0.0
        var i = 0
        while i < chars.count {
            var run = 1
            while i + run < chars.count, chars[i + run] == chars[i] { run += 1 }
            var seq = 1
            for s in sequences {
                guard let idx = s.firstIndex(of: chars[i]) else { continue }
                var k = 1
                var pos = s.index(after: idx)
                while i + k < chars.count, pos < s.endIndex, s[pos] == chars[i + k] { k += 1; pos = s.index(after: pos) }
                seq = max(seq, k)
            }
            let step = max(run, seq)
            effective += step >= 3 ? 1.5 : Double(step)
            i += step
        }
        var bits = effective * log2(Double(max(pool, 10)))
        if core.count >= 3, wordSet.contains(core) || common.contains(where: { core.hasPrefix($0) && $0.count >= 4 }) {
            bits = min(bits, 12 + Double(pw.count - core.count) * 3.3)
        }
        for u in userInputs where u.count >= 3 && lower.contains(u.lowercased()) { bits -= Double(u.count) * 3 }
        switch bits {
        case ..<28: return 0
        case ..<40: return 1
        case ..<60: return 2
        case ..<80: return 3
        default: return 4
        }
    }

    public static func isWeak(_ pw: String, userInputs: [String] = []) -> Bool { score(pw, userInputs: userInputs) <= 2 }
}

