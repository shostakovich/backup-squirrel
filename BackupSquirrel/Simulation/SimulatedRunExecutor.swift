import Foundation

@MainActor
final class SimulatedRunExecutor: RunExecutor {
    private struct Profile {
        var filesTotal: Int
        var bytesTotal: Int64
        var filesPerSecond: Double
    }

    /// Used once, for the next job, to pick up a run that is already under way.
    var resumeProgress: OperationProgress?
    private let tick: Duration

    init(tick: Duration = .milliseconds(500)) {
        self.tick = tick
    }

    func execute(_ job: RunJob) -> RunExecution {
        let profile = Self.profile(for: job)
        let start = resumeProgress ?? Self.progress(filesDone: 0, profile: profile)
        resumeProgress = nil
        let tickSeconds = Double(tick.components.seconds) + Double(tick.components.attoseconds) / 1e18
        let tick = self.tick
        let (events, continuation) = AsyncStream<RunEvent>.makeStream()
        let task = Task { @MainActor in
            var progress = start
            let startedAt = Date()
            continuation.yield(.progress(progress))
            while progress.filesDone < progress.filesTotal {
                do {
                    try await Task.sleep(for: tick)
                } catch {
                    break
                }
                let filesDone = min(
                    progress.filesTotal, progress.filesDone + Int(profile.filesPerSecond * tickSeconds))
                progress = Self.progress(filesDone: filesDone, profile: profile)
                continuation.yield(.progress(progress))
            }
            if !Task.isCancelled {
                continuation.yield(.finished(Self.outcome(for: job, duration: Date().timeIntervalSince(startedAt))))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return RunExecution(events: events, stop: { task.cancel() })
    }

    func report(_ run: Run, of plan: Plan) async -> PushFailure? {
        try? await Task.sleep(for: .milliseconds(600))
        return nil
    }

    private static func profile(for job: RunJob) -> Profile {
        switch job {
        case .backup: Profile(filesTotal: 28_901, bytesTotal: 41_215_000_000, filesPerSecond: 15.3)
        case .check: Profile(filesTotal: 412, bytesTotal: 0, filesPerSecond: 2)
        case .prune: Profile(filesTotal: 121, bytesTotal: 0, filesPerSecond: 2)
        }
    }

    private static func progress(filesDone: Int, profile: Profile) -> OperationProgress {
        let fraction = Double(filesDone) / Double(profile.filesTotal)
        let isFileBased = profile.bytesTotal > 0
        return OperationProgress(
            fractionCompleted: fraction,
            filesDone: isFileBased ? filesDone : 0,
            filesTotal: isFileBased ? profile.filesTotal : 0,
            bytesDone: Int64(Double(profile.bytesTotal) * fraction),
            bytesTotal: profile.bytesTotal,
            secondsRemaining: Double(profile.filesTotal - filesDone) / profile.filesPerSecond
        )
    }

    private static func outcome(for job: RunJob, duration: TimeInterval) -> RunOutcome {
        switch job {
        case .backup(let plan, _):
            let statistics = BackupStatistics(
                filesNew: 214, filesChanged: 87, filesUnmodified: 28_600, bytesAdded: 312_427_000,
                bytesProcessed: 41_215_000_000, snapshotID: "9b31d2c7")
            return RunOutcome(
                status: .success, details: .backup(statistics),
                output: SampleOutput.backup(
                    sources: plan.sourceFolders, statistics: statistics, duration: duration, parentSnapshot: "4f2a9c1e"),
                monitorPush: plan.reportsToUptimeKuma ? MonitorPush(sentAt: Date()) : nil
            )
        case .check(_, let subset):
            let statistics = CheckStatistics(subset: subset)
            return RunOutcome(
                status: .success, details: .check(statistics),
                output: SampleOutput.check(statistics, packs: 412, duration: duration))
        case .prune:
            let statistics = PruneStatistics(snapshotsRemoved: 3, bytesFreed: 412_000_000)
            return RunOutcome(status: .success, details: .prune(statistics), output: SampleOutput.prune(statistics))
        }
    }
}
