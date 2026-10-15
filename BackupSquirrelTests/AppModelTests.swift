import Foundation
import Security
import Testing

@testable import BackupSquirrel

@MainActor
struct AppModelTests {
    private let executor = MockRunExecutor()
    private let passwords = FlakyPasswordStore([Fixture.targetID: "geheim"])
    private let connection = MockConnection()
    private let keys = MockKeys()

    private func makeModel(
        plans: [Plan] = [Fixture.plan()], runs: [Run] = [], system: SystemState = SystemState()
    ) -> AppModel {
        AppModel(
            targets: [Fixture.target()], plans: plans, runs: runs, passwords: passwords, connection: connection,
            keys: keys, calendar: Fixture.calendar, currentDate: { Fixture.now }, inspectSystem: { system },
            executor: executor)
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

    @Test func aCancelledRunStaysBusyUntilResticHasExitedAndKeepsItsOutput() async {
        let model = makeModel(plans: [Fixture.plan(), Fixture.plan(id: Fixture.dataID, name: "Daten")])
        executor.endsWhenStopped = false
        model.backUpAllPlans()
        model.cancelActiveRun()
        #expect(executor.stops == 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(model.isBusy)
        executor.finish(
            with: RunOutcome(status: .cancelled, details: .backup(BackupStatistics()), output: "interrupted"))
        await eventually { !model.isBusy }
        #expect(model.runs.last?.status == .cancelled)
        #expect(model.runs.last?.output == "interrupted")
        #expect(executor.jobs.count == 1, "the queue was cleared")
    }

    @Test func quittingStopsTheRunAndRecordsItAsInterrupted() async {
        let model = makeModel()
        executor.endsWhenStopped = false
        model.start(.backup(Fixture.homeID))
        let shutDown = Task { await model.shutDown(waitingAtMost: .seconds(5)) }
        await eventually { executor.stops == 1 }
        executor.finish(with: RunOutcome(status: .cancelled, details: .backup(BackupStatistics()), output: "bye"))
        await shutDown.value
        #expect(model.runs.last?.status == .failed)
        #expect(model.runs.last?.failure == .interrupted)
        #expect(model.runs.last?.output == "bye")
        #expect(!model.start(.backup(Fixture.homeID)), "no run starts while quitting")
    }

    @Test func quittingWaitsOnlySoLongForTheRun() async {
        let model = makeModel()
        executor.endsWhenStopped = false
        model.start(.backup(Fixture.homeID))
        await model.shutDown(waitingAtMost: .milliseconds(100))
        #expect(!model.isBusy)
        #expect(model.runs.last?.failure == .interrupted)
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

    @Test func deletingATargetDetachesItsPlansAndRemovesItsPasswordAndKey() {
        let model = makeModel()
        #expect(model.hasRepositoryPassword(for: Fixture.targetID))
        model.deleteTarget(Fixture.targetID)
        #expect(model.targets.isEmpty)
        #expect(model.plans.first?.targetID == nil)
        #expect(model.repositoryPassword(for: Fixture.targetID) == nil)
        #expect(!model.hasRepositoryPassword(for: Fixture.targetID))
        #expect(passwords.password(for: Fixture.targetID) == nil)
        #expect(keys.removedKeys == [Fixture.targetID])
    }

    @Test func aNewTargetGetsItsOwnKeyAndIsAddedWithItsPassword() async throws {
        let model = makeModel()
        let setup = model.makeTargetSetup()
        let draft = setup.target
        #expect(draft.name == "Storage Box 2")
        #expect(draft.createdAt == Fixture.now)
        #expect(!setup.isOnboarding)
        await eventually { setup.keyState == .ready }
        #expect(keys.generatedKeys == [draft.id])
        #expect(setup.target.sshKey.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(!setup.target.sshKey.isInstalled)
        try model.addTarget(setup.target, password: "geheim-2")
        model.markConnected(draft.id)
        #expect(model.target(draft.id)?.sshKey.isInstalled == true)
        #expect(model.repositoryPassword(for: draft.id) == "geheim-2")
        #expect(model.hasRepositoryPassword(for: draft.id))
    }

    @Test func launchingOnlyAsksWhetherPasswordsExist() {
        let model = makeModel()
        #expect(model.hasRepositoryPassword(for: Fixture.targetID))
        #expect(passwords.reads == 0)
    }

    @Test func aKeychainThatRefusesThePasswordKeepsTheTargetOutAndSaysWhy() {
        let model = makeModel()
        passwords.refusesWrites = true
        #expect(throws: PasswordStoreError.self) {
            try model.addTarget(Fixture.target(id: Fixture.dataID, name: "Zweite Box"), password: "geheim-2")
        }
        #expect(model.target(Fixture.dataID) == nil)
        let message = PasswordStoreError(underlying: KeychainError(status: errSecInteractionNotAllowed))
            .localizedDescription
        #expect(message.hasPrefix("Passwort konnte nicht im Schlüsselbund gespeichert werden ("))
    }

    @Test func changingThePasswordChangesTheRepositoryThenTheKeychain() async {
        let model = makeModel()
        #expect(await model.changeRepositoryPassword(of: Fixture.targetID, to: "neu") == nil)
        #expect(connection.calls == ["change geheim -> neu"])
        #expect(passwords.password(for: Fixture.targetID) == "neu")
    }

    @Test func aNewPasswordWithSurroundingWhitespaceIsRefusedBeforeResticSeesIt() async {
        let model = makeModel()
        let message = await model.changeRepositoryPassword(of: Fixture.targetID, to: "neu ")
        #expect(message == RepositoryPassword.problem(with: "neu "))
        #expect(message != nil)
        #expect(connection.calls.isEmpty)
        #expect(passwords.password(for: Fixture.targetID) == "geheim")
    }

    @Test func aRefusedPasswordChangeKeepsTheOldPassword() async {
        let model = makeModel()
        connection.change = .failed("Bisheriges Passwort passt nicht")
        #expect(
            await model.changeRepositoryPassword(of: Fixture.targetID, to: "neu") == "Bisheriges Passwort passt nicht")
        #expect(passwords.password(for: Fixture.targetID) == "geheim")
    }

