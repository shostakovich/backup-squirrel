import Foundation
import Testing

@testable import BackupSquirrel

/// The scenarios of issue #1 at model level; connecting an existing repository is in `TargetSetupFlowTests`.
@MainActor
struct ScenarioTests {
    private let clock = TestClock(Fixture.now)
    private let executor = MockRunExecutor()
    private let planner = AlertPlanner(calendar: Fixture.calendar)
    private let threeAM = TimeOfDay(hour: 3, minute: 0)

    private func model(
        plans: [Plan], runs: [Run], system: @escaping () -> SystemState = { SystemState() }, awakeSince: Date? = nil
    ) -> AppModel {
        let clock = clock
        return AppModel(
            targets: [Fixture.target()], plans: plans, runs: runs,
            passwords: InMemoryPasswordStore([Fixture.targetID: "geheim"]), connection: MockConnection(),
            keys: MockKeys(), calendar: Fixture.calendar, currentDate: { clock.now }, awakeSince: awakeSince,
            inspectSystem: system, executor: executor)
    }

    private func status(of planID: Plan.ID, in model: AppModel) -> PlanStatus? {
        model.plan(planID).map { StatusEvaluator(calendar: Fixture.calendar).status(of: $0, in: model.state) }
    }

    private func finish(_ model: AppModel, at date: Date, with outcome: RunOutcome) async {
        clock.now = date
        executor.finish(with: outcome)
        await eventually { !model.isBusy }
    }

    private static let unreachable = RunOutcome(
        status: .failed, details: .backup(BackupStatistics()), failure: .targetUnreachable, output: "")
    private static let success = RunOutcome(
        status: .success, details: .backup(BackupStatistics(filesNew: 12)), output: "snapshot saved")

    /// Mirrors `NotificationController`: only problems that were not there before are posted.
    private final class Notifications {
        var known: Set<AlertKey>?
        var posted: [BackupAlert] = []
    }

    private func notify(_ notifications: Notifications, _ model: AppModel) {
        let result = planner.newAlerts(in: model.state, previous: notifications.known)
        notifications.known = result.current
        notifications.posted += result.new
    }

    @Test func aFailingHourlyBackupBacksOffAndNotifiesOnce() async throws {
        let home = Fixture.plan(name: "Home")
        clock.now = Fixture.date(2026, 10, 14, 13, 2)
        let model = model(
            plans: [home], runs: [Fixture.backup(at: Fixture.date(2026, 10, 14, 12, 2))] + Fixture.maintenance(),
            awakeSince: Fixture.date(2026, 10, 14, 7, 0))
        let notifications = Notifications()
        notify(notifications, model)

        model.startScheduling()
        #expect(executor.jobs.count == 1)
        await finish(model, at: Fixture.date(2026, 10, 14, 13, 2), with: Self.unreachable)
        model.tick()
        #expect(executor.jobs.count == 1, "an instant failure must not start the next attempt right away")
        #expect(status(of: home.id, in: model)?.nextRun == .retry(Fixture.date(2026, 10, 14, 13, 17)))
        notify(notifications, model)
        #expect(notifications.posted.isEmpty)

        clock.now = Fixture.date(2026, 10, 14, 13, 16)
        model.tick()
        #expect(executor.jobs.count == 1)
        clock.now = Fixture.date(2026, 10, 14, 13, 17)
        model.tick()
        #expect(executor.jobs.count == 2)
        notify(notifications, model)
        await finish(model, at: Fixture.date(2026, 10, 14, 13, 17), with: Self.unreachable)
        notify(notifications, model)
        #expect(notifications.posted.map(\.title) == ["Sicherung von „Home“ fehlgeschlagen"])
        #expect(notifications.posted.first?.style?.title == "Erneut versuchen")
        #expect(notifications.posted.first?.command == .start(.backup(home.id)))
        #expect(status(of: home.id, in: model)?.nextRun == .retry(Fixture.date(2026, 10, 14, 13, 47)))

        clock.now = Fixture.date(2026, 10, 14, 13, 47)
        model.tick()
        #expect(executor.jobs.count == 3)
        notify(notifications, model)
        await finish(model, at: Fixture.date(2026, 10, 14, 13, 47), with: Self.unreachable)
        notify(notifications, model)
        #expect(status(of: home.id, in: model)?.nextRun == .retry(Fixture.date(2026, 10, 14, 14, 47)))
        #expect(notifications.posted.count == 1)

        clock.now = Fixture.date(2026, 10, 14, 14, 47)
        model.tick()
        #expect(executor.jobs.count == 4)
        notify(notifications, model)
        await finish(model, at: Fixture.date(2026, 10, 14, 14, 47), with: Self.unreachable)
        notify(notifications, model)
        #expect(status(of: home.id, in: model)?.nextRun == .retry(Fixture.date(2026, 10, 14, 15, 47)))
        #expect(notifications.posted.count == 1, "overdue while failing is still the same failure")

        clock.now = Fixture.date(2026, 10, 14, 15, 46)
        model.tick()
        #expect(executor.jobs.count == 4)
        clock.now = Fixture.date(2026, 10, 14, 15, 47)
        model.tick()
        #expect(executor.jobs.count == 5)
        notify(notifications, model)
        await finish(model, at: Fixture.date(2026, 10, 14, 15, 47), with: Self.unreachable)
        notify(notifications, model)
        #expect(notifications.posted.map(\.title) == ["Sicherung von „Home“ fehlgeschlagen"])
    }

