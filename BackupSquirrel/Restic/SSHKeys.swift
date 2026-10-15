import Foundation
import Synchronization

struct SSHKeyError: Error, Hashable, Sendable {
    var message: String
}

protocol SSHKeyGenerating: Sendable {
    func generateKey(for targetID: Target.ID) async throws -> SSHKey
    func removeKey(for targetID: Target.ID) throws
}

/// One ed25519 key without passphrase per target, readable only by the owner.
struct SSHKeyStore: SSHKeyGenerating {
    static let keygen = URL(fileURLWithPath: "/usr/bin/ssh-keygen")

    var paths: AppPaths
    var runner: any ProcessRunner = PosixProcessRunner()

    func generateKey(for targetID: Target.ID) async throws -> SSHKey {
        let files = FileManager.default
        try files.createDirectory(at: paths.keys, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.keys.path)
        try removeKey(for: targetID)
        let privateKey = paths.privateKey(for: targetID)
        let errors = Mutex<[String]>([])
        let exitCode = try await runner.run(
            ProcessInvocation(
                executable: Self.keygen,
                arguments: ["-q", "-t", "ed25519", "-N", "", "-C", "backup-squirrel", "-f", privateKey.path],
                environment: ChildEnvironment.minimal(paths: paths)
            )
        ) { line in
            if case .standardError(let text) = line { errors.withLock { $0.append(text) } }
        }
        guard exitCode == 0 else {
            throw SSHKeyError(message: errors.withLock { $0.joined(separator: "\n") })
        }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKey.path)
        let publicKeyURL = paths.publicKey(for: targetID)
        let publicKey = try String(contentsOf: publicKeyURL, encoding: .utf8)
        return SSHKey(
            publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines),
            publicKeyPath: paths.pathFromHome(publicKeyURL))
    }

    func removeKey(for targetID: Target.ID) throws {
        for url in [paths.privateKey(for: targetID), paths.publicKey(for: targetID), paths.knownHosts(for: targetID)] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }
    }
}
