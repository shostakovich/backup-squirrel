import Foundation

struct BackupState: Sendable {
    var plans: [Plan]
    var targets: [Target]
    var runs: [Run]
    var progress: OperationProgress?
    var now: Date
    /// When the app launched or the Mac last woke up.
    var awakeSince: Date = .distantPast
    var system = SystemState()
    /// Waiting for the active run, such as the catch-up after launch or wake.
    var queued: [RunRequest] = []

    var activeRun: Run? { runs.last { $0.status == .running } }

    func plan(_ id: Plan.ID?) -> Plan? { plans.first { $0.id == id } }

    func target(_ id: Target.ID?) -> Target? { targets.first { $0.id == id } }
}

extension AppModel {
    var state: BackupState {
        BackupState(
            plans: plans, targets: targets, runs: runs, progress: progress, now: now, awakeSince: awakeSince,
            system: system, queued: queuedRequests)
    }
}

enum Severity: Int, Comparable, Hashable, Sendable {
    case warning = 1
    case error = 2

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum PlanHealth: Hashable, Sendable {
    case running
    case current
    case notYetBackedUp
    case warning
    case failed
    case overdue
    case manualOnly
    case incomplete(automatic: Bool)

    var severity: Severity? {
        switch self {
        case .failed, .overdue: .error
        case .warning: .warning
        case .incomplete(let automatic): automatic ? .warning : nil
        case .running, .current, .notYetBackedUp, .manualOnly: nil
        }
    }
}

enum PlanGap: Hashable, Sendable {
    case noTarget
    case noSourceFolders
}

enum PlanWarning: Hashable, Sendable {
    case monitorPushFailed(PushFailure)
    case unreadableFiles(Int)
}

enum NextRun: Hashable, Sendable {
    case at(Date)
    case retry(Date)
    /// Due now; it only waits for the runs ahead of it.
    case catchUp
    case whenVolumeConnected(String)
}

/// Why nothing new was saved: what the next attempt waits for, or what the last one ran into.
enum Standstill: Hashable, Sendable {
    case failing(Run)
    case volumeMissing(String)
    case cancelled(at: Date)
    case noAttempt(since: Date?)
}

struct PlanStatus: Hashable, Sendable {
    var health: PlanHealth
    /// The last backup that produced a snapshot, with or without warnings.
    var lastSnapshot: Run?
    /// The newest failed attempt, only when it is newer than the last snapshot.
    var failedAttempt: Run?
    /// Failed attempts since the last snapshot; cancelled ones neither count nor reset.
    var consecutiveFailures = 0
    var standstill: Standstill
    var nextRun: NextRun?
    var warning: PlanWarning?
    var gap: PlanGap?
    var lastReport: Date?
    var failedReport: PushFailure?
    var isQueued = false
}

enum TargetHealth: Hashable, Sendable {
    case running
    case current
    case notYetChecked
    case checkOverdue
    /// The check ran and found damaged data.
    case checkFoundErrors
    /// The check could not run, for example because the target was unreachable.
    case checkFailed
    case pruneFailed

    var severity: Severity? {
        switch self {
        case .checkFoundErrors, .checkFailed, .pruneFailed: .error
        case .checkOverdue: .warning
        case .running, .current, .notYetChecked: nil
        }
    }
}

struct TargetStatus: Hashable, Sendable {
    static let checkInterval: TimeInterval = 24 * 3600
    static let pruneInterval: TimeInterval = 7 * 24 * 3600

    var health: TargetHealth
    /// The last check that ran to the end, whatever it found.
    var lastCheck: Run?
    /// The newest check that could not run, only when it is newer than the last completed one.
    var failedCheck: Run?
    var checkFailures = 0
    var checkStandstill: Standstill
    var lastPrune: Run?
    var failedPrune: Run?
    var pruneFailures = 0
    var nextCheck: NextRun
    var nextPrune: NextRun
    var lastConnection: Date?
}

enum SetupGap: Hashable, Sendable {
    case noTarget
    case noPlan
    case nothingAutomatic
}

enum SystemProblem: Hashable, Sendable, CaseIterable {
    case noFullDiskAccess
    case notOpeningAtLogin
    case notificationsOff
}

struct Problem: Hashable, Sendable {
    enum Subject: Hashable, Sendable {
        case plan(Plan.ID)
        case target(Target.ID)
    }

