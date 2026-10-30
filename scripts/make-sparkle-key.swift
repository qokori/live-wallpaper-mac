// Creates the Sparkle update signing key (Ed25519) without the keychain, in the format `sign_update --ed-key-file` reads: the
// private seed as one base64 line. Writes the private key to <key file> (mode 600, its folder 700) and prints only the PUBLIC key
// (what goes into SUPublicEDKey). Refuses to overwrite an existing key.
// Usage: make-sparkle-key <key file>
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-sparkle-key <key file>\n".utf8))
    exit(2)
}
let file = URL(filePath: CommandLine.arguments[1])
guard !FileManager.default.fileExists(atPath: file.path) else {
    FileHandle.standardError.write(Data("\(file.path) already exists; not overwritten\n".utf8))
    exit(1)
}
try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let key = Curve25519.Signing.PrivateKey()
guard FileManager.default.createFile(atPath: file.path, contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
    FileHandle.standardError.write(Data("cannot write \(file.path)\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
