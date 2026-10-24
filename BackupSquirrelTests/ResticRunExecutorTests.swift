import Foundation
import Synchronization
import Testing

@testable import BackupSquirrel

@MainActor
struct ResticRunExecutorTests {
    private static let summary =
        #"{"message_type":"summary","files_new":214,"files_changed":87,"files_unmodified":28600,"#
        + #""data_added":312427000,"total_bytes_processed":41215000000,"snapshot_id":"9b31d2c7aa"}"#
    private static let status =
        #"{"message_type":"status","percent_done":0.5,"total_files":10,"files_done":5,"total_bytes":100,"#
        + #""bytes_done":50,"seconds_remaining":7}"#
    private static let forgetOneRemoved = #"[{"tags":["x"],"host":"mac","keep":[{}],"remove":[{}]}]"#
    private static let unreadable =
        #"{"message_type":"error","error":{"message":"permission denied"},"during":"archival","#
        + #""item":"/Users/example/Documents/geheim.txt"}"#

    private let passwords = InMemoryPasswordStore([Fixture.targetID: "correct horse"])
    private let pushes = URLRecorder()

    private func executor(_ runner: any ProcessRunner, kumaStatus: Int = 200) -> ResticRunExecutor {
        let pushes = pushes
        return ResticRunExecutor(
            restic: Restic(
                binary: URL(fileURLWithPath: "/tmp/restic"),
                paths: AppPaths(
                    home: URL(fileURLWithPath: "/Users/example"), applicationSupport: URL(fileURLWithPath: "/a"),
                    caches: URL(fileURLWithPath: "/c"), temporary: URL(fileURLWithPath: "/t"))),
            runner: runner,
            passwords: passwords,
            hostName: "mac-mini",
            uptimeKuma: UptimeKuma { url in
                pushes.append(url)
                return (Data(), kumaStatus)
            },
            clock: { Fixture.now }
        )
    }

    private func events(of job: RunJob, on runner: any ProcessRunner, kumaStatus: Int = 200) async -> [RunEvent] {
        var events: [RunEvent] = []
        for await event in executor(runner, kumaStatus: kumaStatus).execute(job).events { events.append(event) }
        return events
    }

    private func outcome(of job: RunJob, on runner: any ProcessRunner, kumaStatus: Int = 200) async -> RunOutcome? {
        guard case .finished(let outcome) = await events(of: job, on: runner, kumaStatus: kumaStatus).last else {
            return nil
        }
        return outcome
    }

    private var kumaPlan: Plan { Fixture.plan(uptimeKumaPushURL: "https://uptime.example.com/api/push/abc") }

