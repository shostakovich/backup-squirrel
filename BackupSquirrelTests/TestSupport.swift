import Foundation

@testable import BackupSquirrel

enum Fixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "de_DE")
        return calendar
    }()

    /// Wednesday, 14 October 2026, 13:20 in Berlin.
    static let now = date(2026, 10, 14, 13, 20)

    static let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    static let targetID = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    static let homeID = UUID(uuidString: "00000000-0000-4000-8000-0000000000b1")!
    static let dataID = UUID(uuidString: "00000000-0000-4000-8000-0000000000b2")!

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0)
        -> Date
    {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static func target(
        id: UUID = targetID, name: String = "Storage Box", port: Int = 23, createdAt: Date = date(2026, 10, 10)
    ) -> Target {
        Target(
            id: id,
            name: name,
            host: "u123456.your-storagebox.de",
            user: "u123456-sub1",
            port: port,
            path: "/home/restic/mac",
            sshKey: SSHKey(
                publicKey: "ssh-ed25519 AAAA example",
                publicKeyPath: "Library/Application Support/Backup-Squirrel/Keys/storage-box.pub"),
            createdAt: createdAt
        )
    }

    static func plan(
        id: UUID = homeID,
        name: String = "Home-Verzeichnis",
        targetID: UUID? = Fixture.targetID,
        automatic: Bool = true,
        sourceFolders: [URL] = [URL(fileURLWithPath: "/Users/example/Documents", isDirectory: true)],
        schedule: Schedule = .everyHours(1),
        uptimeKumaPushURL: String = "",
        createdAt: Date = date(2026, 1, 1)
    ) -> Plan {
        Plan(
            id: id, name: name, targetID: targetID, backsUpAutomatically: automatic, sourceFolders: sourceFolders,
            schedule: schedule, uptimeKumaPushURL: uptimeKumaPushURL, createdAt: createdAt)
    }

    static func backup(
        plan: UUID = homeID,
        status: RunStatus = .success,
        at start: Date,
        duration: TimeInterval = 180,
        statistics: BackupStatistics = BackupStatistics(filesNew: 214, filesChanged: 87, bytesAdded: 312_427_000),
        failure: RunFailure? = nil,
        monitorPush: MonitorPush? = nil
    ) -> Run {
        Run(
            planID: plan,
            targetID: targetID,
            status: status,
            startedAt: start,
            finishedAt: status == .running ? nil : start.addingTimeInterval(duration),
            details: .backup(statistics),
            failure: failure ?? (status == .failed ? .targetUnreachable : nil),
            monitorPush: monitorPush
        )
    }

    static func check(
        status: RunStatus = .success, at start: Date, subset: Int = 7, errorCount: Int = 0, failure: RunFailure? = nil
    ) -> Run {
        Run(
            targetID: targetID,
            status: status,
            startedAt: start,
            finishedAt: status == .running ? nil : start.addingTimeInterval(226),
            details: .check(CheckStatistics(subset: subset, errorCount: errorCount)),
            failure: failure ?? (status == .failed && errorCount == 0 ? .targetUnreachable : nil)
        )
    }

    static func prune(status: RunStatus = .success, at start: Date, failure: RunFailure? = nil) -> Run {
        Run(
            targetID: targetID,
            status: status,
            startedAt: start,
            finishedAt: status == .running ? nil : start.addingTimeInterval(97),
            details: .prune(PruneStatistics(snapshotsRemoved: 14, bytesFreed: 2_104_000_000)),
            failure: failure ?? (status == .failed ? .targetUnreachable : nil)
        )
    }

    /// Awake for a day unless a test says otherwise, so the catch-up grace period is over.
    static func state(
        plans: [Plan] = [plan()],
        targets: [Target] = [target()],
        runs: [Run] = [],
        progress: OperationProgress? = nil,
        now: Date = now,
        awakeSince: Date? = nil,
        system: SystemState = SystemState(),
        queued: [RunRequest] = []
    ) -> BackupState {
        BackupState(
            plans: plans, targets: targets, runs: runs, progress: progress, now: now,
            awakeSince: awakeSince ?? now.addingTimeInterval(-24 * 3600), system: system, queued: queued)
    }

    /// Recent checks and prunes, so the target is healthy and only the plans matter.
    static func maintenance() -> [Run] {
        [check(at: date(2026, 10, 12, 4, 0)), prune(at: date(2026, 10, 11, 5, 0))]
    }

    static func progress(filesDone: Int = 12_345, filesTotal: Int = 28_901, secondsRemaining: TimeInterval? = 1_100)
        -> OperationProgress
    {
        OperationProgress(
            fractionCompleted: Double(filesDone) / Double(max(filesTotal, 1)),
            filesDone: filesDone,
            filesTotal: filesTotal,
            bytesDone: 0,
            bytesTotal: 0,
            secondsRemaining: secondsRemaining
        )
    }
}

@MainActor
final class MockRunExecutor: RunExecutor {
    private(set) var jobs: [RunJob] = []
    private(set) var reports: [String] = []
    var reportResult: PushFailure?
    private var continuation: AsyncStream<RunEvent>.Continuation?

    func report(_ run: Run, of plan: Plan) async -> PushFailure? {
        reports.append(plan.uptimeKumaPushURL)
        return reportResult
    }

    func execute(_ job: RunJob) -> RunExecution {
        jobs.append(job)
        let (stream, continuation) = AsyncStream<RunEvent>.makeStream()
        self.continuation = continuation
        return RunExecution(events: stream) { continuation.finish() }
    }

    func send(_ event: RunEvent) {
        continuation?.yield(event)
    }

    func finish(with outcome: RunOutcome) {
        continuation?.yield(.finished(outcome))
        continuation?.finish()
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@MainActor
func eventually(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        await Task.yield()
    }
}
