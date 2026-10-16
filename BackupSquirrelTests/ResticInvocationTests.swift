import Foundation
import Testing

@testable import BackupSquirrel

/// restic's `SplitShellStrings` (internal/backend/shell_split.go in 0.19.1), ported to check our quoting.
private func resticSplit(_ command: String) -> [String]? {
    var fields: [String] = []
    var field: String?
    var quote: Character?
    var lastCharacter: Character?
    for character in command {
        var splits = false
        if lastCharacter != "\\", let open = quote, character == open {
            quote = nil
            splits = true
        } else if lastCharacter != "\\", quote == nil, character == "\"" || character == "'" {
            quote = character
            splits = true
        } else {
            lastCharacter = character
            splits = quote == nil && (character == "\\" || character.isWhitespace)
        }
        if splits {
            if let done = field { fields.append(done) }
            field = nil
        } else {
            field = (field ?? "") + String(character)
        }
    }
    if let done = field { fields.append(done) }
    return quote == nil && !fields.isEmpty ? fields : nil
}

/// Reads one CSV field the way restic's `-o` flag does.
private func csvValue(_ field: String) -> String? {
    guard field.count >= 2, field.hasPrefix("\""), field.hasSuffix("\"") else { return nil }
    return String(field.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
}

struct ResticInvocationTests {
    private let paths = AppPaths(
        home: URL(fileURLWithPath: "/Users/example", isDirectory: true),
        applicationSupport: URL(fileURLWithPath: "/Users/example/Library/Application Support/Backup-Squirrel"),
        caches: URL(fileURLWithPath: "/Users/example/Library/Caches/de.rocu.BackupSquirrel"),
        temporary: URL(fileURLWithPath: "/var/folders/xy/T", isDirectory: true)
    )

    private var restic: Restic {
        Restic(binary: URL(fileURLWithPath: "/Applications/Backup-Squirrel.app/Contents/MacOS/restic"), paths: paths)
    }

    private var keyFolder: String { "/Users/example/Library/Application Support/Backup-Squirrel/Keys" }

    @Test func sshUsesOnlyTheTargetsKeyAndKnownHosts() {
        let options = SSHCommand.options(for: Fixture.target(), paths: paths, hostKeys: .enforce)
        let id = Fixture.targetID.uuidString.lowercased()
        #expect(
            options == [
                "-F", "/dev/null",
                "-i", "\(keyFolder)/\(id)",
                "-o", "IdentitiesOnly=yes",
                "-o", "IdentityAgent=none",
                "-o", "UserKnownHostsFile=\"\(keyFolder)/\(id).known_hosts\"",
                "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "ConnectTimeout=30",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=4",
            ])
    }

    @Test func theSFTPCommandSurvivesResticsSplittingIntactDespiteSpaces() throws {
        let arguments = try restic.globalArguments(for: Fixture.target(port: 23))
        #expect(
            arguments.prefix(2) == ["--repo", "sftp://u123456-sub1@u123456.your-storagebox.de:23//home/restic/mac"])
        #expect(arguments[2] == "-o")
        let value = try #require(csvValue(arguments[3]))
        #expect(value.hasPrefix("sftp.command="))
        let split = resticSplit(String(value.dropFirst("sftp.command=".count)))
        #expect(split == SSHCommand.resticSFTP(for: Fixture.target(port: 23), paths: paths))
        #expect(split?.first == "/usr/bin/ssh")
        #expect(split?.suffix(6) == ["-p", "23", "-s", "--", "u123456-sub1@u123456.your-storagebox.de", "sftp"])
    }

    @Test func quotingPicksTheQuoteTheArgumentDoesNotContain() throws {
        let arguments = ["/a b/c", "it's", "Known=\"x y\"", "plain"]
        let quoted = try CommandQuoting.resticShell(arguments)
        #expect(quoted == "'/a b/c' \"it's\" 'Known=\"x y\"' 'plain'")
        #expect(resticSplit(quoted) == arguments)
    }

    @Test(arguments: ["back\\slash", "both'\"", ""])
    func quotingRefusesWhatResticCannotSplitBack(argument: String) {
        #expect(throws: UnquotableArgument(argument: argument)) { try CommandQuoting.resticShell([argument]) }
    }

    @Test func csvFieldDoublesQuotesAndKeepsCommas() {
        #expect(CommandQuoting.csvField("a,\"b\"") == "\"a,\"\"b\"\"\"")
    }

    @Test func globalFlagsSetTheAppsOwnCacheAndTheUploadLimit() throws {
        var target = Fixture.target()
        target.uploadLimitKiBPerSecond = 2441
        let arguments = try restic.globalArguments(for: target)
        #expect(
            arguments.suffix(4) == [
                "--cache-dir", "/Users/example/Library/Caches/de.rocu.BackupSquirrel/restic", "--limit-upload", "2441",
            ])
        #expect(try !restic.globalArguments(for: Fixture.target()).contains("--limit-upload"))
    }

    @Test func aLocalRepositoryNeedsNoSSH() throws {
        var local = restic
        local.access = .local(URL(fileURLWithPath: "/tmp/repo"))
        #expect(
            try local.globalArguments(for: Fixture.target()) == [
                "--repo", "/tmp/repo", "--cache-dir", "/Users/example/Library/Caches/de.rocu.BackupSquirrel/restic",
            ])
    }

    @Test func thePasswordGoesToStdinAndNeverIntoArgumentsOrEnvironment() throws {
        let invocation = try restic.invocation(
            ["key", "passwd"], for: Fixture.target(), password: "secret-1", newPassword: "secret-2")
        #expect(invocation.standardInput == Data("secret-1\n".utf8))
        #expect(invocation.extraInput == Data("secret-2\n".utf8))
        #expect(
            invocation.environment == [
                "HOME": "/Users/example", "TMPDIR": "/var/folders/xy/T", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "RESTIC_PROGRESS_FPS": "1",
            ])
        let visible = invocation.arguments + invocation.environment.map { "\($0.key)=\($0.value)" }
        #expect(!visible.contains { $0.contains("secret") })
        #expect(invocation.arguments.prefix(2) == ["key", "passwd"])
    }

    @Test func backupTagsThePlanAndEscapesExcludedFolders() {
        var plan = Fixture.plan(
            id: UUID(uuidString: "ABCDEF00-0000-4000-8000-0000000000B1")!,
            sourceFolders: [URL(fileURLWithPath: "/Users/example"), URL(fileURLWithPath: "/Volumes/Daten")])
        plan.exclusions = [.path(URL(fileURLWithPath: "/Users/example/Fotos [alt]*")), .pattern("*.tmp")]
        #expect(
            ResticJobRunner.backupArguments(for: plan, hostName: "mac-mini") == [
                "backup", "--json", "--host", "mac-mini", "--tag", "abcdef00-0000-4000-8000-0000000000b1",
                "--exclude", "/Users/example/Fotos \\[alt\\]\\*", "--exclude", "*.tmp",
                "/Users/example", "/Volumes/Daten",
            ])
    }

    @Test func retentionThinsOnlyThisPlansSnapshots() {
        #expect(
            ResticJobRunner.forgetArguments(for: Fixture.plan(), hostName: "mac-mini") == [
                "forget", "--json", "--host", "mac-mini", "--tag", Fixture.homeID.uuidString.lowercased(),
                "--group-by", "host,tags", "--keep-within", "24h", "--keep-daily", "30", "--keep-weekly", "52",
                "--keep-monthly", "unlimited",
            ])
    }

    @Test func theConnectionTestAcceptsANewHostKeyAndUsesSFTPsPortFlag() {
        let arguments = SSHCommand.sftpBatch(for: Fixture.target(port: 23), paths: paths, hostKeys: .acceptNew)
        #expect(arguments.prefix(2) == ["-b", "-"])
        #expect(arguments.contains("StrictHostKeyChecking=accept-new"))
        #expect(arguments.suffix(4) == ["-P", "23", "--", "u123456-sub1@u123456.your-storagebox.de"])
    }

    @Test func keyFilesLiveInTheAppsKeysFolder() {
        let id = Fixture.targetID
        #expect(paths.pathFromHome(paths.publicKey(for: id)) == SSHKey.defaultPath(for: id))
        #expect(paths.knownHosts(for: id).lastPathComponent == "\(id.uuidString.lowercased()).known_hosts")
        #expect(paths.pathFromHome(URL(fileURLWithPath: "/tmp/x")) == "/tmp/x")
    }

    @Test func theStandardPathsKeepResticsCacheApartFromTheOwners() {
        let standard = AppPaths.standard
        #expect(standard.applicationSupport.path.hasSuffix("Library/Application Support/Backup-Squirrel"))
        #expect(standard.resticCache.path.hasSuffix("Library/Caches/de.rocu.BackupSquirrel/restic"))
    }
}