    var subject: Subject
    var severity: Severity
}

enum MenuBarIconState: Hashable, Sendable {
    case idle
    case running(fraction: Double?)
    case warning
    case error
    case notSetUp
}

struct StatusEvaluator {
    /// A plan without a snapshot for longer than this many intervals counts as overdue; checks likewise.
    static let overdueIntervals: Double = 2
    static let catchUpGracePeriod: TimeInterval = 15 * 60
    /// Backups never retry more often than this once the short retries are used up.
    static let minimumBackupInterval: TimeInterval = 3600
    /// A cancelled check or prune waits this long, so cancelling does not start it again right away.
    static let pauseAfterCancel: TimeInterval = 3600

    /// 15 minutes, 30 minutes, 1 hour; after that the regular interval applies.
    static func retryDelay(afterFailures count: Int) -> TimeInterval? {
        switch count {
        case 1: 15 * 60
        case 2: 30 * 60
        case 3: 60 * 60
        default: nil
        }
    }

    let calendar: Calendar
    var home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    // MARK: Plans

    func status(of plan: Plan, in state: BackupState) -> PlanStatus {
        let backups = state.runs.filter { $0.planID == plan.id }.sorted { $0.startedAt < $1.startedAt }
        let finished = backups.filter { $0.status != .running }
        let lastSnapshot = finished.last { $0.producedSnapshot }
        let sinceSnapshot = finished.filter { $0.startedAt > (lastSnapshot?.startedAt ?? .distantPast) }
        let failures = sinceSnapshot.filter { $0.status == .failed }
        let isRunning = backups.contains { $0.status == .running }
        let isQueued = state.queued.contains(.backup(plan.id))
        let missingVolume = state.system.missingVolume(for: plan.sourceFolders)
        let pushes = backups.compactMap(\.monitorPush).sorted { $0.sentAt < $1.sentAt }

        var gap: PlanGap?
        if state.target(plan.targetID) == nil {
            gap = .noTarget
        } else if plan.sourceFolders.isEmpty {
            gap = .noSourceFolders
        }
        let isScheduled = plan.backsUpAutomatically && gap == nil

        let failedReport = plan.reportsToUptimeKuma ? pushes.last?.failure : nil
        var warning: PlanWarning?
        if let failedReport {
            warning = .monitorPushFailed(failedReport)
        } else if let lastSnapshot, lastSnapshot.status == .warning {
            warning = .unreadableFiles(Self.unreadableFileCount(of: lastSnapshot))
        }

        let health: PlanHealth
        if isRunning {
            health = .running
        } else if gap != nil {
            health = .incomplete(automatic: plan.backsUpAutomatically)
        } else if isScheduled, !isQueued,
            isOverdue(since: lastSnapshot?.endedAt ?? plan.createdAt, plan.schedule.nominalInterval, state)
        {
            health = .overdue
        } else if !failures.isEmpty {
            health = .failed
        } else if warning != nil {
            health = .warning
        } else if !plan.backsUpAutomatically {
            health = .manualOnly
        } else if lastSnapshot == nil {
            health = .notYetBackedUp
        } else {
            health = .current
        }

        let standstill: Standstill
        if let missingVolume {
            standstill = .volumeMissing(missingVolume)
        } else if let failed = failures.last {
            standstill = .failing(failed)
        } else if let cancelled = sinceSnapshot.last, cancelled.status == .cancelled {
            standstill = .cancelled(at: cancelled.startedAt)
        } else {
            standstill = .noAttempt(since: finished.last?.startedAt)
        }

        var nextRun: NextRun?
        if isScheduled, !isRunning {
            if let missingVolume {
                nextRun = .whenVolumeConnected(missingVolume)
            } else if isQueued {
                nextRun = .catchUp
            } else if let failed = failures.last, failed.id == finished.last?.id {
                let end = failed.endedAt
                let regular = max(
                    plan.schedule.nextRun(after: failed.startedAt, now: end, calendar: calendar),
                    end.addingTimeInterval(Self.minimumBackupInterval))
                let due = Self.retryDelay(afterFailures: failures.count).map { end.addingTimeInterval($0) } ?? regular
                nextRun = due > state.now ? .retry(due) : .catchUp
            } else {
                let due = plan.schedule.nextRun(after: finished.last?.startedAt, now: state.now, calendar: calendar)
                nextRun = due > state.now ? .at(due) : .catchUp
            }
        }

        return PlanStatus(
            health: health,
            lastSnapshot: lastSnapshot,
            failedAttempt: failures.last,
            consecutiveFailures: failures.count,
            standstill: standstill,
            nextRun: nextRun,
            warning: warning,
            gap: gap,
            lastReport: pushes.last { $0.failure == nil }?.sentAt,
            failedReport: failedReport,
            isQueued: isQueued
        )
    }

