import Foundation

struct Target: Identifiable, Hashable, Sendable, Codable {
    static let defaultPort = 23

    let id: UUID
    var name: String
    var host: String
    var user: String
    var port: Int
    var path: String
    /// Passed to `restic --limit-upload`, which counts in KiB/s.
    var uploadLimitKiBPerSecond: Int?
    var sshKey: SSHKey
    var createdAt: Date
    /// The last successful connection test; runs that reached the target count as well.
    var connectedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        host: String = "",
        user: String = "",
        port: Int = Target.defaultPort,
        path: String = "",
        uploadLimitKiBPerSecond: Int? = nil,
        sshKey: SSHKey,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.path = path
        self.uploadLimitKiBPerSecond = uploadLimitKiBPerSecond
        self.sshKey = sshKey
        self.createdAt = createdAt
    }

    /// As restic expects it after `--repo`; an absolute path yields the double slash restic wants.
    var repository: String {
        let user = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user
        let path = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "sftp://\(user)@\(host):\(port)/\(path)"
    }

    /// A control character in a field would split the sftp batch commands the setup sends.
    var hasValidConnection: Bool {
        let fields = [host, user, path].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return !fields[0].isEmpty && !fields[1].isEmpty && (1...65_535).contains(port)
            && !fields.contains { $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    }

    func trimmingConnection() -> Target {
        var target = self
        target.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        target.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        target.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return target
    }
}

struct SSHKey: Hashable, Sendable, Codable {
    var publicKey: String
    /// Relative to the home directory.
    var publicKeyPath: String
    var isInstalled = false

    func installCommand(for target: Target) -> String {
        let path = "~/" + publicKeyPath.replacingOccurrences(of: " ", with: "\\ ")
        return "cat \(path) | ssh -p\(target.port) \(target.user)@\(target.host) install-ssh-key"
    }
}

enum UploadLimit {
    /// Decimal megabytes like everywhere else in the app; restic wants KiB/s.
    static let megabytesPerSecond: [Double] = [1, 2.5, 5, 10]

    static func kibPerSecond(megabytesPerSecond: Double) -> Int {
        Int((megabytesPerSecond * 1_000_000 / 1024).rounded())
    }

    static var options: [Int] { megabytesPerSecond.map(kibPerSecond(megabytesPerSecond:)) }

    static func option(for kibPerSecond: Int?) -> Int? {
        guard let kibPerSecond else { return nil }
        return options.min { abs($0 - kibPerSecond) < abs($1 - kibPerSecond) }
    }
}
