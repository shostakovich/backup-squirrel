import Foundation
import Synchronization

@MainActor
final class ResticRunExecutor: RunExecutor {
    private let jobs: ResticJobRunner

    init(
        restic: Restic,
        runner: any ProcessRunner = PosixProcessRunner(),
        passwords: any PasswordStore,
        hostName: String,
        uptimeKuma: UptimeKuma = .live,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        jobs = ResticJobRunner(
            restic: restic, runner: runner, passwords: passwords, hostName: hostName, uptimeKuma: uptimeKuma,
            clock: clock)
    }

    func execute(_ job: RunJob) -> RunExecution {
        let jobs = jobs
        let (events, continuation) = AsyncStream<RunEvent>.makeStream()
        let task = Task { @MainActor in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: "restic läuft")
            let outcome = await jobs.perform(job, progress: { continuation.yield(.progress($0)) })
            continuation.yield(.finished(outcome))
            ProcessInfo.processInfo.endActivity(activity)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return RunExecution(events: events, stop: { task.cancel() })
    }

    func report(_ run: Run, of plan: Plan) async -> PushFailure? {
        await jobs.report(run, of: plan)
    }
}

struct ResticJobRunner: Sendable {
    static let retention = [
        "--group-by", "host,tags", "--keep-within", "24h", "--keep-daily", "30", "--keep-weekly", "52",
        "--keep-monthly", "unlimited",
    ]

    var restic: Restic
    var runner: any ProcessRunner
    var passwords: any PasswordStore
    var hostName: String
    var uptimeKuma: UptimeKuma
    var clock: @Sendable () -> Date

    /// A cancelled job ends as cancelled once restic has exited, with what it printed until then.
    func perform(_ job: RunJob, progress: @escaping @Sendable (OperationProgress) -> Void) async -> RunOutcome {
        let target = job.target
        let details = Self.emptyDetails(for: job)
        guard let password = passwords.password(for: target.id) else {
            return RunOutcome(
                status: .failed, details: details, failure: .other("Repository-Passwort fehlt im Schlüsselbund"),
                output: "")
        }
        let session = Session(
            jobs: self, target: target, password: password, log: Log(redacting: password), progress: progress)
        do {
            let unlock = try await session.run(["unlock"])
            guard unlock.exitCode == 0 else {
                return session.outcome(.failed, details, failure: unlock.failure)
            }
            switch job {
            case .backup(let plan, _): return try await backup(plan, in: session)
            case .check(_, let subset): return try await check(subset: subset, in: session)
            case .prune: return try await prune(in: session)
            }
        } catch let error as ProcessLaunchError {
            let message =
                error.code == ENOENT ? "restic fehlt im Programmpaket" : "restic konnte nicht gestartet werden"
            return session.outcome(.failed, details, failure: .other(message))
        } catch is UnquotableArgument {
            return session.outcome(.failed, details, failure: .other("Zugangsdaten enthalten ungültige Zeichen"))
        } catch {
            return session.outcome(.cancelled, details)
        }
    }

    func report(_ run: Run, of plan: Plan) async -> PushFailure? {
        guard case .backup(let statistics) = run.details else { return nil }
        return await uptimeKuma.push(to: plan.uptimeKumaPushURL, statistics: statistics, duration: run.duration ?? 0)
    }

    static func backupArguments(for plan: Plan, hostName: String) -> [String] {
        let exclusions = plan.exclusions.flatMap { exclusion in
            switch exclusion {
            case .path(let url): ["--exclude", CommandQuoting.resticGlob(url.path)]
            case .pattern(let pattern): ["--exclude", pattern]
            }
        }
        return ["backup", "--json", "--host", hostName, "--tag", tag(for: plan)] + exclusions
            + plan.sourceFolders.map(\.path)
    }

    static func forgetArguments(for plan: Plan, hostName: String) -> [String] {
        ["forget", "--json", "--host", hostName, "--tag", tag(for: plan)] + retention
    }

    static func tag(for plan: Plan) -> String {
        plan.id.uuidString.lowercased()
    }