    @Test func aBackupUnlocksBacksUpThinsAndReportsProgress() async throws {
        let runner = FakeProcessRunner([
            "backup": [.exit(0, stdout: ["using parent snapshot 4f2a9c1e", Self.status, Self.summary])],
            "forget": [.exit(0, stdout: [Self.forgetOneRemoved])],
        ])
        let events = await events(of: .backup(Fixture.plan(), Fixture.target()), on: runner)
        #expect(runner.commands == ["unlock", "backup", "forget"])
        #expect(
            events.first
                == .progress(
                    OperationProgress(
                        fractionCompleted: 0.5, filesDone: 5, filesTotal: 10, bytesDone: 50, bytesTotal: 100,
                        secondsRemaining: 7)))
        guard case .finished(let outcome) = events.last else { throw CancellationError() }
        #expect(outcome.status == .success)
        #expect(outcome.failure == nil)
        #expect(
            outcome.details
                == .backup(
                    BackupStatistics(
                        filesNew: 214, filesChanged: 87, filesUnmodified: 28_600, bytesAdded: 312_427_000,
                        bytesProcessed: 41_215_000_000, snapshotID: "9b31d2c7", snapshotsForgotten: 1)))
        #expect(outcome.monitorPush == nil)
        #expect(pushes.all.isEmpty)
        #expect(outcome.output.contains("$ restic unlock"))
        #expect(outcome.output.contains("using parent snapshot 4f2a9c1e"))
        #expect(outcome.output.contains("1 ältere Sicherung entfernt"))
        #expect(!outcome.output.contains("\"status\""))
        #expect(!outcome.output.contains(Self.forgetOneRemoved))
    }

    @Test func unreadableFilesMakeAWarningThatStillReportsUp() async throws {
        let runner = FakeProcessRunner([
            "backup": [
                FakeProcessRunner.Response(
                    lines: [
                        .standardError(Self.unreadable.replacingOccurrences(of: "archival", with: "scan")),
                        .standardError(Self.unreadable), .standardOutput(Self.summary),
                    ], exitCode: 3)
            ]
        ])
        let outcome = try #require(await outcome(of: .backup(kumaPlan, Fixture.target()), on: runner))
        #expect(outcome.status == .warning)
        guard case .backup(let statistics) = outcome.details else { throw CancellationError() }
        #expect(statistics.unreadableFiles == ["/Users/example/Documents/geheim.txt"])
        #expect(outcome.monitorPush == MonitorPush(sentAt: Fixture.now))
        let query = pushes.all.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        #expect(query?.queryItems?.first { $0.name == "status" }?.value == "up")
        #expect(outcome.output.contains("An Uptime Kuma gemeldet"))
    }

    @Test func aRejectedPushIsRecordedWithoutFailingTheBackup() async throws {
        let runner = FakeProcessRunner(["backup": [.exit(0, stdout: [Self.summary])]])
        let outcome = try #require(
            await outcome(of: .backup(kumaPlan, Fixture.target()), on: runner, kumaStatus: 404))
        #expect(outcome.status == .success)
        #expect(outcome.monitorPush == MonitorPush(sentAt: Fixture.now, failure: .rejected(statusCode: 404)))
        #expect(outcome.output.contains("Uptime Kuma kennt diese Push-URL nicht (HTTP 404)"))
    }

    @Test func aFailedForgetLeavesTheBackupSuccessful() async throws {
        let runner = FakeProcessRunner([
            "backup": [.exit(0, stdout: [Self.summary])],
            "forget": [.exit(11, stderr: ["Fatal: unable to create lock in backend"])],
        ])
        let outcome = try #require(await outcome(of: .backup(Fixture.plan(), Fixture.target()), on: runner))
        #expect(outcome.status == .success)
        #expect(outcome.output.contains("Ältere Sicherungen nicht ausgedünnt: Repository gesperrt"))
    }

    @Test func aWrongPasswordFailsWithoutThinningOrReporting() async throws {
        let runner = FakeProcessRunner([
            "backup": [.exit(12, stderr: ["Fatal: wrong password or no key found"])]
        ])
        let outcome = try #require(await outcome(of: .backup(kumaPlan, Fixture.target()), on: runner))
        #expect(outcome.status == .failed)
        #expect(outcome.failure == .other("Repository-Passwort passt nicht"))
        #expect(runner.commands == ["unlock", "backup"])
        #expect(outcome.monitorPush == nil)
        #expect(pushes.all.isEmpty)
    }

    @Test func anUnreachableServerStopsAtTheUnlock() async throws {
        let runner = FakeProcessRunner([
            "unlock": [.exit(1, stderr: ["ssh: connect to host u1.example port 23: Connection refused"])]
        ])
        let outcome = try #require(await outcome(of: .backup(Fixture.plan(), Fixture.target()), on: runner))
        #expect(outcome.status == .failed)
        #expect(outcome.failure == .targetUnreachable)
        #expect(runner.commands == ["unlock"])
        #expect(outcome.output.contains("Connection refused"))
    }

    @Test func aMissingPasswordFailsWithoutRunningRestic() async throws {
        passwords.removePassword(for: Fixture.targetID)
        let runner = FakeProcessRunner()
        let outcome = try #require(await outcome(of: .backup(Fixture.plan(), Fixture.target()), on: runner))
        #expect(outcome.status == .failed)
        #expect(outcome.failure == .other("Repository-Passwort fehlt im Schlüsselbund"))
        #expect(runner.invocations.isEmpty)
    }

    @Test func thePasswordGoesToStdinAndIsRedactedFromTheOutput() async throws {
        let runner = FakeProcessRunner(["backup": [.exit(1, stderr: ["echo: correct horse"])]])
        let outcome = try #require(await outcome(of: .backup(Fixture.plan(), Fixture.target()), on: runner))
        #expect(runner.invocations.allSatisfy { $0.standardInput == Data("correct horse\n".utf8) })
        #expect(runner.invocations.allSatisfy { $0.environment["RESTIC_PASSWORD"] == nil })
        #expect(!outcome.output.contains("correct horse"))
    }

    @Test func aCheckReadsItsSubset() async throws {
        let runner = FakeProcessRunner([
            "check": [.exit(0, stdout: [#"{"message_type":"summary","num_errors":0}"#])]
        ])
        let outcome = try #require(await outcome(of: .check(Fixture.target(), subset: 8), on: runner))
        #expect(runner.invocation("check")?.arguments.prefix(3) == ["check", "--json", "--read-data-subset=8/128"])
        #expect(outcome.status == .success)
        #expect(outcome.details == .check(CheckStatistics(subset: 8)))
    }

    @Test func aCheckThatFindsDamageFailsWithAnErrorCountButNoFailure() async throws {
        let runner = FakeProcessRunner([
            "check": [.exit(1, stdout: [#"{"message_type":"summary","num_errors":3}"#])]
        ])
        let outcome = try #require(await outcome(of: .check(Fixture.target(), subset: 8), on: runner))
        #expect(outcome.status == .failed)
        #expect(outcome.details == .check(CheckStatistics(subset: 8, errorCount: 3)))
        #expect(outcome.failure == nil)
    }

    @Test func aCheckThatCouldNotRunHasAFailure() async throws {
        let runner = FakeProcessRunner(["check": [.exit(1, stderr: ["subprocess ssh: exit status 255"])]])
        let outcome = try #require(await outcome(of: .check(Fixture.target(), subset: 8), on: runner))
        #expect(outcome.status == .failed)
        #expect(outcome.failure == .targetUnreachable)
    }

    @Test func aPruneReportsTheSpaceItFreed() async throws {
        let runner = FakeProcessRunner([
            "prune": [.exit(0, stdout: ["total prune:          14 blobs / 2.000 MiB", "done"])]
        ])
        let outcome = try #require(await outcome(of: .prune(Fixture.target()), on: runner))
        #expect(outcome.status == .success)
        #expect(outcome.details == .prune(PruneStatistics(bytesFreed: 2_097_152)))
        #expect(outcome.output.contains("total prune:"))
    }

    @Test func aBinaryThatCannotStartFailsTheRun() async throws {
        let outcome = try #require(await outcome(of: .prune(Fixture.target()), on: LaunchFailingRunner(code: EACCES)))
        #expect(outcome.status == .failed)
        #expect(outcome.failure == .other("restic konnte nicht gestartet werden"))
    }

    @Test func aMissingBinaryFailsTheRunSayingSo() async throws {
        let outcome = try #require(await outcome(of: .prune(Fixture.target()), on: LaunchFailingRunner(code: ENOENT)))
        #expect(outcome.status == .failed)
        #expect(outcome.failure == .other("restic fehlt im Programmpaket"))
    }

    @Test func stoppingEndsResticAndFinishesCancelledWithItsOutput() async throws {
        let runner = FakeProcessRunner([
            "backup": [FakeProcessRunner.Response(lines: [.standardOutput("scan started")], hangs: true)]
        ])
        let execution = executor(runner).execute(.backup(kumaPlan, Fixture.target()))
        let consumer = Task {
            var events: [RunEvent] = []
            for await event in execution.events { events.append(event) }
            return events
        }
        while runner.commands.count < 2 { await Task.yield() }
        execution.stop()
        guard case .finished(let outcome) = await consumer.value.last else { throw CancellationError() }
        #expect(outcome.status == .cancelled)
        #expect(outcome.output.contains("scan started"))
        #expect(pushes.all.isEmpty)
    }

    @Test func cancellingTheStreamStopsResticAndFinishesNothing() async {
        let runner = FakeProcessRunner(["backup": [FakeProcessRunner.Response(hangs: true)]])
        let stream = executor(runner).execute(.backup(kumaPlan, Fixture.target())).events
        let consumer = Task {
            var events: [RunEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        while runner.commands.count < 2 { await Task.yield() }
        consumer.cancel()
        #expect(await consumer.value.isEmpty)
        #expect(runner.commands == ["unlock", "backup"])
        #expect(pushes.all.isEmpty)
    }

    @Test func reportingAgainSendsTheRunsSummaryAndDuration() async throws {
        let run = Fixture.backup(at: Fixture.date(2026, 10, 14, 13, 2), duration: 180)
        let failure = await executor(FakeProcessRunner()).report(run, of: kumaPlan)
        #expect(failure == nil)
        let url = try #require(pushes.all.first)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "ping" }?.value == "180000")
        #expect(items.first { $0.name == "msg" }?.value == "214 neu, 87 geändert, 312,4 MB")
    }
}

private struct LaunchFailingRunner: ProcessRunner {
    var code: Int32

    func run(_ invocation: ProcessInvocation, onOutput: @escaping @Sendable (OutputLine) -> Void) async throws -> Int32
    {
        throw ProcessLaunchError(code: code)
    }
}

private final class URLRecorder: Sendable {
    private let urls = Mutex<[URL]>([])

    var all: [URL] { urls.withLock { $0 } }

    func append(_ url: URL) {
        urls.withLock { $0.append(url) }
    }
}
