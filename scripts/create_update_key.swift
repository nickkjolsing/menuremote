import CryptoKit
import Foundation

// Sparkle accepts the base64 encoding of an Ed25519 seed. Use a protected file
// so setup and CI never need access to unrelated Keychain credentials.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: create_update_key.swift PRIVATE_KEY_FILE PUBLIC_KEY_FILE")
}
let privateURL = URL(fileURLWithPath: CommandLine.arguments[1])
let publicURL = URL(fileURLWithPath: CommandLine.arguments[2])
let fm = FileManager.default
let key: Curve25519.Signing.PrivateKey
if fm.fileExists(atPath: privateURL.path) {
    let encoded = try String(contentsOf: privateURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: encoded) else { fatalError("Invalid private key file") }
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
} else {
    // Never silently replace the signing identity of an app already distributed.
    guard !fm.fileExists(atPath: publicURL.path) else {
        fatalError("A public key already exists. Restore its private key instead of generating a replacement.")
    }
    key = Curve25519.Signing.PrivateKey()
    try fm.createDirectory(at: privateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o700])
    guard fm.createFile(atPath: privateURL.path,
                        contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
                        attributes: [.posixPermissions: 0o600]) else {
        fatalError("Could not write the private signing key")
    }
}
let publicKey = key.publicKey.rawRepresentation.base64EncodedString() + "\n"
if fm.fileExists(atPath: publicURL.path) {
    guard try String(contentsOf: publicURL, encoding: .utf8) == publicKey else {
        fatalError("Private key does not match the existing public key")
    }
} else {
    try publicKey.write(to: publicURL, atomically: true, encoding: .utf8)
}
print("Public signing key: \(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))")
print("Private signing key saved at: \(privateURL.path)")
print("Add that file's contents as the GitHub Actions secret SPARKLE_PRIVATE_KEY. Keep a secure backup.")
