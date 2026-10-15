import Foundation
import Testing

@testable import BackupSquirrel

@MainActor
struct AppModelTests {
    private let executor = MockRunExecutor()

    private func makeModel(
        plans: [Plan] = [Fixture.plan()], runs: [Run] = [], system: SystemState = SystemState()
    ) -> AppModel {
        AppModel(
            targets: [Fixture.target()], plans: plans, runs: runs,
            repositoryPasswords: [Fixture.targetID: "geheim"], calendar: Fixture.calendar,
            currentDate: { Fixture.now }, inspectSystem: { system }, executor: executor)
    }

    private static let success = RunOutcome(
        status: .success, details: .backup(BackupStatistics(filesNew: 3)), output: "snapshot 1234abcd saved")

    @Test func startingABackupRecordsARunningRunAndHandsTheJobToTheExecutor() {
        let model = makeModel()
        #expect(model.start(.backup(Fixture.homeID)))
        #expect(model.activeRun?.planID == Fixture.homeID)
        #expect(model.activeRun?.startedAt == Fixture.now)
        #expect(executor.jobs == [.backup(Fixture.plan(), Fixture.target())])
        #expect(model.isBusy)
    }

    @Test func progressEventsReachTheModel() async {
        let model = makeModel()
        model.start(.backup(Fixture.homeID))
        executor.send(.progress(Fixture.progress()))
        await eventually { model.progress != nil }
        #expect(model.progress == Fixture.progress())
    }

    @Test func finishingRecordsTheOutcome() async {
        let model = makeModel()
        model.start(.backup(Fixture.homeID))
        executor.finish(with: Self.success)
        await eventually { !model.isBusy }
        let run = model.runs.last
        #expect(run?.status == .success)
        #expect(run?.details == .backup(BackupStatistics(filesNew: 3)))
        #expect(run?.output == "snapshot 1234abcd saved")
        #expect(run?.finishedAt == Fixture.now)
        #expect(model.progress == nil)
    }

    @Test func cancellingMarksTheRunCancelled() async {
        let model = makeModel()
        model.start(.backup(Fixture.homeID))
        model.cancelActiveRun()
        await eventually { !model.isBusy }
        #expect(model.runs.last?.status == .cancelled)
        #expect(model.runs.last?.finishedAt != nil)
    }

    @Test func onlyOneRunAtATime() {
        let model = makeModel()
        #expect(model.start(.backup(Fixture.homeID)))
        #expect(!model.start(.check(Fixture.targetID)))
        #expect(executor.jobs.count == 1)
    }

    @Test func manualPlansCanBeBackedUpOnDemand() {
        let model = makeModel(plans: [Fixture.plan(automatic: false)])
        #expect(model.canBackUp(Fixture.plan(automatic: false)))
        #expect(model.start(.backup(Fixture.homeID)))
    }

    @Test func plansWithoutTargetOrFoldersDoNotStart() {
        let model = makeModel(plans: [Fixture.plan(sourceFolders: [])])
        #expect(!model.canBackUp(Fixture.plan(sourceFolders: [])))
        #expect(!model.start(.backup(Fixture.homeID)))
        #expect(model.runs.isEmpty)
    }

    @Test func theUptimeKumaPushIsRecordedWithTheRun() async {
        let model = makeModel()
        model.start(.backup(Fixture.homeID))
        var outcome = Self.success
        outcome.monitorPush = MonitorPush(sentAt: Fixture.now, failure: .rejected(statusCode: 404))
        executor.finish(with: outcome)
        await eventually { !model.isBusy }
        #expect(model.runs.last?.monitorPush == MonitorPush(sentAt: Fixture.now, failure: .rejected(statusCode: 404)))
    }

    @Test func backingUpAllPlansRunsThemOneAfterAnother() async {
        let data = Fixture.plan(id: Fixture.dataID, name: "Daten")
        let model = makeModel(plans: [Fixture.plan(), data])
        model.backUpAllPlans()
        #expect(executor.jobs.count == 1)
        executor.finish(with: Self.success)
        await eventually { executor.jobs.count == 2 }
        #expect(executor.jobs.last == .backup(data, Fixture.target()))
        #expect(model.activeRun?.planID == Fixture.dataID)
    }

    @Test func checksRotateThroughTheTwelveSubsets() {
        let model = makeModel(runs: [Fixture.check(at: Fixture.date(2026, 10, 12, 4, 0), subset: 12)])
        model.start(.check(Fixture.targetID))
        #expect(executor.jobs == [.check(Fixture.target(), subset: 1)])

        let next = makeModel(runs: [Fixture.check(at: Fixture.date(2026, 10, 12, 4, 0), subset: 7)])
        next.start(.check(Fixture.targetID))
        #expect(executor.jobs.last == .check(Fixture.target(), subset: 8))
    }

    @Test func aCheckThatCouldNotRunDoesNotUseUpItsSubset() {
        let runs = [
            Fixture.check(at: Fixture.date(2026, 10, 5, 4, 0), subset: 6),
            Fixture.check(status: .failed, at: Fixture.date(2026, 10, 12, 4, 0), subset: 7),
        ]
        makeModel(runs: runs).start(.check(Fixture.targetID))
        #expect(executor.jobs == [.check(Fixture.target(), subset: 7)])
    }

