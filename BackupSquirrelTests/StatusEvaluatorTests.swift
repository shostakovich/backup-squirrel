import Foundation
import Testing

@testable import BackupSquirrel

struct StatusEvaluatorTests {
    private let evaluator = StatusEvaluator(calendar: Fixture.calendar, home: Fixture.home)
    private let lastHour = Fixture.date(2026, 10, 14, 13, 2)
    private let threeAM = TimeOfDay(hour: 3, minute: 0)

    private func status(
        of plan: Plan = Fixture.plan(), runs: [Run], now: Date = Fixture.now, system: SystemState = SystemState(),
        queued: [RunRequest] = []
    ) -> PlanStatus {
        evaluator.status(
            of: plan, in: Fixture.state(plans: [plan], runs: runs, now: now, system: system, queued: queued))
    }

    // MARK: Last snapshot and failed attempts

    @Test func lastBackupMeansTheLastSnapshotNotTheLastAttempt() {
        let snapshot = Fixture.backup(at: lastHour.addingTimeInterval(-3600))
        let failed = Fixture.backup(status: .failed, at: lastHour)
        let status = status(runs: [snapshot, failed])
        #expect(status.health == .failed)
        #expect(status.lastSnapshot == snapshot)
        #expect(status.failedAttempt == failed)
        #expect(status.consecutiveFailures == 1)
    }

    @Test func aSnapshotWithWarningsCountsAsSnapshot() {
        let warning = Fixture.backup(
            status: .warning, at: lastHour, statistics: BackupStatistics(unreadableFiles: ["/a"]))
        let status = status(runs: [warning])
        #expect(status.lastSnapshot == warning)
        #expect(status.health == .warning)
        #expect(status.warning == .unreadableFiles(1))
    }

    @Test func aFailureOlderThanTheLastSnapshotIsForgotten() {
        let failed = Fixture.backup(status: .failed, at: lastHour.addingTimeInterval(-3600))
        let status = status(runs: [failed, Fixture.backup(at: lastHour)])
        #expect(status.failedAttempt == nil)
        #expect(status.consecutiveFailures == 0)
        #expect(status.health == .current)
    }

    @Test func aLongBackupCountsFromItsEndNotItsStart() {
        let fiveHours = Fixture.backup(at: Fixture.now.addingTimeInterval(-5 * 3600), duration: 5 * 3600 - 60)
        #expect(status(runs: [fiveHours]).health == .current)
    }

    @Test func cancelledBackupsChangeNothing() {
        let snapshot = Fixture.backup(at: lastHour.addingTimeInterval(-3600))
        let status = status(runs: [snapshot, Fixture.backup(status: .cancelled, at: lastHour)])
        #expect(status.health == .current)
        #expect(status.lastSnapshot == snapshot)
    }

    @Test func runningBackupShowsAsRunningWithoutNextRun() {
        let status = status(runs: [Fixture.backup(at: lastHour), Fixture.backup(status: .running, at: Fixture.now)])
        #expect(status.health == .running)
        #expect(status.nextRun == nil)
    }

    // MARK: Overdue

    @Test func overdueOnlyAfterMoreThanTwoIntervalsWithoutSnapshot() {
        let run = Fixture.backup(at: Fixture.date(2026, 10, 14, 11, 17), duration: 180)
        #expect(status(runs: [run]).health == .current)
        #expect(status(runs: [run], now: Fixture.now.addingTimeInterval(1)).health == .overdue)
    }

    @Test func overdueOutranksAFailure() {
        let daily = Fixture.plan(schedule: .daily(at: threeAM))
        let runs = [
            Fixture.backup(at: Fixture.date(2026, 10, 11, 3, 0)),
            Fixture.backup(status: .failed, at: Fixture.date(2026, 10, 14, 3, 0)),
        ]
        let status = status(of: daily, runs: runs)
        #expect(status.health == .overdue)
        #expect(status.failedAttempt != nil)
    }

