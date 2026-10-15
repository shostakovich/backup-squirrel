import Foundation

struct AppPaths: Hashable, Sendable {
    var home: URL
    var applicationSupport: URL
    var caches: URL
    var temporary: URL

    static var standard: AppPaths {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        return AppPaths(
            home: home,
            applicationSupport: library.appending(
                path: "Application Support/Backup-Squirrel", directoryHint: .isDirectory),
            caches: library.appending(path: "Caches/de.rocu.BackupSquirrel", directoryHint: .isDirectory),
            temporary: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        )
    }

    var keys: URL { applicationSupport.appending(path: "Keys", directoryHint: .isDirectory) }

    /// Not shared with a restic the owner runs by hand.
    var resticCache: URL { caches.appending(path: "restic", directoryHint: .isDirectory) }

    func privateKey(for targetID: Target.ID) -> URL {
        keys.appending(path: targetID.uuidString.lowercased(), directoryHint: .notDirectory)
    }

    func publicKey(for targetID: Target.ID) -> URL {
        keys.appending(path: "\(targetID.uuidString.lowercased()).pub", directoryHint: .notDirectory)
    }

    func knownHosts(for targetID: Target.ID) -> URL {
        keys.appending(path: "\(targetID.uuidString.lowercased()).known_hosts", directoryHint: .notDirectory)
    }

    /// Relative to the home directory where possible, as `SSHKey.publicKeyPath` stores it.
    func pathFromHome(_ url: URL) -> String {
        let homePath = home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return path }
        return String(path.dropFirst(homePath.count + 1))
    }
}