    @Test func aRequestWhileBusyWaitsInTheQueueOnce() async {
        let model = makeModel()
        model.start(.backup(Fixture.homeID))
        model.request(.check(Fixture.targetID))
        model.request(.check(Fixture.targetID))
        #expect(model.queuedRequests == [.check(Fixture.targetID)])
        #expect(model.state.queued == [.check(Fixture.targetID)])
        executor.finish(with: Self.success)
        await eventually { executor.jobs.count == 2 }
        #expect(executor.jobs.last == .check(Fixture.target(), subset: 1))
        #expect(model.queuedRequests.isEmpty)
    }

    @Test func aPlanOnADisconnectedVolumeCannotStart() {
        let external = Fixture.plan(sourceFolders: [URL(fileURLWithPath: "/Volumes/Daten", isDirectory: true)])
        let model = makeModel(plans: [external], system: SystemState(mountedVolumes: ["/"]))
        #expect(!model.canBackUp(external))
        #expect(!model.canStart(.backup(Fixture.homeID)))
        #expect(!model.start(.backup(Fixture.homeID)))
    }

    @Test func reportingAgainRecordsTheNewAnswerOnTheLastSnapshot() async {
        let plan = Fixture.plan(uptimeKumaPushURL: "https://uptime.example.com/api/push/abc")
        let rejected = Fixture.backup(
            at: Fixture.date(2026, 10, 14, 13, 2),
            monitorPush: MonitorPush(sentAt: Fixture.date(2026, 10, 14, 13, 5), failure: .rejected(statusCode: 404)))
        let model = makeModel(plans: [plan], runs: [rejected])
        await model.resendReport(for: Fixture.homeID)
        #expect(executor.reports == ["https://uptime.example.com/api/push/abc"])
        #expect(model.runs.last?.monitorPush == MonitorPush(sentAt: Fixture.now))
        #expect(model.reportingPlans.isEmpty)
    }

    @Test func aSuccessfulConnectionTestIsRemembered() {
        let model = makeModel()
        model.markConnected(Fixture.targetID)
        #expect(model.target(Fixture.targetID)?.connectedAt == Fixture.now)
        #expect(model.target(Fixture.targetID)?.sshKey.isInstalled == true)
    }

    @Test func theFirstPlanOfTheSetUpGetsItsFoldersAndSchedule() {
        let model = makeModel(plans: [])
        let folders = [URL(fileURLWithPath: "/Volumes/Daten", isDirectory: true)]
        let id = model.addPlan(
            name: " Daten ", targetID: Fixture.targetID, sourceFolders: folders,
            schedule: .daily(at: TimeOfDay(hour: 3, minute: 0)), automatic: true)
        let plan = model.plan(id)
        #expect(plan?.name == "Daten")
        #expect(plan?.sourceFolders == folders)
        #expect(plan?.schedule == .daily(at: TimeOfDay(hour: 3, minute: 0)))
        #expect(plan?.createdAt == Fixture.now)
    }

    @Test func deletingATargetDetachesItsPlansAndForgetsThePassword() {
        let model = makeModel()
        model.deleteTarget(Fixture.targetID)
        #expect(model.targets.isEmpty)
        #expect(model.plans.first?.targetID == nil)
        #expect(model.repositoryPassword(for: Fixture.targetID) == nil)
    }

    @Test func aNewTargetComesWithAKeyAndIsAddedWithItsPassword() {
        let model = makeModel()
        let draft = model.makeTargetDraft()
        #expect(draft.name == "Storage Box 2")
        #expect(draft.sshKey.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(!draft.sshKey.isInstalled)
        #expect(draft.createdAt == Fixture.now)
        model.addTarget(draft, password: "geheim-2")
        model.markConnected(draft.id)
        #expect(model.target(draft.id)?.sshKey.isInstalled == true)
        #expect(model.repositoryPassword(for: draft.id) == "geheim-2")
    }

    @Test func unreadableFilesCanBeExcludedFromThePlan() {
        let model = makeModel()
        let file = URL(fileURLWithPath: "/Users/example/Library/Mail/Envelope Index-wal")
        model.exclude(file, fromPlan: Fixture.homeID)
        model.exclude(file, fromPlan: Fixture.homeID)
        #expect(model.plan(Fixture.homeID)?.exclusions == [.path(file)])
    }

    @Test func newPlansGetUniqueNamesAndTheFirstTarget() {
        let model = makeModel(plans: [])
        let first = model.addPlan()
        let second = model.addPlan()
        #expect(model.plan(first)?.name == "Neuer Plan")
        #expect(model.plan(second)?.name == "Neuer Plan 2")
        #expect(model.plan(first)?.targetID == Fixture.targetID)
    }

    @Test func clockRefreshUsesTheInjectedClock() {
        var current = Fixture.now
        let model = AppModel(calendar: Fixture.calendar, currentDate: { current }, executor: executor)
        current = Fixture.now.addingTimeInterval(60)
        model.refreshNow()
        #expect(model.now == Fixture.now.addingTimeInterval(60))
    }

    @Test func wakingUpRestartsTheGracePeriodAndAsksTheSystemAgain() {
        var current = Fixture.now
        var system = SystemState()
        let model = AppModel(
            calendar: Fixture.calendar, currentDate: { current }, awakeSince: Fixture.date(2026, 10, 14, 8, 0),
            inspectSystem: { system }, executor: executor)
        #expect(model.awakeSince == Fixture.date(2026, 10, 14, 8, 0))
        current = Fixture.now.addingTimeInterval(600)
        system.hasFullDiskAccess = false
        model.noteWake()
        #expect(model.awakeSince == Fixture.now.addingTimeInterval(600))
        #expect(model.system.hasFullDiskAccess == false)
    }
}