    @Test func nothingIsOverdueDuringTheFirstFifteenMinutesAfterLaunchOrWake() {
        let run = Fixture.backup(at: Fixture.date(2026, 10, 14, 8, 0))
        let plan = Fixture.plan()
        let justWoke = Fixture.state(plans: [plan], runs: [run], awakeSince: Fixture.now.addingTimeInterval(-14 * 60))
        #expect(evaluator.status(of: plan, in: justWoke).health == .current)
        #expect(evaluator.status(of: plan, in: justWoke).nextRun == .catchUp)
        let later = Fixture.state(plans: [plan], runs: [run], awakeSince: Fixture.now.addingTimeInterval(-15 * 60))
        #expect(evaluator.status(of: plan, in: later).health == .overdue)
    }

    @Test func theGracePeriodLastsUntilTheCatchUpQueueHasDrained() {
        let data = Fixture.plan(id: Fixture.dataID, name: "Daten")
        let runs = [Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 14, 8, 0))]
        let awakeAnHour = Fixture.now.addingTimeInterval(-3600)
        let catchingUp = Fixture.state(
            plans: [data], runs: runs + [Fixture.backup(status: .running, at: Fixture.now)], awakeSince: awakeAnHour,
            queued: [.check(Fixture.targetID)])
        #expect(evaluator.isInGracePeriod(catchingUp))
        #expect(evaluator.status(of: data, in: catchingUp).health == .current)
        let drained = Fixture.state(plans: [data], runs: runs, awakeSince: awakeAnHour)
        #expect(!evaluator.isInGracePeriod(drained))
        #expect(evaluator.status(of: data, in: drained).health == .overdue)
    }

    @Test func aQueuedPlanIsNeverOverdue() {
        let old = [Fixture.backup(at: Fixture.date(2026, 10, 13, 8, 0))]
        let status = status(runs: old, queued: [.backup(Fixture.homeID)])
        #expect(status.health == .current)
        #expect(status.isQueued)
        #expect(status.nextRun == .catchUp)
    }

    @Test func aNewPlanIsNotYetBackedUpUntilItBecomesOverdue() {
        let fresh = Fixture.plan(createdAt: Fixture.now.addingTimeInterval(-600))
        let old = Fixture.plan(createdAt: Fixture.now.addingTimeInterval(-3 * 3600))
        #expect(status(of: fresh, runs: []).health == .notYetBackedUp)
        #expect(status(of: old, runs: []).health == .overdue)
    }

    // MARK: Why nothing new was saved

    @Test func aStandstillNamesTheFailureTheMissingVolumeACancellationOrTheLastAttempt() {
        let daily = Fixture.plan(schedule: .daily(at: threeAM))
        let snapshot = Fixture.backup(at: Fixture.date(2026, 10, 11, 3, 0))
        let failed = Fixture.backup(status: .failed, at: Fixture.date(2026, 10, 13, 3, 0))
        #expect(status(of: daily, runs: [snapshot, failed]).standstill == .failing(failed))
        let cancelled = Fixture.backup(status: .cancelled, at: Fixture.date(2026, 10, 12, 3, 0))
        #expect(status(of: daily, runs: [snapshot, cancelled]).standstill == .cancelled(at: cancelled.startedAt))
        #expect(status(of: daily, runs: [snapshot]).standstill == .noAttempt(since: snapshot.startedAt))

        let external = Fixture.plan(
            sourceFolders: [URL(fileURLWithPath: "/Volumes/Daten/Fotos", isDirectory: true)],
            schedule: .daily(at: threeAM))
        let unplugged = SystemState(mountedVolumes: ["/", "/Volumes/Archiv"])
        let status = status(of: external, runs: [snapshot, failed], system: unplugged)
        #expect(status.standstill == .volumeMissing("Daten"))
        #expect(status.nextRun == .whenVolumeConnected("Daten"))
        #expect(status.health == .overdue)
    }

    @Test func anUnknownSetOfVolumesCountsAsConnected() {
        let external = Fixture.plan(sourceFolders: [URL(fileURLWithPath: "/Volumes/Daten", isDirectory: true)])
        #expect(status(of: external, runs: [Fixture.backup(at: lastHour)]).nextRun != .whenVolumeConnected("Daten"))
        #expect(SystemState(mountedVolumes: ["/Volumes/Daten"]).missingVolume(for: external.sourceFolders) == nil)
    }

    // MARK: Next run and retries

    @Test func nextRunFollowsTheSchedule() {
        #expect(status(runs: [Fixture.backup(at: lastHour)]).nextRun == .at(Fixture.date(2026, 10, 14, 14, 2)))
    }

    @Test func aMissedRunIsCaughtUpRatherThanDueNow() {
        let daily = Fixture.plan(schedule: .daily(at: threeAM))
        let runs = [Fixture.backup(at: Fixture.date(2026, 10, 13, 3, 0))]
        #expect(status(of: daily, runs: runs).nextRun == .catchUp)
    }

    @Test func retriesBackOffFromFifteenMinutesToAnHourThenFollowTheSchedule() {
        let daily = Fixture.plan(schedule: .daily(at: threeAM))
        let snapshot = Fixture.backup(at: Fixture.date(2026, 10, 13, 3, 0))
        let attempts = [(3, 0), (3, 15), (3, 46), (4, 47)].map { hour, minute in
            Fixture.backup(status: .failed, at: Fixture.date(2026, 10, 14, hour, minute), duration: 30)
        }
        let expected = [
            Fixture.date(2026, 10, 14, 3, 15, 30), Fixture.date(2026, 10, 14, 3, 45, 30),
            Fixture.date(2026, 10, 14, 4, 46, 30), Fixture.date(2026, 10, 15, 3, 0),
        ]
        for count in 1...4 {
            let failures = Array(attempts.prefix(count))
            let now = failures.last!.startedAt.addingTimeInterval(60)
            #expect(status(of: daily, runs: [snapshot] + failures, now: now).nextRun == .retry(expected[count - 1]))
        }
    }

    @Test func anHourlyPlanNeverRetriesMoreOftenThanHourlyOnceTheShortRetriesAreUsedUp() {
        let failures = (0..<4).map { index in
            Fixture.backup(status: .failed, at: Fixture.date(2026, 10, 14, 9 + index, 0), duration: 30)
        }
        let status = status(
            runs: [Fixture.backup(at: Fixture.date(2026, 10, 14, 8, 0))] + failures,
            now: Fixture.date(2026, 10, 14, 12, 1))
        #expect(status.nextRun == .retry(Fixture.date(2026, 10, 14, 13, 0, 30)))
    }

    @Test func aRetryThatIsDueIsCaughtUp() {
        let failed = Fixture.backup(status: .failed, at: Fixture.date(2026, 10, 14, 12, 50), duration: 30)
        #expect(status(runs: [Fixture.backup(at: lastHour.addingTimeInterval(-3600)), failed]).nextRun == .catchUp)
    }

    // MARK: Manual and incomplete plans

    @Test func aManualPlanIsNeverOverdueAndHasNoSchedule() {
        let manual = Fixture.plan(automatic: false)
        let status = status(of: manual, runs: [Fixture.backup(at: Fixture.date(2026, 9, 1, 10, 0))])
        #expect(status.health == .manualOnly)
        #expect(status.nextRun == nil)
        #expect(status.lastSnapshot != nil)
    }

    @Test func aManualPlanStillReportsAFailedBackup() {
        let manual = Fixture.plan(automatic: false)
        let status = status(of: manual, runs: [Fixture.backup(status: .failed, at: lastHour)])
        #expect(status.health == .failed)
        #expect(status.nextRun == nil)
    }

    @Test func anAutomaticPlanWithoutTargetOrFoldersIsAWarningAManualOneIsNot() {
        let noTarget = Fixture.plan(targetID: nil)
        let noFolders = Fixture.plan(sourceFolders: [])
        #expect(status(of: noTarget, runs: []).health == .incomplete(automatic: true))
        #expect(status(of: noTarget, runs: []).health.severity == .warning)
        #expect(status(of: noTarget, runs: []).gap == .noTarget)
        #expect(status(of: noFolders, runs: []).gap == .noSourceFolders)
        #expect(status(of: noFolders, runs: []).nextRun == nil)
        let manual = Fixture.plan(targetID: nil, automatic: false)
        #expect(status(of: manual, runs: []).health.severity == nil)
    }

    // MARK: Uptime Kuma

    @Test func uptimeKumaReportsAndFailures() {
        let plan = Fixture.plan(uptimeKumaPushURL: "https://uptime.example.com/api/push/abc")
        let reported = Fixture.backup(
            at: lastHour.addingTimeInterval(-3600),
            monitorPush: MonitorPush(sentAt: Fixture.date(2026, 10, 14, 12, 5)))
        let rejected = Fixture.backup(
            at: lastHour,
            monitorPush: MonitorPush(sentAt: Fixture.date(2026, 10, 14, 13, 5), failure: .rejected(statusCode: 404)))
        let status = status(of: plan, runs: [reported, rejected])
        #expect(status.lastReport == Fixture.date(2026, 10, 14, 12, 5))
        #expect(status.failedReport == .rejected(statusCode: 404))
        #expect(status.health == .warning)
        #expect(status.warning == .monitorPushFailed(.rejected(statusCode: 404)))
    }

    @Test func aRejectedPushOutranksUnreadableFiles() {
        let plan = Fixture.plan(uptimeKumaPushURL: "https://uptime.example.com/api/push/abc")
        let run = Fixture.backup(
            status: .warning, at: lastHour, statistics: BackupStatistics(unreadableFiles: ["/a"]),
            monitorPush: MonitorPush(sentAt: Fixture.now, failure: .rejected(statusCode: 404)))
        #expect(status(of: plan, runs: [run]).warning == .monitorPushFailed(.rejected(statusCode: 404)))
    }

    @Test func aFailedPushNoLongerMattersOnceTheURLIsRemoved() {
        let rejected = Fixture.backup(
            at: lastHour, monitorPush: MonitorPush(sentAt: Fixture.now, failure: .rejected(statusCode: 404)))
        #expect(status(runs: [rejected]).health == .current)
    }

    // MARK: Targets

    private func targetStatus(_ runs: [Run], target: Target = Fixture.target(), queued: [RunRequest] = [])
        -> TargetStatus
    {
        evaluator.status(of: target, in: Fixture.state(runs: runs, queued: queued))
    }

    @Test func targetHealthFollowsTheLastCheckAndPrune() {
        let today = Fixture.date(2026, 10, 14, 4, 0)
        let sunday = Fixture.date(2026, 10, 11, 5, 0)
        #expect(targetStatus([Fixture.check(at: today), Fixture.prune(at: sunday)]).health == .current)
        #expect(
            targetStatus([Fixture.check(at: today), Fixture.prune(status: .failed, at: sunday)]).health
                == .pruneFailed)
        #expect(targetStatus([Fixture.check(status: .running, at: Fixture.now)]).health == .running)
    }

    @Test func damagedDataAndACheckThatCouldNotRunAreDifferentProblems() {
        let today = Fixture.date(2026, 10, 14, 4, 0)
        let errors = targetStatus([Fixture.check(status: .failed, at: today, errorCount: 3)])
        #expect(errors.health == .checkFoundErrors)
        #expect(errors.lastCheck?.errorCount == 3)
        #expect(errors.nextCheck == .at(Fixture.date(2026, 10, 15, 4, 0)))

        let earlier = Fixture.check(at: Fixture.date(2026, 10, 5, 4, 0), subset: 6)
        let unreachable = Fixture.check(status: .failed, at: Fixture.date(2026, 10, 14, 13, 0))
        let couldNotRun = targetStatus([earlier, unreachable])
        #expect(couldNotRun.health == .checkFailed)
        #expect(couldNotRun.lastCheck == earlier)
        #expect(couldNotRun.failedCheck == unreachable)
        #expect(couldNotRun.checkFailures == 1)
    }

    @Test func damagedDataStaysUntilTheRepeatedSlicePasses() {
        let errors = Fixture.check(status: .failed, at: Fixture.date(2026, 10, 12, 4, 0), subset: 7, errorCount: 3)
        let cancelled = Fixture.check(status: .cancelled, at: Fixture.date(2026, 10, 13, 4, 0), subset: 7)
        let unreachable = Fixture.check(status: .failed, at: Fixture.date(2026, 10, 14, 4, 0), subset: 7)
        #expect(targetStatus([errors, cancelled]).health == .checkFoundErrors)
        #expect(targetStatus([errors, cancelled, unreachable]).health == .checkFoundErrors)

        let passed = Fixture.check(at: Fixture.date(2026, 10, 14, 5, 0), subset: 7)
        #expect(targetStatus([errors, cancelled, unreachable, passed]).health == .current)
    }

    @Test func checksAndPrunesRetryLikeBackups() {
        let checkFailure = Fixture.check(status: .failed, at: Fixture.date(2026, 10, 14, 13, 10))
        #expect(targetStatus([checkFailure]).nextCheck == .retry(Fixture.date(2026, 10, 14, 13, 28, 46)))
        let pruneFailures = [
            Fixture.prune(status: .failed, at: Fixture.date(2026, 10, 14, 12, 30)),
            Fixture.prune(status: .failed, at: Fixture.date(2026, 10, 14, 12, 50)),
        ]
        #expect(
            targetStatus(Fixture.maintenance() + pruneFailures).nextPrune
                == .retry(Fixture.date(2026, 10, 14, 13, 21, 37)))
    }

    @Test func aCheckIsOverdueAfterTwoMissedDays() {
        #expect(targetStatus([Fixture.check(at: Fixture.date(2026, 10, 12, 13, 21))]).health == .current)
        let overdue = targetStatus([Fixture.check(at: Fixture.date(2026, 10, 12, 13, 19))])
        #expect(overdue.health == .checkOverdue)
        #expect(overdue.nextCheck == .catchUp)
        let queued = targetStatus(
            [Fixture.check(at: Fixture.date(2026, 10, 12, 13, 19))], queued: [.check(Fixture.targetID)])
        #expect(queued.health == .current)
    }

    @Test func anOverdueCheckLeavesTheWeeklyPruneAlone() {
        let prune = Fixture.prune(at: Fixture.date(2026, 10, 11, 5, 0))
        let status = targetStatus([Fixture.check(at: Fixture.date(2026, 10, 11, 4, 0)), prune])
        #expect(status.health == .checkOverdue)
        #expect(status.nextCheck == .catchUp)
        #expect(status.nextPrune == .at(Fixture.date(2026, 10, 18, 5, 0)))
    }

    @Test func aPruneSixDaysAgoIsNotYetDueWhileTheCheckIsDueDaily() {
        let runs = [
            Fixture.check(at: Fixture.date(2026, 10, 13, 4, 0)), Fixture.prune(at: Fixture.date(2026, 10, 8, 14, 0)),
        ]
        let status = targetStatus(runs)
        #expect(status.health == .current)
        #expect(status.nextCheck == .catchUp)
        #expect(status.nextPrune == .at(Fixture.date(2026, 10, 15, 14, 0)))
    }

    @Test func aCheckThatFailedForGoodRetriesADayLater() {
        let failures = (0..<4).map { Fixture.check(status: .failed, at: Fixture.date(2026, 10, 14, 9 + $0, 0)) }
        let status = targetStatus([Fixture.check(at: Fixture.date(2026, 10, 14, 4, 0))] + failures)
        #expect(status.nextCheck == .retry(Fixture.date(2026, 10, 15, 12, 3, 46)))
    }

    @Test func anOverdueCheckNamesItsLastAttempt() {
        let lastCheck = Fixture.check(at: Fixture.date(2026, 9, 28, 4, 0))
        let cancelled = Fixture.check(status: .cancelled, at: Fixture.date(2026, 10, 12, 4, 0))
        #expect(targetStatus([lastCheck, cancelled]).checkStandstill == .cancelled(at: cancelled.startedAt))
        #expect(targetStatus([lastCheck]).checkStandstill == .noAttempt(since: lastCheck.startedAt))
    }

    @Test func aNewTargetIsNotYetCheckedUntilTwoDaysPass() {
        let fresh = Fixture.target(createdAt: Fixture.date(2026, 10, 14))
        #expect(targetStatus([], target: fresh).health == .notYetChecked)
        #expect(targetStatus([], target: fresh).nextCheck == .at(Fixture.date(2026, 10, 15)))
        #expect(targetStatus([], target: fresh).nextPrune == .at(Fixture.date(2026, 10, 21)))
        #expect(targetStatus([], target: Fixture.target(createdAt: Fixture.date(2026, 10, 12))).health == .checkOverdue)
    }

    @Test func checksAreDailyAndPrunesWeekly() {
        let status = targetStatus(Fixture.maintenance())
        #expect(status.nextCheck == .at(Fixture.date(2026, 10, 15, 4, 0)))
        #expect(status.nextPrune == .at(Fixture.date(2026, 10, 18, 5, 0)))
    }

    @Test func theLastConnectionIsTheNewestRunThatReachedTheTargetOrTheLastTest() {
        let backup = Fixture.backup(at: lastHour)
        #expect(
            targetStatus([backup, Fixture.backup(status: .failed, at: Fixture.now)]).lastConnection == backup.finishedAt
        )
        var tested = Fixture.target()
        tested.connectedAt = Fixture.now
        #expect(targetStatus([backup], target: tested).lastConnection == Fixture.now)
    }

    // MARK: Set-up

    @Test func nothingIsProtectedWithoutTargetPlanOrAutomaticPlan() {
        #expect(evaluator.setupGap(in: Fixture.state(plans: [], targets: [])) == .noTarget)
        #expect(evaluator.setupGap(in: Fixture.state(plans: [])) == .noPlan)
        #expect(evaluator.setupGap(in: Fixture.state(plans: [Fixture.plan(automatic: false)])) == .nothingAutomatic)
        #expect(evaluator.setupGap(in: Fixture.state(plans: [Fixture.plan(sourceFolders: [])])) == .nothingAutomatic)
        #expect(evaluator.setupGap(in: Fixture.state()) == nil)
    }

    // MARK: Problems

    @Test func problemsListErrorsBeforeWarnings() {
        let data = Fixture.plan(id: Fixture.dataID, name: "Daten")
        let runs =
            [
                Fixture.backup(status: .warning, at: lastHour),
                Fixture.backup(plan: Fixture.dataID, status: .failed, at: lastHour),
            ] + Fixture.maintenance()
        let problems = evaluator.problems(in: Fixture.state(plans: [Fixture.plan(), data], runs: runs))
        #expect(
            problems == [
                Problem(subject: .plan(Fixture.dataID), severity: .error),
                Problem(subject: .plan(Fixture.homeID), severity: .warning),
            ])
    }

    @Test(
        arguments: [
            ("/Users/example", true), ("/Users/example/Documents", true), ("/Users", true), ("/", true),
            ("/Volumes/Daten", true), ("/Volumes/Daten/Fotos", true), ("/opt/data", false),
            ("/Users/examples", false),
        ])
    func fullDiskAccessIsNeededForTheHomeFolderAndExternalVolumes(path: String, needed: Bool) {
        let plan = Fixture.plan(sourceFolders: [URL(fileURLWithPath: path, isDirectory: true)])
        #expect(evaluator.needsFullDiskAccess(plan) == needed)
    }

    @Test func missingFullDiskAccessIsAProblemOnlyForPlansThatNeedIt() {
        let noAccess = SystemState(hasFullDiskAccess: false)
        let optional = Fixture.plan(sourceFolders: [URL(fileURLWithPath: "/opt/data", isDirectory: true)])
        #expect(evaluator.systemProblems(in: Fixture.state(plans: [optional], system: noAccess)).isEmpty)
        #expect(evaluator.systemProblems(in: Fixture.state(system: noAccess)) == [.noFullDiskAccess])
    }

    @Test func aMissingLoginItemAndMissingNotificationsMatterOnlyWithAnAutomaticPlan() {
        let system = SystemState(opensAtLogin: false, notifications: .denied)
        #expect(evaluator.systemProblems(in: Fixture.state(system: system)) == [.notOpeningAtLogin, .notificationsOff])
        let undecided = SystemState(notifications: .notDetermined)
        #expect(evaluator.systemProblems(in: Fixture.state(system: undecided)) == [.notificationsOff])
        let manual = Fixture.state(plans: [Fixture.plan(automatic: false)], system: system)
        #expect(evaluator.systemProblems(in: manual).isEmpty)
    }

    // MARK: Menu bar icon

    @Test func iconShowsRunningWithProgressFirst() {
        let state = Fixture.state(
            runs: [Fixture.backup(status: .failed, at: lastHour), Fixture.backup(status: .running, at: Fixture.now)],
            progress: Fixture.progress(filesDone: 1, filesTotal: 4))
        #expect(evaluator.iconState(for: state) == .running(fraction: 0.25))
    }

    @Test func iconIsDimmedWhenNothingIsProtected() {
        #expect(evaluator.iconState(for: Fixture.state(plans: [], targets: [])) == .notSetUp)
        let failedManual = Fixture.state(
            plans: [Fixture.plan(automatic: false)], runs: [Fixture.backup(status: .failed, at: lastHour)])
        #expect(evaluator.iconState(for: failedManual) == .notSetUp)
    }

    @Test func iconTreatsFailedAndOverduePlansAndFailedChecksAsErrors() {
        let healthy = Fixture.maintenance()
        #expect(
            evaluator.iconState(for: Fixture.state(runs: healthy + [Fixture.backup(status: .failed, at: lastHour)]))
                == .error)
        let overdue = Fixture.backup(at: Fixture.date(2026, 10, 14, 8, 0))
        #expect(evaluator.iconState(for: Fixture.state(runs: healthy + [overdue])) == .error)
        let failedCheck = [Fixture.backup(at: lastHour), Fixture.check(status: .failed, at: lastHour)]
        #expect(evaluator.iconState(for: Fixture.state(runs: failedCheck)) == .error)
    }

    @Test func iconShowsWarningsIncludingThoseOfThisMac() {
        let healthy = [Fixture.backup(at: lastHour)] + Fixture.maintenance()
        #expect(evaluator.iconState(for: Fixture.state(runs: healthy)) == .idle)
        let warning = [Fixture.backup(status: .warning, at: lastHour)] + Fixture.maintenance()
        #expect(evaluator.iconState(for: Fixture.state(runs: warning)) == .warning)
        let overdueCheck = [Fixture.backup(at: lastHour), Fixture.check(at: Fixture.date(2026, 9, 28, 4, 0))]
        #expect(evaluator.iconState(for: Fixture.state(runs: overdueCheck)) == .warning)
        let noLogin = Fixture.state(runs: healthy, system: SystemState(opensAtLogin: false))
        #expect(evaluator.iconState(for: noLogin) == .warning)
    }
}
