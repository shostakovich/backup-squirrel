import Foundation

enum RunKind: String, CaseIterable, Hashable, Sendable {
    case backup
    case check
    case prune
}

enum RunStatus: String, Hashable, Sendable, Codable {
    case running
    case success
    /// The snapshot exists, but some files could not be read.
    case warning
    case failed
    case cancelled
}

/// Why a run could not do its job; a check that found damaged data has no failure but an error count.
enum RunFailure: Hashable, Sendable {
    case targetUnreachable
    case other(String)

    /// Counts as a failure, so the retry or catch-up is due right after the next launch.
    static let interrupted = RunFailure.other("Backup-Squirrel wurde beendet, während der Vorgang lief")
}

struct BackupStatistics: Hashable, Sendable, Codable {
    var filesNew = 0
    var filesChanged = 0
    var filesUnmodified = 0
    var bytesAdded: Int64 = 0
    var bytesProcessed: Int64 = 0
    var snapshotID: String?
    var unreadableFiles: [String] = []
    /// Removed by the retention that follows the backup; the weekly prune frees their space.
    var snapshotsForgotten = 0
}

struct CheckStatistics: Hashable, Sendable {
    /// About 10 GB per slice at 1.23 TiB, so a daily check holds the lock for minutes rather than hours.
    static let currentSubsetCount = 128

    /// 1-based index of the slice passed to `restic check --read-data-subset=n/m`.
    var subset: Int
    /// Stored per run, so older checks keep showing the slicing they ran with.
    var subsetCount = currentSubsetCount
    var errorCount = 0
}

struct PruneStatistics: Hashable, Sendable, Codable {
    var snapshotsRemoved = 0
    var bytesFreed: Int64 = 0
}

enum RunDetails: Hashable, Sendable {
    case backup(BackupStatistics)
    case check(CheckStatistics)
    case prune(PruneStatistics)

    var kind: RunKind {
        switch self {
        case .backup: .backup
        case .check: .check
        case .prune: .prune
        }
    }
}

enum PushFailure: Hashable, Sendable, Codable {
    case rejected(statusCode: Int)
    case unreachable
}

struct MonitorPush: Hashable, Sendable, Codable {
    var sentAt: Date
    var failure: PushFailure?
}

struct Run: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    /// Set for backups only; checks and prunes belong to a target.
    var planID: Plan.ID?
    var targetID: Target.ID
    var status: RunStatus
    var startedAt: Date
    var finishedAt: Date?
    var details: RunDetails
    var failure: RunFailure?
    var output: String
    var monitorPush: MonitorPush?

    init(
        id: UUID = UUID(),
        planID: Plan.ID? = nil,
        targetID: Target.ID,
        status: RunStatus,
        startedAt: Date,
        finishedAt: Date? = nil,
        details: RunDetails,
        failure: RunFailure? = nil,
        output: String = "",
        monitorPush: MonitorPush? = nil
    ) {
        self.id = id
        self.planID = planID
        self.targetID = targetID
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.details = details
        self.failure = failure
        self.output = output
        self.monitorPush = monitorPush
    }

    var kind: RunKind { details.kind }

    /// When the run ended; a backup counts as saved from then on.
    var endedAt: Date { finishedAt ?? startedAt }

    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    var producedSnapshot: Bool {
        kind == .backup && (status == .success || status == .warning)
    }

    var errorCount: Int {
        if case .check(let statistics) = details { statistics.errorCount } else { 0 }
    }

    /// Failed without doing its job, as opposed to a check that ran and found damaged data.
    var couldNotRun: Bool {
        status == .failed && errorCount == 0
    }

    /// A check that ran to the end, whatever it found.
    var completedCheck: Bool {
        kind == .check && (status == .success || (status == .failed && errorCount > 0))
    }
}

struct OperationProgress: Hashable, Sendable {
    var fractionCompleted: Double
    var filesDone: Int
    var filesTotal: Int
    var bytesDone: Int64
    var bytesTotal: Int64
    var secondsRemaining: TimeInterval?
}
