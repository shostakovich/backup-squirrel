import Foundation

enum RunRequest: Hashable, Sendable {
    case backup(Plan.ID)
    case check(Target.ID)
    case prune(Target.ID)
}

enum RunJob: Hashable, Sendable {
    case backup(Plan, Target)
    case check(Target, subset: Int)
    case prune(Target)

    var target: Target {
        switch self {
        case .backup(_, let target), .check(let target, _), .prune(let target): target
        }
    }
}

struct RunOutcome: Hashable, Sendable {
    var status: RunStatus
    var details: RunDetails
    var failure: RunFailure?
    var output: String
    var monitorPush: MonitorPush?
}

enum RunEvent: Hashable, Sendable {
    case progress(OperationProgress)
    case finished(RunOutcome)
}

/// Performs one job; cancelling the consumer of the stream cancels the job.
@MainActor
protocol RunExecutor: AnyObject {
    func execute(_ job: RunJob) -> AsyncStream<RunEvent>

    /// Sends the Uptime Kuma push for a plan's last snapshot again.
    func report(to pushURL: String) async -> PushFailure?
}
