import Foundation

struct SimulatedSSHKeys: SSHKeyGenerating {
    func generateKey(for targetID: Target.ID) async throws -> SSHKey {
        .simulated(for: targetID)
    }

    func removeKey(for targetID: Target.ID) throws {}
}

extension SSHKey {
    static func defaultPath(for targetID: Target.ID) -> String {
        "Library/Application Support/Backup-Squirrel/Keys/\(targetID.uuidString.lowercased()).pub"
    }

    static func simulated(for targetID: Target.ID) -> SSHKey {
        let bytes = withUnsafeBytes(of: targetID.uuid) { Data($0) }
        let material = (bytes + bytes.reversed()).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return SSHKey(
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI\(material) backup-squirrel",
            publicKeyPath: defaultPath(for: targetID)
        )
    }
}
