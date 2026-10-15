import Foundation
import Testing

@testable import BackupSquirrel

struct ResticConnectionTests {
    private func connection(_ runner: FakeProcessRunner) -> ResticConnection {
        ResticConnection(
            restic: Restic(
                binary: URL(fileURLWithPath: "/tmp/restic"),
                paths: AppPaths(
                    home: URL(fileURLWithPath: "/Users/example"), applicationSupport: URL(fileURLWithPath: "/a"),
                    caches: URL(fileURLWithPath: "/c"), temporary: URL(fileURLWithPath: "/t"))),
            runner: runner)
    }

    @Test func theTestOpensOneSFTPSessionAndAcceptsANewHostKey() async throws {
        let runner = FakeProcessRunner()
        #expect(await connection(runner).test(Fixture.target()) == .succeeded)
        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executable.path == "/usr/bin/sftp")
        #expect(invocation.arguments.contains("StrictHostKeyChecking=accept-new"))
        #expect(invocation.standardInput == Data("pwd\n".utf8))
        #expect(invocation.environment["HOME"] == "/Users/example")
    }

    @Test(arguments: [
        ("u1@u1.example: Permission denied (publickey).", "SSH-Schlüssel ist noch nicht installiert"),
        ("ssh: Could not resolve hostname u1.example: nodename nor servname provided", "Server nicht gefunden"),
        ("ssh: connect to host u1.example port 23: Operation timed out", "Server nicht erreichbar"),
        ("@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @", "Hostschlüssel des Servers hat sich geändert"),
        ("Connection closed", "Server nicht erreichbar"),
        ("something odd", "Verbindung fehlgeschlagen"),
    ])
    func aFailedTestSaysWhy(error: String, message: String) async {
        let runner = FakeProcessRunner(["-b": [.exit(255, stderr: [error])]])
        #expect(await connection(runner).test(Fixture.target()) == .failed(message))
    }

    @Test func anExistingRepositoryIsFoundWithItsSnapshotCount() async throws {
        let runner = FakeProcessRunner([
            "-b": [
                .exit(
                    0,
                    stdout: [
                        #"sftp> -ls -1 "/home/restic/mac/config""#, "/home/restic/mac/config",
                        #"sftp> -ls -1 "/home/restic/mac/snapshots""#, "/home/restic/mac/snapshots/a1",
                        "/home/restic/mac/snapshots/b2", "/home/restic/mac/snapshots/c3",
                    ])
            ]
        ])
        #expect(await connection(runner).detectRepository(at: Fixture.target()) == .found(snapshots: 3))
        let invocation = try #require(runner.invocations.first)
        #expect(
            invocation.standardInput
                == Data("-ls -1 \"/home/restic/mac/config\"\n-ls -1 \"/home/restic/mac/snapshots\"\n".utf8))
        #expect(invocation.arguments.contains("StrictHostKeyChecking=yes"))
    }

    @Test func aPathWithAControlCharacterIsNeverSentToSFTP() async {
        let runner = FakeProcessRunner()
        var target = Fixture.target()
        target.path = "backups\n!rm -rf ~"
        #expect(await connection(runner).detectRepository(at: target) == .notFound)
        #expect(runner.invocations.isEmpty)
    }

    @Test func withoutAConfigThereIsNoRepository() async {
        let runner = FakeProcessRunner([
            "-b": [.exit(0, stdout: [#"sftp> -ls -1 "mac/config""#, #"sftp> -ls -1 "mac/snapshots""#])]
        ])
        #expect(await connection(runner).detectRepository(at: Fixture.target()) == .notFound)
    }

    @Test(arguments: [
        ("/home/restic/mac/", "/home/restic/mac/config"), ("backups", "backups/config"), ("", "config"),
        ("/", "/config"),
    ])
    func repositoryFilesSitBelowTheTargetsPath(path: String, expected: String) {
        var target = Fixture.target()
        target.path = path
        #expect(ResticConnection.remotePath("config", in: target) == expected)
    }

    @Test func aWrongPasswordIsToldApartFromOtherProblems() async {
        let wrong = FakeProcessRunner(["cat": [.exit(12)]])
        #expect(await connection(wrong).verifyPassword("x", for: Fixture.target()) == .wrong)
        let unreachable = FakeProcessRunner(["cat": [.exit(1, stderr: ["subprocess ssh: exit status 255"])]])
        #expect(
            await connection(unreachable).verifyPassword("x", for: Fixture.target())
                == .failed("Storage Box nicht erreichbar"))
        let fine = FakeProcessRunner()
        #expect(await connection(fine).verifyPassword("x", for: Fixture.target()) == .matches)
        #expect(fine.invocations.first?.arguments.prefix(2) == ["cat", "config"])
        #expect(fine.invocations.first?.standardInput == Data("x\n".utf8))
    }

    @Test func creatingTheRepositoryRunsInit() async {
        let runner = FakeProcessRunner()
        #expect(await connection(runner).createRepository(for: Fixture.target(), password: "pw") == .succeeded)
        #expect(runner.commands == ["init"])
        let failing = FakeProcessRunner(["init": [.exit(1, stderr: ["Fatal: create key in repository failed"])]])
        #expect(
            await connection(failing).createRepository(for: Fixture.target(), password: "pw")
                == .failed("restic-Fehler 1"))
    }

    @Test func changingThePasswordPassesTheNewOneOnFileDescriptor3() async throws {
        let runner = FakeProcessRunner()
        #expect(await connection(runner).changePassword(of: Fixture.target(), from: "old", to: "new") == .succeeded)
        let invocation = try #require(runner.invocations.first)
        #expect(invocation.arguments.prefix(4) == ["key", "passwd", "--new-password-file", "/dev/fd/3"])
        #expect(invocation.standardInput == Data("old\n".utf8))
        #expect(invocation.extraInput == Data("new\n".utf8))
        let wrong = FakeProcessRunner(["key": [.exit(12)]])
        #expect(
            await connection(wrong).changePassword(of: Fixture.target(), from: "old", to: "new")
                == .failed("Bisheriges Passwort passt nicht"))
    }
}
