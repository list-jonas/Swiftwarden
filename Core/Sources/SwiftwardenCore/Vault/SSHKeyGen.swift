import CryptoKit
import Foundation

public enum SSHKeyGen {
    static func string(_ d: Data) -> Data {
        var n = UInt32(d.count).bigEndian
        return Data(bytes: &n, count: 4) + d
    }

    static func u32(_ v: UInt32) -> Data { var n = v.bigEndian; return Data(bytes: &n, count: 4) }

    public static func ed25519(comment: String = "") -> SSHKeyData {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation
        let type = Data("ssh-ed25519".utf8)
        let pubBlob = string(type) + string(pub)
        let check = UInt32.random(in: 0 ... UInt32.max)
        var priv = u32(check) + u32(check) + string(type) + string(pub) + string(key.rawRepresentation + pub) + string(Data(comment.utf8))
        var pad: UInt8 = 1
        while priv.count % 8 != 0 { priv.append(pad); pad += 1 }
        let body = Data("openssh-key-v1".utf8) + Data([0]) + string(Data("none".utf8)) + string(Data("none".utf8)) + string(Data())
            + u32(1) + string(pubBlob) + string(priv)
        let b64 = body.base64EncodedString()
        var lines: [String] = []
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[i ..< j])); i = j
        }
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + lines.joined(separator: "\n") + "\n-----END OPENSSH PRIVATE KEY-----\n"
        let fp = "SHA256:" + Data(SHA256.hash(data: pubBlob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return SSHKeyData(privateKey: pem, publicKey: "ssh-ed25519 " + pubBlob.base64EncodedString() + (comment.isEmpty ? "" : " " + comment), keyFingerprint: fp)
    }
}
