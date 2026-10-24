import Foundation
import Testing

@testable import BackupSquirrel

struct AlertPlannerTests {
    private let planner = AlertPlanner(calendar: Fixture.calendar)
    private let threeAM = TimeOfDay(hour: 3, minute: 0)
    private var data: Plan { Fixture.plan(id: Fixture.dataID, name: "Daten", schedule: .daily(at: threeAM)) }
    private let yesterday = Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 13, 3, 0))

    private func failed(at start: Date) -> Run {
        Fixture.backup(plan: Fixture.dataID, status: .failed, at: start)
    }

    @Test func aSingleFailureThatMayHealWithinFifteenMinutesStaysQuiet() {
        let failure = failed(at: Fixture.date(2026, 10, 14, 3, 0))
        let result = planner.newAlerts(in: Fixture.state(plans: [data], runs: [yesterday, failure]), previous: [])
        #expect(result.new.isEmpty)
    }

    @Test func aFailedRetryNotifiesWithCauseLastSnapshotAndARetryButton() {
        let first = failed(at: Fixture.date(2026, 10, 14, 3, 0))
        let retry = failed(at: Fixture.date(2026, 10, 14, 3, 15))
        let result = planner.newAlerts(in: Fixture.state(plans: [data], runs: [yesterday, first, retry]), previous: [])
        #expect(result.new.count == 1)
        let alert = result.new.first
        #expect(alert?.title == "Sicherung von „Daten“ fehlgeschlagen")
        #expect(alert?.body == "„Storage Box“ ist nicht erreichbar. Die letzte Sicherung ist von gestern, 03:03.")
        #expect(alert?.style == .retry)
        #expect(alert?.style?.title == "Erneut versuchen")
        #expect(alert?.command == .start(.backup(Fixture.dataID)))
        #expect(alert?.route == .showRun(retry.id))
    }

    @Test func withoutARecordTheFirstEvaluationOnlyRecordsTheBaseline() {
        let runs = [
            yesterday, failed(at: Fixture.date(2026, 10, 14, 3, 0)), failed(at: Fixture.date(2026, 10, 14, 3, 15)),
        ]
        let result = planner.newAlerts(in: Fixture.state(plans: [data], runs: runs), previous: nil)
        #expect(result.new.isEmpty)
        #expect(result.current == [AlertKey(kind: .backupFailed, subject: Fixture.dataID)])
    }

    @Test func retriesThatFailAgainDoNotNotifyAgain() {
        let runs = [
            yesterday, failed(at: Fixture.date(2026, 10, 14, 3, 0)), failed(at: Fixture.date(2026, 10, 14, 3, 15)),
        ]
        let known = planner.newAlerts(in: Fixture.state(plans: [data], runs: runs), previous: []).current

        let retrying = Fixture.state(
            plans: [data],
            runs: runs + [Fixture.backup(plan: Fixture.dataID, status: .running, at: Fixture.date(2026, 10, 14, 3, 45))]
        )
        let duringRetry = planner.newAlerts(in: retrying, previous: known)
        #expect(duringRetry.new.isEmpty)

        let again = Fixture.state(plans: [data], runs: runs + [failed(at: Fixture.date(2026, 10, 14, 3, 45))])
        #expect(planner.newAlerts(in: again, previous: duringRetry.current).new.isEmpty)
    }

    @Test func anOverduePlanNotifiesWithAButtonThatBacksItUp() {
        let cancelled = Fixture.backup(plan: Fixture.dataID, status: .cancelled, at: Fixture.date(2026, 10, 12, 3, 0))
        let runs = [Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 11, 3, 0)), cancelled]
        let result = planner.newAlerts(in: Fixture.state(plans: [data], runs: runs), previous: [])
        #expect(result.new.map(\.title) == ["„Daten“ seit 3 Tagen nicht gesichert"])
        #expect(
            result.new.first?.body
                == "Der letzte Versuch am Mo., 12.10. wurde abgebrochen. Die letzte Sicherung ist von So., 11.10., 03:03."
        )
        #expect(result.new.first?.style == .backUpNow)
        #expect(result.new.first?.command == .start(.backup(Fixture.dataID)))
        #expect(result.new.first?.route == .showPlan(Fixture.dataID))
    }

    @Test func anOverduePlanThatKeepsFailingReportsOnlyTheFailure() {
        let snapshot = Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 11, 3, 0))
        let first = failed(at: Fixture.date(2026, 10, 12, 3, 0))
        #expect(planner.alerts(in: Fixture.state(plans: [data], runs: [snapshot, first])).isEmpty)
        let retry = failed(at: Fixture.date(2026, 10, 12, 3, 15))
        let alerts = planner.alerts(in: Fixture.state(plans: [data], runs: [snapshot, first, retry]))
        #expect(alerts.map(\.key) == [AlertKey(kind: .backupFailed, subject: Fixture.dataID)])
    }

    @Test func aKnownOverduePlanStaysKnownWhileAnotherRunsAndAfterWake() {
        let home = Fixture.plan()
        let runs = [
            Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 11, 3, 0)),
            Fixture.backup(plan: Fixture.dataID, status: .cancelled, at: Fixture.date(2026, 10, 12, 3, 0)),
            Fixture.backup(at: Fixture.date(2026, 10, 14, 12, 2)),
        ]
        let overdue = AlertKey(kind: .overdue, subject: Fixture.dataID)
        let known = planner.newAlerts(in: Fixture.state(plans: [data, home], runs: runs), previous: []).current
        #expect(known == [overdue])

        let running = runs + [Fixture.backup(status: .running, at: Fixture.date(2026, 10, 14, 13, 19))]
        let duringRun = planner.newAlerts(in: Fixture.state(plans: [data, home], runs: running), previous: known)
        #expect(duringRun.current == [overdue])
        let afterRun = runs + [Fixture.backup(at: Fixture.date(2026, 10, 14, 13, 19), duration: 30)]
        #expect(
            planner.newAlerts(in: Fixture.state(plans: [data, home], runs: afterRun), previous: duringRun.current)
                .new.isEmpty)

        let justAwake = Fixture.state(plans: [data, home], runs: runs, awakeSince: Fixture.now.addingTimeInterval(-60))
        #expect(planner.newAlerts(in: justAwake, previous: known).current == [overdue])
        #expect(planner.newAlerts(in: justAwake, previous: []).new.isEmpty, "a new problem waits for the catch-up")
    }

    @Test func damagedDataNotifiesRightAwayWithACheckButton() {
        let check = Fixture.check(status: .failed, at: Fixture.date(2026, 10, 12, 4, 0), errorCount: 3)
        let alerts = planner.alerts(
            in: Fixture.state(runs: [Fixture.backup(at: Fixture.date(2026, 10, 14, 13, 2)), check]))
        #expect(alerts.map(\.title) == ["Fehler in den Sicherungen auf „Storage Box“"])
        #expect(alerts.first?.body == "Die Prüfung hat 3 Fehler in Teil 7 von 128 gefunden.")
        #expect(alerts.first?.style == .checkNow)
        #expect(alerts.first?.command == .start(.check(Fixture.targetID)))
        #expect(alerts.first?.route == .showRun(check.id))
    }

    @Test func aCheckThatCouldNotRunNotifiesOnlyAfterItsRetryFailedToo() {
        let lastCheck = Fixture.check(at: Fixture.date(2026, 10, 5, 4, 0))
        let first = Fixture.check(status: .failed, at: Fixture.date(2026, 10, 14, 12, 50))
        let backup = Fixture.backup(at: Fixture.date(2026, 10, 14, 13, 2))
        #expect(planner.alerts(in: Fixture.state(runs: [backup, lastCheck, first])).isEmpty)
        let retry = Fixture.check(status: .failed, at: Fixture.date(2026, 10, 14, 13, 5))
        let alerts = planner.alerts(in: Fixture.state(runs: [backup, lastCheck, first, retry]))
        #expect(alerts.map(\.title) == ["Prüfung von „Storage Box“ konnte nicht laufen"])
        #expect(
            alerts.first?.body == "„Storage Box“ ist nicht erreichbar. Die letzte Prüfung war am Mo., 05.10.")
    }

    @Test func anOverdueCheckNotifiesOnce() {
        let old = Fixture.check(at: Fixture.date(2026, 9, 28, 4, 0))
        let state = Fixture.state(runs: [Fixture.backup(at: Fixture.date(2026, 10, 14, 13, 2)), old])
        let first = planner.newAlerts(in: state, previous: [])
        #expect(first.new.map(\.title) == ["Prüfung von „Storage Box“ überfällig"])
        #expect(first.new.first?.body == "Die letzte Prüfung war am Mo., 28.09.")
        #expect(first.new.first?.style == .checkNow)
        #expect(planner.newAlerts(in: state, previous: first.current).new.isEmpty)
    }

    @Test func aRejectedUptimeKumaPushNotifiesInAFullSentenceWithAResendButton() {
        let plan = Fixture.plan(uptimeKumaPushURL: "https://uptime.example.com/api/push/abc")
        let run = Fixture.backup(
            at: Fixture.date(2026, 10, 14, 13, 2),
            monitorPush: MonitorPush(sentAt: Fixture.now, failure: .rejected(statusCode: 404)))
        let alerts = planner.alerts(in: Fixture.state(plans: [plan], runs: [run]))
        #expect(alerts.map(\.title) == ["Meldung an Uptime Kuma fehlgeschlagen"])
        #expect(alerts.first?.body == "Uptime Kuma hat die Meldung für „Home-Verzeichnis“ abgelehnt (HTTP 404).")
        #expect(alerts.first?.style == .resendReport)
        #expect(alerts.first?.style?.title == "Erneut melden")
        #expect(alerts.first?.command == .resendReport(Fixture.homeID))
    }

    @Test func warningsAboutUnreadableFilesDoNotNotify() {
        let run = Fixture.backup(
            status: .warning, at: Fixture.date(2026, 10, 14, 13, 2),
            statistics: BackupStatistics(unreadableFiles: ["/a"]))
        #expect(planner.alerts(in: Fixture.state(runs: [run])).isEmpty)
    }

    @Test func routesAndCommandsSurviveTheNotificationRoundTrip() {
        let id = UUID()
        for action in [MenuAction.showRun(id), .showPlan(id), .showTarget(id), .showHistory] {
            #expect(AlertRoute.decode(AlertRoute.encode(action)) == action)
        }
        #expect(AlertRoute.decode("nonsense") == nil)
        for command in [
            AlertCommand.start(.backup(id)), .start(.check(id)), .start(.prune(id)), .resendReport(id),
        ] {
            #expect(AlertRoute.decodeCommand(AlertRoute.encode(command)) == command)
        }
        #expect(AlertRoute.decodeCommand("backup:nonsense") == nil)
    }

    @Test func notifiedAlertsSurviveARelaunch() throws {
        let suite = "NotifiedAlertsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NotifiedAlerts(defaults: defaults)
        #expect(store.load() == nil)
        let keys: Set = [
            AlertKey(kind: .backupFailed, subject: Fixture.homeID),
            AlertKey(kind: .checkOverdue, subject: Fixture.targetID),
        ]
        store.save(keys)
        #expect(NotifiedAlerts(defaults: defaults).load() == keys)
        store.save([])
        #expect(store.load() == [])
    }

    @Test func aRelaunchNotifiesOnlyWhatAppearedMeanwhile() {
        let known: Set = [AlertKey(kind: .backupFailed, subject: Fixture.dataID)]
        let runs = [
            Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 11, 3, 0)),
            failed(at: Fixture.date(2026, 10, 12, 3, 0)), failed(at: Fixture.date(2026, 10, 12, 3, 15)),
            Fixture.check(status: .failed, at: Fixture.date(2026, 10, 12, 4, 0), errorCount: 3),
        ]
        let result = planner.newAlerts(in: Fixture.state(plans: [data], runs: runs), previous: known)
        #expect(result.new.map(\.key) == [AlertKey(kind: .checkFoundErrors, subject: Fixture.targetID)])
    }
}