    private func backup(_ plan: Plan, in session: Session) async throws -> RunOutcome {
        let startedAt = clock()
        let backup = try await session.run(Self.backupArguments(for: plan, hostName: hostName))
        let duration = clock().timeIntervalSince(startedAt)
        var statistics = BackupStatistics()
        var unreadableFiles: [String] = []
        for message in backup.messages {
            switch message {
            case .backupSummary(let summary): statistics = summary
            // restic reports an unreadable item once while scanning and again while archiving.
            case .error(let item?, _) where !unreadableFiles.contains(item): unreadableFiles.append(item)
            default: break
            }
        }
        statistics.unreadableFiles = unreadableFiles
        let status: RunStatus
        switch backup.exitCode {
        case 0: status = .success
        case 3: status = .warning
        default: return session.outcome(.failed, .backup(statistics), failure: backup.failure)
        }

        let forget = try await session.run(Self.forgetArguments(for: plan, hostName: hostName), logsOutput: false)
        if forget.exitCode == 0, let removed = ForgetOutput.removedCount(in: forget.output) {
            statistics.snapshotsForgotten = removed
            session.log.append(RunText.olderBackupsRemoved(removed))
        } else {
            let reason = RunText.reason(forget.failure, targetName: session.target.name)
            session.log.append("Ältere Sicherungen nicht ausgedünnt: \(reason)")
        }

        var monitorPush: MonitorPush?
        if plan.reportsToUptimeKuma {
            try Task.checkCancellation()
            let failure = await uptimeKuma.push(
                to: plan.uptimeKumaPushURL, statistics: statistics, duration: duration)
            monitorPush = MonitorPush(sentAt: clock(), failure: failure)
            session.log.append(failure.map { "Uptime Kuma: \(RunText.pushReason($0))" } ?? "An Uptime Kuma gemeldet")
        }
        var outcome = session.outcome(status, .backup(statistics))
        outcome.monitorPush = monitorPush
        return outcome
    }

    private func check(subset: Int, in session: Session) async throws -> RunOutcome {
        var statistics = CheckStatistics(subset: subset)
        let check = try await session.run([
            "check", "--json", "--read-data-subset=\(statistics.subset)/\(statistics.subsetCount)",
        ])
        let errorCount = check.messages.lazy.compactMap { message -> Int? in
            if case .checkSummary(let errorCount) = message { errorCount } else { nil }
        }.last
        statistics.errorCount = errorCount ?? 0
        if check.exitCode == 0 { return session.outcome(.success, .check(statistics)) }
        if statistics.errorCount > 0 { return session.outcome(.failed, .check(statistics)) }
        return session.outcome(.failed, .check(statistics), failure: check.failure)
    }

    private func prune(in session: Session) async throws -> RunOutcome {
        let prune = try await session.run(["prune"])
        guard prune.exitCode == 0 else {
            return session.outcome(.failed, .prune(PruneStatistics()), failure: prune.failure)
        }
        let bytesFreed = PruneOutput.bytesFreed(in: prune.output) ?? 0
        return session.outcome(.success, .prune(PruneStatistics(bytesFreed: bytesFreed)))
    }

    private static func emptyDetails(for job: RunJob) -> RunDetails {
        switch job {
        case .backup: .backup(BackupStatistics())
        case .check(_, let subset): .check(CheckStatistics(subset: subset))
        case .prune: .prune(PruneStatistics())
        }
    }
}

private struct StepResult {
    var exitCode: Int32
    var output: [String]
    var errors: [String]
    var messages: [ResticMessage]

    var failure: RunFailure {
        ResticFailure.classify(exitCode: exitCode, errorLines: errors + output)
    }
}

private struct Session {
    let jobs: ResticJobRunner
    let target: Target
    let password: String
    let log: Log
    let progress: @Sendable (OperationProgress) -> Void

    func run(_ command: [String], logsOutput: Bool = true) async throws -> StepResult {
        let invocation = try jobs.restic.invocation(command, for: target, password: password)
        log.append("$ restic \(command.joined(separator: " "))")
        let collected = Mutex(StepResult(exitCode: 0, output: [], errors: [], messages: []))
        let log = log
        let progress = progress
        let exitCode = try await jobs.runner.run(invocation) { line in
            switch line {
            case .standardOutput(let text):
                let message = ResticMessage.parse(text)
                if case .status(let current) = message { return progress(current) }
                collected.withLock {
                    $0.output.append(text)
                    if let message { $0.messages.append(message) }
                }
                if logsOutput { log.append(text) }
            case .standardError(let text):
                collected.withLock {
                    $0.errors.append(text)
                    if let message = ResticMessage.parse(text) { $0.messages.append(message) }
                }
                log.append(text)
            }
        }
        return collected.withLock {
            $0.exitCode = exitCode
            return $0
        }
    }

    func outcome(_ status: RunStatus, _ details: RunDetails, failure: RunFailure? = nil) -> RunOutcome {
        RunOutcome(status: status, details: details, failure: failure, output: log.text)
    }
}

private final class Log: Sendable {
    private let lines = Mutex<[String]>([])
    private let secret: String

    init(redacting secret: String) {
        self.secret = secret
    }

    func append(_ line: String) {
        let safe = secret.isEmpty ? line : line.replacingOccurrences(of: secret, with: "••••••")
        lines.withLock { $0.append(safe) }
    }

    var text: String { lines.withLock { $0.joined(separator: "\n") } }
}
