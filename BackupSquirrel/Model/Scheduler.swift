import Foundation

struct Scheduler {
    let calendar: Calendar

    func dueRequests(in state: BackupState) -> [RunRequest] {
        let evaluator = StatusEvaluator(calendar: calendar)
        let backups = state.plans.filter { evaluator.status(of: $0, in: state).nextRun == .catchUp }
            .map { RunRequest.backup($0.id) }
        let maintenance = state.targets.flatMap { target -> [RunRequest] in
            let status = evaluator.status(of: target, in: state)
            return [
                status.nextCheck == .catchUp ? RunRequest.check(target.id) : nil,
                status.nextPrune == .catchUp ? RunRequest.prune(target.id) : nil,
            ].compactMap { $0 }
        }
        let active = state.runs.filter { $0.status == .running }.compactMap(\.request)
        return (backups + maintenance).filter { !state.queued.contains($0) && !active.contains($0) }
    }
}

extension Run {
    var request: RunRequest? {
        switch kind {
        case .backup: planID.map(RunRequest.backup)
        case .check: .check(targetID)
        case .prune: .prune(targetID)
        }
    }
}
