import Foundation
import Testing

@testable import BackupSquirrel

struct SchedulerTests {
    private let scheduler = Scheduler(calendar: Fixture.calendar)
    private let threeAM = TimeOfDay(hour: 3, minute: 0)

    private var data: Plan { Fixture.plan(id: Fixture.dataID, name: "Daten", schedule: .daily(at: threeAM)) }

    @Test func nothingIsDueRightAfterEverythingRan() {
        let runs = [Fixture.backup(at: Fixture.date(2026, 10, 14, 13, 2))] + Fixture.maintenance()
        #expect(scheduler.dueRequests(in: Fixture.state(runs: runs)).isEmpty)
    }

    @Test func backupsComeBeforeTheChecksAndPrunesThatAreDue() {
        let runs = [
            Fixture.backup(at: Fixture.date(2026, 10, 14, 11, 2)),
            Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 13, 3, 0)),
            Fixture.check(at: Fixture.date(2026, 10, 5, 4, 0)),
            Fixture.prune(at: Fixture.date(2026, 10, 4, 5, 0)),
        ]
        let state = Fixture.state(plans: [Fixture.plan(), data], runs: runs)
        #expect(
            scheduler.dueRequests(in: state) == [
                .backup(Fixture.homeID), .backup(Fixture.dataID), .check(Fixture.targetID), .prune(Fixture.targetID),
            ])
    }

    @Test func manualPlansAndPlansWithoutTheirVolumeAreNotScheduled() {
        let manual = Fixture.plan(automatic: false)
        let external = Fixture.plan(
            id: Fixture.dataID, sourceFolders: [URL(fileURLWithPath: "/Volumes/Daten", isDirectory: true)])
        let state = Fixture.state(
            plans: [manual, external], runs: Fixture.maintenance(), system: SystemState(mountedVolumes: ["/"]))
        #expect(scheduler.dueRequests(in: state).isEmpty)
    }

    @Test func whatIsQueuedOrRunningIsNotRequestedAgain() {
        let runs = [
            Fixture.check(at: Fixture.date(2026, 10, 5, 4, 0)),
            Fixture.check(status: .running, at: Fixture.date(2026, 10, 14, 13, 0)),
            Fixture.prune(at: Fixture.date(2026, 10, 4, 5, 0)),
        ]
        let state = Fixture.state(runs: runs, queued: [.backup(Fixture.homeID)])
        #expect(scheduler.dueRequests(in: state) == [.prune(Fixture.targetID)])
    }

    @Test func aCancelledCheckWaitsAnHourInsteadOfStartingAgain() {
        let runs = [
            Fixture.backup(at: Fixture.date(2026, 10, 14, 13, 2)),
            Fixture.check(at: Fixture.date(2026, 10, 5, 4, 0)),
            Fixture.check(status: .cancelled, at: Fixture.date(2026, 10, 14, 13, 10)),
            Fixture.prune(at: Fixture.date(2026, 10, 11, 5, 0)),
        ]
        let state = Fixture.state(runs: runs)
        #expect(scheduler.dueRequests(in: state).isEmpty)
        let resume = Fixture.date(2026, 10, 14, 13, 10).addingTimeInterval(226 + 3600)
        let status = StatusEvaluator(calendar: Fixture.calendar).status(of: Fixture.target(), in: state)
        #expect(status.nextCheck == .retry(resume))
        var later = state
        later.now = resume
        #expect(scheduler.dueRequests(in: later) == [.backup(Fixture.homeID), .check(Fixture.targetID)])
    }

    @Test func aCancelledRetryIsNotStartedAgainRightAway() {
        let runs =
            [
                Fixture.backup(at: Fixture.date(2026, 10, 14, 12, 2)),
                Fixture.backup(status: .failed, at: Fixture.date(2026, 10, 14, 13, 2)),
                Fixture.backup(status: .cancelled, at: Fixture.date(2026, 10, 14, 13, 17)),
            ] + Fixture.maintenance()
        let state = Fixture.state(runs: runs)
        #expect(scheduler.dueRequests(in: state).isEmpty)
        let status = StatusEvaluator(calendar: Fixture.calendar).status(of: Fixture.plan(), in: state)
        #expect(status.nextRun == .at(Fixture.date(2026, 10, 14, 14, 17)))
    }
}

@MainActor
struct SchedulingModelTests {
    private let executor = MockRunExecutor()

    private func model(runs: [Run]) -> AppModel {
        AppModel(
            targets: [Fixture.target()], plans: [Fixture.plan()], runs: runs, passwords: InMemoryPasswordStore(),
            connection: MockConnection(), keys: MockKeys(), calendar: Fixture.calendar, currentDate: { Fixture.now },
            executor: executor)
    }

    @Test func onlyAModelThatSchedulesStartsDueRuns() {
        let model = model(runs: Fixture.maintenance())
        model.tick()
        model.noteWake()
        #expect(executor.jobs.isEmpty)
        model.startScheduling()
        #expect(executor.jobs == [.backup(Fixture.plan(), Fixture.target())])
    }

    @Test func dueRunsWaitInTheQueueOneAtATime() {
        let model = model(runs: [
            Fixture.check(at: Fixture.date(2026, 10, 5, 4, 0)), Fixture.prune(at: Fixture.date(2026, 10, 4, 5, 0)),
        ])
        model.startScheduling()
        model.tick()
        #expect(executor.jobs.count == 1)
        #expect(model.queuedRequests == [.check(Fixture.targetID), .prune(Fixture.targetID)])
    }
}