    // MARK: Targets

    func status(of target: Target, in state: BackupState) -> TargetStatus {
        let runs = state.runs.filter { $0.targetID == target.id }.sorted { $0.startedAt < $1.startedAt }
        let checks = runs.filter { $0.kind == .check && $0.status != .running }
        let prunes = runs.filter { $0.kind == .prune && $0.status != .running }
        let isRunning = runs.contains { $0.kind != .backup && $0.status == .running }

        let lastCheck = checks.last(where: \.completedCheck)
        let checkFailures = checks.filter {
            $0.couldNotRun && $0.startedAt > (lastCheck?.startedAt ?? .distantPast)
        }
        let lastPrune = prunes.last { $0.status == .success }
        let pruneFailures = prunes.filter {
            $0.status == .failed && $0.startedAt > (lastPrune?.startedAt ?? .distantPast)
        }
        let checkQueued = state.queued.contains(.check(target.id))

        let health: TargetHealth
        if isRunning {
            health = .running
        } else if let lastCheck, lastCheck.errorCount > 0 {
            health = .checkFoundErrors
        } else if !checkFailures.isEmpty {
            health = .checkFailed
        } else if !pruneFailures.isEmpty {
            health = .pruneFailed
        } else if !checkQueued,
            isOverdue(since: lastCheck?.startedAt ?? target.createdAt, TargetStatus.checkInterval, state)
        {
            health = .checkOverdue
        } else if lastCheck == nil {
            health = .notYetChecked
        } else {
            health = .current
        }

        let checkStandstill: Standstill
        if let failed = checkFailures.last {
            checkStandstill = .failing(failed)
        } else if let attempt = checks.last, attempt.status == .cancelled,
            attempt.startedAt > (lastCheck?.startedAt ?? .distantPast)
        {
            checkStandstill = .cancelled(at: attempt.startedAt)
        } else {
            checkStandstill = .noAttempt(since: lastCheck?.startedAt ?? target.createdAt)
        }

        let reached = runs.filter { $0.status == .success || $0.status == .warning || $0.completedCheck }
            .compactMap(\.finishedAt)
        return TargetStatus(
            health: health,
            lastCheck: lastCheck,
            failedCheck: checkFailures.last,
            checkFailures: checkFailures.count,
            checkStandstill: checkStandstill,
            lastPrune: lastPrune,
            failedPrune: pruneFailures.last,
            pruneFailures: pruneFailures.count,
            nextCheck: checkQueued
                ? .catchUp
                : nextMaintenance(
                    after: lastCheck?.startedAt ?? target.createdAt, every: TargetStatus.checkInterval,
                    attempts: checks, failures: checkFailures, state),
            nextPrune: nextMaintenance(
                after: lastPrune?.startedAt ?? target.createdAt, every: TargetStatus.pruneInterval,
                attempts: prunes, failures: pruneFailures, state),
            lastConnection: (reached + [target.connectedAt].compactMap { $0 }).max()
        )
    }

