import Foundation
import Security
import Synchronization
import Testing

@testable import BackupSquirrel

@MainActor
final class ResticIntegrationTests {
    private static let password = "integration-pw-\(UUID().uuidString)"
    private static let hostName = "test-mac"

    private let folder: URL
    private let source: URL
    private let restic: Restic
    private let target = Fixture.target()
    private let passwords = InMemoryPasswordStore()

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "BackupSquirrelTests-\(UUID().uuidString)")
        source = folder.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let binary = try #require(Bundle.main.url(forAuxiliaryExecutable: "restic"), "restic is not bundled")
        let paths = AppPaths(
            home: folder, applicationSupport: folder.appending(path: "support"),
            caches: folder.appending(path: "caches"),
            temporary: folder)
        restic = Restic(binary: binary, paths: paths, access: .local(folder.appending(path: "repo")), progressFPS: 60)
        passwords.setPassword(Self.password, for: target.id)
    }

    deinit {
        let files = FileManager.default
        if let contents = files.enumerator(atPath: folder.path) {
            for case let path as String in contents {
                try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.appending(path: path).path)
            }
        }
        try? files.removeItem(at: folder)
    }

    private var connection: ResticConnection { ResticConnection(restic: restic) }

    private func executor() -> ResticRunExecutor {
        ResticRunExecutor(
            restic: restic, passwords: passwords, hostName: Self.hostName,
            uptimeKuma: UptimeKuma { _ in (Data(), 200) })
    }

    private func createRepository() async throws {
        #expect(await connection.createRepository(for: target, password: Self.password) == .succeeded)
    }

    private func write(_ name: String, bytes: Int = 16) throws {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        try data.write(to: source.appending(path: name))
    }

    private func plan(_ id: UUID = UUID()) -> Plan {
        Fixture.plan(id: id, sourceFolders: [source])
    }

    private func events(of job: RunJob) async -> [RunEvent] {
        var events: [RunEvent] = []
        for await event in executor().execute(job).events { events.append(event) }
        return events
    }

    private func outcome(of job: RunJob) async throws -> RunOutcome {
        guard case .finished(let outcome) = await events(of: job).last else {
            throw CancellationError()
        }
        return outcome
    }

    private func runRestic(_ command: [String]) async throws -> (status: Int32, output: [String]) {
        let lines = Mutex<[String]>([])
        let status = try await PosixProcessRunner().run(
            try restic.invocation(command, for: target, password: Self.password)
        ) { line in
            if case .standardOutput(let text) = line { lines.withLock { $0.append(text) } }
        }
        return (status, lines.withLock { $0 })
    }

    private func snapshotCount(of plan: Plan) async throws -> Int {
        let result = try await runRestic(["snapshots", "--json", "--tag", ResticJobRunner.tag(for: plan)])
        struct Snapshot: Decodable {}
        return try JSONDecoder().decode([Snapshot].self, from: Data(result.output.joined().utf8)).count
    }

    @Test func aBackupReportsProgressAndItsSummary() async throws {
        try await createRepository()
        try write("big.bin", bytes: 20_000_000)
        try write("small.txt")
        let events = await events(of: .backup(plan(), target))
        let progress = events.compactMap { event -> OperationProgress? in
            if case .progress(let progress) = event { progress } else { nil }
        }
        #expect(!progress.isEmpty)
        #expect(progress.last?.bytesTotal == 20_000_016)
        guard case .finished(let outcome) = events.last, case .backup(let statistics) = outcome.details else {
            Issue.record("no outcome")
            return
        }
        #expect(outcome.status == .success)
        #expect(statistics.filesNew == 2)
        #expect(statistics.bytesProcessed == 20_000_016)
        #expect(statistics.snapshotID?.count == 8)
        #expect(outcome.output.contains("$ restic backup"))
        #expect(!outcome.output.contains(Self.password))
    }

    @Test func anUnreadableFileLeavesASnapshotAndAWarning() async throws {
        try await createRepository()
        try write("readable.txt")
        try write("locked.txt")
        let locked = source.appending(path: "locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        let outcome = try await outcome(of: .backup(plan(), target))
        guard case .backup(let statistics) = outcome.details else { throw CancellationError() }
        #expect(outcome.status == .warning)
        #expect(statistics.unreadableFiles == [locked.path])
        #expect(statistics.snapshotID != nil)
    }

    @Test func retentionThinsOnlyTheBackedUpPlansSnapshots() async throws {
        try await createRepository()
        try write("file.txt")
        let thinned = plan()
        let untouched = plan()
        for plan in [thinned, untouched] {
            for time in ["2020-01-01 00:00:00", "2020-01-03 09:00:00", "2020-01-03 10:00:00"] {
                let created = try await runRestic([
                    "backup", "--host", Self.hostName, "--tag", ResticJobRunner.tag(for: plan), "--time", time,
                    source.path,
                ])
                #expect(created.status == 0)
            }
        }
        let outcome = try await outcome(of: .backup(thinned, target))
        guard case .backup(let statistics) = outcome.details else { throw CancellationError() }
        #expect(outcome.status == .success)
        #expect(statistics.snapshotsForgotten == 1)
        #expect(try await snapshotCount(of: thinned) == 3)
        #expect(try await snapshotCount(of: untouched) == 3)
    }

    @Test func aCheckReadsItsSubsetOfTheData() async throws {
        try await createRepository()
        try write("file.bin", bytes: 100_000)
        _ = try await outcome(of: .backup(plan(), target))
        let outcome = try await outcome(of: .check(target, subset: 5, subsetCount: 128))
        #expect(outcome.status == .success)
        #expect(outcome.details == .check(CheckStatistics(subset: 5)))
        #expect(outcome.output.contains("--read-data-subset=5/128"))
    }

    @Test func aPruneFreesWhatForgottenSnapshotsHeld() async throws {
        try await createRepository()
        try write("file.bin", bytes: 300_000)
        let backup = try await outcome(of: .backup(plan(), target))
        guard case .backup(let statistics) = backup.details, let snapshot = statistics.snapshotID else {
            throw CancellationError()
        }
        #expect(try await runRestic(["forget", snapshot]).status == 0)
        let outcome = try await outcome(of: .prune(target))
        guard case .prune(let pruned) = outcome.details else { throw CancellationError() }
        #expect(outcome.status == .success)
        #expect(pruned.bytesFreed > 290_000)
    }

    @Test func aWrongPasswordIsRecognised() async throws {
        try await createRepository()
        #expect(await connection.verifyPassword(Self.password, for: target) == .matches)
        #expect(await connection.verifyPassword("wrong", for: target) == .wrong)
        passwords.setPassword("wrong", for: target.id)
        let outcome = try await outcome(of: .backup(plan(), target))
        #expect(outcome.status == .failed)
        #expect(outcome.failure == .other("Repository-Passwort passt nicht"))
    }

    @Test func thePasswordCanBeChanged() async throws {
        try await createRepository()
        #expect(await connection.changePassword(of: target, from: Self.password, to: "new-pw") == .succeeded)
        #expect(await connection.verifyPassword("new-pw", for: target) == .matches)
        #expect(await connection.verifyPassword(Self.password, for: target) == .wrong)
    }

    @Test func aMissingRepositoryIsNamed() async throws {
        let outcome = try await outcome(of: .backup(plan(), target))
        #expect(outcome.status == .failed)
        #expect(outcome.failure == .other("Repository nicht gefunden"))
    }

    @Test func thePasswordNeverReachesResticsEnvironment() async throws {
        setenv("RESTIC_PASSWORD", "from-the-owners-shell", 1)
        defer { unsetenv("RESTIC_PASSWORD") }
        var invocation = try restic.invocation(["backup"], for: target, password: Self.password)
        invocation.executable = URL(fileURLWithPath: "/usr/bin/env")
        invocation.arguments = []
        let lines = Mutex<[String]>([])
        let status = try await PosixProcessRunner().run(invocation) { line in
            if case .standardOutput(let text) = line { lines.withLock { $0.append(text) } }
        }
        #expect(status == 0)
        let environment = lines.withLock { $0 }
        #expect(
            environment.map { String($0.prefix { $0 != "=" }) }.sorted() == [
                "HOME", "PATH", "RESTIC_PROGRESS_FPS", "TMPDIR",
            ])
        #expect(!environment.contains { $0.contains(Self.password) || $0.contains("from-the-owners-shell") })
    }

    @Test func aGeneratedKeyIsPrivateToTheOwner() async throws {
        let keys = SSHKeyStore(paths: restic.paths)
        let key = try await keys.generateKey(for: target.id)
        #expect(key.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(key.publicKey.hasSuffix(" backup-squirrel"))
        #expect(key.publicKeyPath == "support/Keys/\(target.id.uuidString.lowercased()).pub")
        let files = FileManager.default
        let privateKey = restic.paths.privateKey(for: target.id).path
        #expect(try files.attributesOfItem(atPath: privateKey)[.posixPermissions] as? Int == 0o600)
        #expect(try files.attributesOfItem(atPath: restic.paths.keys.path)[.posixPermissions] as? Int == 0o700)
        let again = try await keys.generateKey(for: target.id)
        #expect(again.publicKey != key.publicKey)
        try Data().write(to: restic.paths.knownHosts(for: target.id))
        try keys.removeKey(for: target.id)
        #expect(try files.contentsOfDirectory(atPath: restic.paths.keys.path).isEmpty)
    }

    @Test func theKeychainKeepsTheRepositoryPassword() throws {
        let store = KeychainPasswordStore(service: "de.rocu.BackupSquirrel.tests.\(UUID().uuidString)")
        let id = UUID()
        defer { try? store.removePassword(for: id) }
        #expect(store.password(for: id) == nil)
        #expect(!store.hasPassword(for: id))
        try store.setPassword("first", for: id)
        #expect(store.hasPassword(for: id))
        #expect(store.password(for: id) == "first")
        try store.setPassword("second", for: id)
        #expect(store.password(for: id) == "second")
        try store.removePassword(for: id)
        #expect(store.password(for: id) == nil)
        #expect(!store.hasPassword(for: id))
        try store.removePassword(for: id)
    }
}