    @Test func aChangedPasswordTheKeychainRefusesIsReported() async {
        let model = makeModel()
        passwords.refusesWrites = true
        let message = await model.changeRepositoryPassword(of: Fixture.targetID, to: "neu")
        #expect(message?.hasPrefix("Das Repository hat jetzt das neue Passwort. ") == true)
    }

    @Test func withoutAStoredPasswordTheGivenOneMustOpenTheRepository() async {
        let model = makeModel()
        try? passwords.removePassword(for: Fixture.targetID)
        connection.verification = .wrong
        #expect(
            await model.changeRepositoryPassword(of: Fixture.targetID, to: "falsch")
                == "Passwort passt nicht zu diesem Repository.")
        #expect(passwords.password(for: Fixture.targetID) == nil)
        connection.verification = .matches
        #expect(await model.changeRepositoryPassword(of: Fixture.targetID, to: "richtig") == nil)
        #expect(passwords.password(for: Fixture.targetID) == "richtig")
        #expect(model.hasRepositoryPassword(for: Fixture.targetID))
    }

    @Test func aConnectionTestUsesTheModelsConnectionAndRemembersSuccess() async {
        let model = makeModel()
        connection.testResult = .failed("Server nicht erreichbar")
        #expect(await model.testConnection(of: Fixture.targetID) == .failed("Server nicht erreichbar"))
        #expect(model.target(Fixture.targetID)?.connectedAt == nil)
        connection.testResult = .succeeded
        #expect(await model.testConnection(of: Fixture.targetID) == .succeeded)
        #expect(model.target(Fixture.targetID)?.connectedAt == Fixture.now)
    }

    @Test func aFinishedPruneCountsTheSnapshotsRetentionForgotSinceThePreviousPrune() async {
        func backup(_ day: Int, forgotten: Int) -> Run {
            Fixture.backup(
                at: Fixture.date(2026, 10, day, 3, 0), statistics: BackupStatistics(snapshotsForgotten: forgotten))
        }
        let runs = [
            backup(3, forgotten: 5), Fixture.prune(at: Fixture.date(2026, 10, 4, 5, 0)), backup(5, forgotten: 2),
            Fixture.prune(status: .failed, at: Fixture.date(2026, 10, 6, 5, 0)), backup(12, forgotten: 3),
        ]
        let model = makeModel(runs: runs)
        model.start(.prune(Fixture.targetID))
        executor.finish(
            with: RunOutcome(status: .success, details: .prune(PruneStatistics(bytesFreed: 1_000)), output: ""))
        await eventually { !model.isBusy }
        #expect(model.runs.last?.details == .prune(PruneStatistics(snapshotsRemoved: 5, bytesFreed: 1_000)))
    }

    @Test func theActiveRunIsNeverRequestedAgain() {
        let model = makeModel()
        model.start(.check(Fixture.targetID))
        model.request(.check(Fixture.targetID))
        #expect(model.queuedRequests.isEmpty)
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
        let model = AppModel(
            passwords: passwords, connection: connection, keys: keys, calendar: Fixture.calendar,
            currentDate: { current }, executor: executor)
        current = Fixture.now.addingTimeInterval(60)
        model.refreshNow()
        #expect(model.now == Fixture.now.addingTimeInterval(60))
    }

    @Test func wakingUpRestartsTheGracePeriodAndAsksTheSystemAgain() {
        var current = Fixture.now
        var system = SystemState()
        let model = AppModel(
            passwords: passwords, connection: connection, keys: keys, calendar: Fixture.calendar,
            currentDate: { current }, awakeSince: Fixture.date(2026, 10, 14, 8, 0), inspectSystem: { system },
            executor: executor)
        #expect(model.awakeSince == Fixture.date(2026, 10, 14, 8, 0))
        current = Fixture.now.addingTimeInterval(600)
        system.hasFullDiskAccess = false
        model.noteWake()
        #expect(model.awakeSince == Fixture.now.addingTimeInterval(600))
        #expect(model.system.hasFullDiskAccess == false)
    }
}