    // MARK: Overall

    /// Nil once at least one plan backs up a folder to a target on its own.
    func setupGap(in state: BackupState) -> SetupGap? {
        if state.targets.isEmpty { return .noTarget }
        if state.plans.isEmpty { return .noPlan }
        let protects = state.plans.contains { plan in
            plan.backsUpAutomatically && state.target(plan.targetID) != nil && !plan.sourceFolders.isEmpty
        }
        return protects ? nil : .nothingAutomatic
    }

    /// Most severe first; plans before targets, each in sidebar order.
    func problems(in state: BackupState) -> [Problem] {
        let plans = state.plans.compactMap { plan -> Problem? in
            status(of: plan, in: state).health.severity.map { Problem(subject: .plan(plan.id), severity: $0) }
        }
        let targets = state.targets.compactMap { target -> Problem? in
            status(of: target, in: state).health.severity.map { Problem(subject: .target(target.id), severity: $0) }
        }
        let all = plans + targets
        return all.filter { $0.severity == .error } + all.filter { $0.severity == .warning }
    }

    func systemProblems(in state: BackupState) -> [SystemProblem] {
        let automatic = state.plans.contains(where: \.backsUpAutomatically)
        return SystemProblem.allCases.filter { problem in
            switch problem {
            case .noFullDiskAccess: !state.system.hasFullDiskAccess && state.plans.contains(where: needsFullDiskAccess)
            case .notOpeningAtLogin: !state.system.opensAtLogin && automatic
            case .notificationsOff: state.system.notifications != .allowed && automatic
            }
        }
    }

    /// Unattended runs cannot answer privacy prompts for Documents, Desktop, iCloud Drive or removable volumes.
    func needsFullDiskAccess(_ plan: Plan) -> Bool {
        let home = home.standardizedFileURL.path
        return plan.sourceFolders.contains { folder in
            let path = folder.standardizedFileURL.path
            return Self.contains(path, home) || Self.contains(home, path) || Self.contains("/Volumes", path)
        }
    }

    func iconState(for state: BackupState) -> MenuBarIconState {
        if state.activeRun != nil { return .running(fraction: state.progress?.fractionCompleted) }
        if setupGap(in: state) != nil { return .notSetUp }
        let worst = problems(in: state).map(\.severity).max()
        if worst == .error { return .error }
        if worst == .warning || !systemProblems(in: state).isEmpty { return .warning }
        return .idle
    }

    /// Lasts until the catch-up queue has drained, and at least 15 minutes.
    func isInGracePeriod(_ state: BackupState) -> Bool {
        state.now < state.awakeSince.addingTimeInterval(Self.catchUpGracePeriod) || !state.queued.isEmpty
    }

    static func unreadableFileCount(of run: Run) -> Int {
        guard case .backup(let statistics) = run.details else { return 0 }
        return statistics.unreadableFiles.count
    }

    private static func contains(_ folder: String, _ path: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    private func isOverdue(since reference: Date, _ interval: TimeInterval, _ state: BackupState) -> Bool {
        !isInGracePeriod(state) && state.now.timeIntervalSince(reference) > Self.overdueIntervals * interval
    }

    private func nextMaintenance(
        after last: Date, every interval: TimeInterval, attempts: [Run], failures: [Run], _ state: BackupState
    ) -> NextRun {
        let newest = attempts.last
        if let failed = failures.last, failed.id == newest?.id {
            let delay = Self.retryDelay(afterFailures: failures.count) ?? interval
            let due = failed.endedAt.addingTimeInterval(delay)
            return due > state.now ? .retry(due) : .catchUp
        }
        let due = last.addingTimeInterval(interval)
        if let newest, newest.status == .cancelled, newest.startedAt > last {
            let resume = newest.endedAt.addingTimeInterval(Self.pauseAfterCancel)
            if resume > due { return resume > state.now ? .retry(resume) : .catchUp }
        }
        return due > state.now ? .at(due) : .catchUp
    }
}
