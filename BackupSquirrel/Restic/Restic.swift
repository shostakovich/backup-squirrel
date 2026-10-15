import Foundation

enum RepositoryAccess: Hashable, Sendable {
    case sftp
    /// A repository folder on this Mac, for tests.
    case local(URL)
}

enum HostKeyPolicy: String, Hashable, Sendable {
    case enforce = "yes"
    /// Only the connection test may trust a server it has never seen.
    case acceptNew = "accept-new"
}

struct UnquotableArgument: Error, Hashable, Sendable {
    var argument: String
}

struct Restic: Hashable, Sendable {
    var binary: URL
    var paths: AppPaths
    var access = RepositoryAccess.sftp

    static func bundled(paths: AppPaths = .standard) -> Restic? {
        Bundle.main.url(forAuxiliaryExecutable: "restic").map { Restic(binary: $0, paths: paths) }
    }

    /// The password travels on stdin and a new one on fd 3, never through the environment or a file.
    func invocation(
        _ command: [String], for target: Target, password: String, newPassword: String? = nil
    ) throws -> ProcessInvocation {
        ProcessInvocation(
            executable: binary,
            arguments: command + (try globalArguments(for: target)),
            environment: ChildEnvironment.minimal(paths: paths),
            standardInput: Data((password + "\n").utf8),
            extraInput: newPassword.map { Data(($0 + "\n").utf8) }
        )
    }

    func globalArguments(for target: Target) throws -> [String] {
        var arguments: [String]
        switch access {
        case .sftp:
            let command = try CommandQuoting.resticShell(SSHCommand.resticSFTP(for: target, paths: paths))
            arguments = ["--repo", target.repository, "-o", CommandQuoting.csvField("sftp.command=\(command)")]
        case .local(let url):
            arguments = ["--repo", url.path]
        }
        arguments += ["--cache-dir", paths.resticCache.path]
        if let limit = target.uploadLimitKiBPerSecond {
            arguments += ["--limit-upload", String(limit)]
        }
        return arguments
    }
}

enum ChildEnvironment {
    /// Nothing from the app's own environment, so no `RESTIC_*` variable of the owner's shell gets through.
    static func minimal(paths: AppPaths) -> [String: String] {
        [
            "HOME": paths.home.path,
            "TMPDIR": paths.temporary.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
    }
}

enum SSHCommand {
    static let ssh = URL(fileURLWithPath: "/usr/bin/ssh")
    static let sftp = URL(fileURLWithPath: "/usr/bin/sftp")

    /// Only the target's own key and known_hosts; the owner's SSH config and agent are ignored.
    static func options(for target: Target, paths: AppPaths, hostKeys: HostKeyPolicy) -> [String] {
        [
            "-F", "/dev/null",
            "-i", paths.privateKey(for: target.id).path,
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            // ssh splits this option at whitespace unless the path is quoted.
            "-o", "UserKnownHostsFile=\"\(paths.knownHosts(for: target.id).path)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=\(hostKeys.rawValue)",
            "-o", "ConnectTimeout=30",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4",
        ]
    }

    static func resticSFTP(for target: Target, paths: AppPaths) -> [String] {
        [ssh.path] + options(for: target, paths: paths, hostKeys: .enforce)
            + ["-p", String(target.port), "-s", "--", "\(target.user)@\(target.host)", "sftp"]
    }

    static func sftpBatch(for target: Target, paths: AppPaths, hostKeys: HostKeyPolicy) -> [String] {
        ["-b", "-"] + options(for: target, paths: paths, hostKeys: hostKeys)
            + ["-P", String(target.port), "--", "\(target.user)@\(target.host)"]
    }
}

enum CommandQuoting {
    /// restic splits `sftp.command` itself: either quote character groups a field, a backslash escapes a quote.
    static func resticShell(_ arguments: [String]) throws -> String {
        try arguments.map { argument in
            guard !argument.isEmpty, !argument.contains("\\") else { throw UnquotableArgument(argument: argument) }
            if !argument.contains("'") { return "'\(argument)'" }
            if !argument.contains("\"") { return "\"\(argument)\"" }
            throw UnquotableArgument(argument: argument)
        }.joined(separator: " ")
    }

    /// restic reads each `-o` value as CSV, so commas and quotes need a quoted field.
    static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// For sftp's batch parser; glob characters are literal inside double quotes, a newline would end the command.
    static func sftpPath(_ path: String) throws -> String {
        guard !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw UnquotableArgument(argument: path)
        }
        var escaped = ""
        for character in path {
            if "\\\"".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }

    /// Exclusions are globs; an excluded folder is meant literally.
    static func resticGlob(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if "\\*?[]".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}