    @Test func catchingUpAfterThreeDaysAsleepIsNotReportedAsOverdue() async throws {
        let data = Fixture.plan(id: Fixture.dataID, name: "Daten", schedule: .daily(at: threeAM))
        let home = Fixture.plan(name: "Home")
        clock.now = Fixture.date(2026, 10, 11, 11, 0)
        let model = model(
            plans: [data, home],
            runs: [
                Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 11, 3, 0)),
                Fixture.backup(at: Fixture.date(2026, 10, 11, 10, 2)),
            ],
            awakeSince: Fixture.date(2026, 10, 11, 7, 0))
        model.startScheduling()
        #expect(executor.jobs.isEmpty)
        let notifications = Notifications()
        notify(notifications, model)

        clock.now = Fixture.date(2026, 10, 14, 8, 0)
        model.noteWake()
        #expect(model.activeRun?.planID == Fixture.dataID)
        #expect(model.activeRun?.startedAt == Fixture.date(2026, 10, 14, 8, 0))
        #expect(model.queuedRequests == [.backup(home.id)])
        notify(notifications, model)

        clock.now = Fixture.date(2026, 10, 14, 8, 19)
        model.tick()
        notify(notifications, model)
        #expect(notifications.posted.isEmpty, "neither the running nor the waiting backup is overdue")

        await finish(model, at: Fixture.date(2026, 10, 14, 8, 20), with: Self.success)
        await eventually { model.activeRun?.planID == home.id }
        notify(notifications, model)
        #expect(notifications.posted.isEmpty)
        await finish(model, at: Fixture.date(2026, 10, 14, 8, 25), with: Self.success)
        notify(notifications, model)
        #expect(notifications.posted.isEmpty)

        let text = StatusText(calendar: Fixture.calendar)
        #expect(text.summary(of: data, in: model.state) == "Gesichert heute, 08:20")
        #expect(status(of: data.id, in: model)?.nextRun == .at(Fixture.date(2026, 10, 15, 3, 0)))
    }

    @Test func aPlanWhoseVolumeIsNotConnectedIsNotAttempted() async throws {
        let data = Fixture.plan(
            id: Fixture.dataID, name: "Daten",
            sourceFolders: [URL(fileURLWithPath: "/Volumes/Daten", isDirectory: true)],
            schedule: .daily(at: threeAM))
        var system = SystemState(mountedVolumes: ["/"])
        clock.now = Fixture.date(2026, 10, 12, 3, 0)
        let model = model(
            plans: [data],
            runs: [Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 11, 3, 0), duration: 30)],
            system: { system }, awakeSince: Fixture.date(2026, 10, 11, 7, 0))
        model.startScheduling()
        let notifications = Notifications()
        notify(notifications, model)
        #expect(executor.jobs.isEmpty)
        let text = StatusText(calendar: Fixture.calendar)
        let nextRun = try #require(status(of: data.id, in: model)?.nextRun)
        #expect(text.nextRunLine(nextRun, model.state) == "Wird nachgeholt, sobald „Daten“ angeschlossen ist")

        clock.now = Fixture.date(2026, 10, 13, 3, 1)
        model.tick()
        #expect(executor.jobs.isEmpty)
        notify(notifications, model)
        #expect(notifications.posted.map(\.title) == ["„Daten“ seit 2 Tagen nicht gesichert"])
        #expect(notifications.posted.first?.command == nil)
        #expect(notifications.posted.first?.style == nil)

        clock.now = Fixture.date(2026, 10, 13, 9, 10)
        system.mountedVolumes = ["/", "/Volumes/Daten"]
        model.refreshSystem()
        #expect(executor.jobs == [.backup(data, Fixture.target())])
        #expect(model.activeRun?.startedAt == Fixture.date(2026, 10, 13, 9, 10))
    }

    @Test func weeklyChecksRotateThroughTheData() {
        clock.now = Fixture.date(2026, 10, 19, 4, 0, 10)
        let runs = [
            Fixture.check(at: Fixture.date(2026, 10, 12, 4, 0), subset: 7),
            Fixture.prune(at: Fixture.date(2026, 10, 18, 5, 0)),
        ]
        let model = model(plans: [], runs: runs)
        model.startScheduling()
        #expect(executor.jobs == [.check(Fixture.target(), subset: 8)])

        let afterTwelve = self.model(
            plans: [],
            runs: [Fixture.check(at: Fixture.date(2026, 10, 12, 4, 0), subset: 12), runs[1]])
        afterTwelve.startScheduling()
        #expect(executor.jobs.last == .check(Fixture.target(), subset: 1))
    }

    @Test func unreadableFilesLeaveASnapshotAndAWarning() async throws {
        let home = Fixture.plan(name: "Home")
        clock.now = Fixture.date(2026, 10, 14, 13, 2)
        let model = model(plans: [home], runs: Fixture.maintenance())
        model.start(.backup(home.id))
        let files = ["/Users/example/Documents/a", "/Users/example/Documents/b", "/Users/example/Documents/c"]
        await finish(
            model, at: Fixture.date(2026, 10, 14, 13, 5),
            with: RunOutcome(
                status: .warning, details: .backup(BackupStatistics(unreadableFiles: files)), output: "",
                monitorPush: MonitorPush(sentAt: Fixture.date(2026, 10, 14, 13, 5))))

        let run = try #require(model.runs.last)
        #expect(run.status == .warning)
        #expect(run.details == .backup(BackupStatistics(unreadableFiles: files)))
        let homeStatus = try #require(status(of: home.id, in: model))
        #expect(homeStatus.lastSnapshot?.id == run.id)
        #expect(homeStatus.health == .warning)
        #expect(homeStatus.warning == .unreadableFiles(3))
        #expect(homeStatus.nextRun == .at(Fixture.date(2026, 10, 14, 14, 2)))
        #expect(run.monitorPush?.failure == nil)
    }
}
