import Foundation
import Synchronization

enum PasswordVerification: Hashable, Sendable {
    case matches
    case wrong
    case failed(String)
}

enum RepositoryChange: Hashable, Sendable {
    case succeeded
    case failed(String)
}

protocol TargetConnection: Sendable {
    func test(_ target: Target) async -> ConnectionTest
    /// Looks for the repository's files, so it needs no password; a failed lookup counts as not found.
    func detectRepository(at target: Target) async -> RepositoryDetection
    func verifyPassword(_ password: String, for target: Target) async -> PasswordVerification
    func createRepository(for target: Target, password: String) async -> RepositoryChange
    func changePassword(of target: Target, from oldPassword: String, to newPassword: String) async -> RepositoryChange
}

struct ResticConnection: TargetConnection {
    var restic: Restic
    var runner: any ProcessRunner = PosixProcessRunner()

    func test(_ target: Target) async -> ConnectionTest {
        guard let result = await sftp(["pwd"], on: target, hostKeys: .acceptNew) else {
            return .failed("sftp konnte nicht gestartet werden")
        }
        return result.exitCode == 0 ? .succeeded : .failed(Self.connectionProblem(in: result.errors))
    }

    func detectRepository(at target: Target) async -> RepositoryDetection {
        let config = Self.remotePath("config", in: target)
        let snapshots = Self.remotePath("snapshots", in: target)
        guard let commands = try? [config, snapshots].map({ "-ls -1 \(try CommandQuoting.sftpPath($0))" }),
            let result = await sftp(commands, on: target, hostKeys: .enforce), result.exitCode == 0
        else {
            return .notFound
        }
        let listings = SFTPBatchOutput.listings(in: result.output)
        guard listings.count == 2, !listings[0].isEmpty else { return .notFound }
        return .found(snapshots: listings[1].count)
    }

    func verifyPassword(_ password: String, for target: Target) async -> PasswordVerification {
        guard let result = await restic(["cat", "config"], on: target, password: password) else {
            return .failed("restic konnte nicht gestartet werden")
        }
        switch result.exitCode {
        case 0: return .matches
        case 12: return .wrong
        default: return .failed(result.problem(for: target))
        }
    }

    func createRepository(for target: Target, password: String) async -> RepositoryChange {
        guard let result = await restic(["init", "--json"], on: target, password: password) else {
            return .failed("restic konnte nicht gestartet werden")
        }
        return result.exitCode == 0 ? .succeeded : .failed(result.problem(for: target))
    }

    func changePassword(of target: Target, from oldPassword: String, to newPassword: String) async -> RepositoryChange {
        guard
            let result = await restic(
                ["key", "passwd", "--new-password-file", "/dev/fd/3"], on: target, password: oldPassword,
                newPassword: newPassword)
        else { return .failed("restic konnte nicht gestartet werden") }
        switch result.exitCode {
        case 0: return .succeeded
        case 12: return .failed("Bisheriges Passwort passt nicht")
        default: return .failed(result.problem(for: target))
        }
    }

    static func remotePath(_ name: String, in target: Target) -> String {
        var path = target.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { return name }
        return path.hasSuffix("/") ? path + name : "\(path)/\(name)"
    }

    static func connectionProblem(in errors: [String]) -> String {
        let text = errors.joined(separator: "\n")
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return "Hostschlüssel des Servers hat sich geändert"
        }
        if text.contains("Permission denied") { return "SSH-Schlüssel ist noch nicht installiert" }
        if text.contains("Could not resolve hostname") || text.contains("nodename nor servname") {
            return "Server nicht gefunden"
        }
        if ResticFailure.unreachableMarkers.contains(where: text.contains) { return "Server nicht erreichbar" }
        return "Verbindung fehlgeschlagen"
    }

    private func sftp(_ commands: [String], on target: Target, hostKeys: HostKeyPolicy) async -> CommandResult? {
        let invocation = ProcessInvocation(
            executable: SSHCommand.sftp,
            arguments: SSHCommand.sftpBatch(for: target, paths: restic.paths, hostKeys: hostKeys),
            environment: ChildEnvironment.minimal(paths: restic.paths),
            standardInput: Data(commands.map { $0 + "\n" }.joined().utf8)
        )
        return await CommandResult.run(invocation, with: runner)
    }

    private func restic(
        _ command: [String], on target: Target, password: String, newPassword: String? = nil
    ) async -> CommandResult? {
        guard
            let invocation = try? restic.invocation(
                command, for: target, password: password, newPassword: newPassword)
        else { return nil }
        return await CommandResult.run(invocation, with: runner)
    }
}

private struct CommandResult {
    var exitCode: Int32 = 0
    var output: [String] = []
    var errors: [String] = []

    static func run(_ invocation: ProcessInvocation, with runner: any ProcessRunner) async -> CommandResult? {
        let collected = Mutex(CommandResult())
        guard
            let exitCode = try? await runner.run(
                invocation,
                onOutput: { line in
                    collected.withLock {
                        switch line {
                        case .standardOutput(let text): $0.output.append(text)
                        case .standardError(let text): $0.errors.append(text)
                        }
                    }
                })
        else { return nil }
        return collected.withLock {
            $0.exitCode = exitCode
            return $0
        }
    }

    func problem(for target: Target) -> String {
        RunText.reason(ResticFailure.classify(exitCode: exitCode, errorLines: errors), targetName: target.name)
    }
}

enum SFTPBatchOutput {
    /// The lines each batch command printed, in order; sftp echoes every command as `sftp> command`.
    static func listings(in lines: [String]) -> [[String]] {
        var listings: [[String]] = []
        for line in lines {
            if line.hasPrefix("sftp> ") {
                listings.append([])
            } else if !line.isEmpty, !listings.isEmpty {
                listings[listings.count - 1].append(line)
            }
        }
        return listings
    }
}
