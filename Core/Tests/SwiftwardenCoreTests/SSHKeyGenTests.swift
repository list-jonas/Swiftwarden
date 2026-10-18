import Foundation
@testable import SwiftwardenCore
import XCTest

final class SSHKeyGenTests: XCTestCase {
    func testGeneratedKeyIsAcceptedByOpenSSH() throws {
        let tool = "/usr/bin/ssh-keygen"
        guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("ssh-keygen missing") }
        let key = SSHKeyGen.ed25519(comment: "deploy@swiftwarden")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sw-\(UUID().uuidString)")
        try XCTUnwrap(key.privateKey).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: file) }

        func run(_ args: String...) throws -> String {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, args.joined(separator: " "))
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try run("-y", "-f", file.path), key.publicKey)
        let fp = try run("-l", "-E", "sha256", "-f", file.path)
        XCTAssertTrue(fp.contains(try XCTUnwrap(key.keyFingerprint)), fp)
        XCTAssertTrue(fp.hasSuffix("deploy@swiftwarden (ED25519)"), fp)
        XCTAssertTrue(key.privateKey!.split(separator: "\n").allSatisfy { $0.count <= 70 })
        XCTAssertNotEqual(SSHKeyGen.ed25519().publicKey, SSHKeyGen.ed25519().publicKey)
        XCTAssertEqual(SSHKeyGen.ed25519().publicKey?.split(separator: " ").count, 2)
    }
}
