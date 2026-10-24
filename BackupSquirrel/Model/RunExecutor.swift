import Foundation

enum RunRequest: Hashable, Sendable {
    case backup(Plan.ID)
    case check(Target.ID)
    case prune(Target.ID)
}

enum RunJob: Hashable, Sendable {
    case backup(Plan, Target)
    case check(Target, subset: Int, subsetCount: Int)
    case prune(Target)

    var target: Target {
        switch self {
        case .backup(_, let target), .check(let target, _, _), .prune(let target): target
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

/// `stop` ends the job early; its events still run to the end, so the run is recorded only once restic is gone.
struct RunExecution {
    var events: AsyncStream<RunEvent>
    var stop: @MainActor () -> Void
}

@MainActor
protocol RunExecutor: AnyObject {
    func execute(_ job: RunJob) -> RunExecution
    func report(_ run: Run, of plan: Plan) async -> PushFailure?
}
