import Foundation
import Testing

@testable import BackupSquirrel

struct HistoryFilterTests {
    private let otherTarget = UUID()
    private let runs: [Run] = {
        let day = Fixture.date(2026, 10, 14)
        return [
            Fixture.backup(plan: Fixture.homeID, at: day),
            Fixture.backup(plan: Fixture.dataID, at: day),
            Fixture.check(at: day),
            Fixture.prune(at: day),
        ]
    }()

    @Test func showsEverythingByDefault() {
        let filter = HistoryFilter()
        #expect(filter.apply(to: runs).count == 4)
        #expect(!filter.isActive)
    }

    @Test func filtersByPlan() {
        let filter = HistoryFilter(scope: .plan(Fixture.dataID))
        #expect(filter.apply(to: runs).map(\.planID) == [Fixture.dataID])
        #expect(filter.isActive)
    }

    @Test func targetScopeIncludesBackupsChecksAndPrunesOfThatTarget() {
        #expect(HistoryFilter(scope: .target(Fixture.targetID)).apply(to: runs).count == 4)
        #expect(HistoryFilter(scope: .target(otherTarget)).apply(to: runs).isEmpty)
    }

    @Test func onlyProblemsKeepsFailuresAndWarnings() {
        let day = Fixture.date(2026, 10, 14)
        let runs = [
            Fixture.backup(at: day), Fixture.backup(status: .failed, at: day),
            Fixture.backup(status: .warning, at: day), Fixture.backup(status: .cancelled, at: day),
        ]
        let filter = HistoryFilter(onlyProblems: true)
        #expect(filter.apply(to: runs).map(\.status) == [.failed, .warning])
        #expect(filter.isActive)
    }

    @Test func groupsByDayInTheGivenOrder() {
        let runs = [
            Fixture.backup(at: Fixture.date(2026, 10, 14, 13, 2)), Fixture.backup(at: Fixture.date(2026, 10, 14, 3, 0)),
            Fixture.check(at: Fixture.date(2026, 10, 13, 4, 0)), Fixture.prune(at: Fixture.date(2026, 10, 11, 5, 0)),
        ]
        let days = HistoryDay.group(runs, calendar: Fixture.calendar, now: Fixture.now)
        #expect(days.map(\.title) == ["Heute", "Gestern", "So., 11.10."])
        #expect(days.map(\.runs.count) == [2, 1, 1])
        #expect(days.first?.rows.map(\.id).first == HistoryRow.day(days[0]).id)
        #expect(days.first?.rows.count == 3)
    }

    @Test func pastDaysWithoutAnyRunGetAnEmptyDayWhileAnAutomaticPlanWasDue() {
        let runs = [
            Fixture.backup(at: Fixture.date(2026, 10, 14, 13, 2)), Fixture.backup(at: Fixture.date(2026, 10, 11, 3, 0)),
        ]
        let calendar = Fixture.calendar
        let days = HistoryDay.group(
            runs, calendar: calendar, now: Fixture.now, dueSince: Fixture.date(2026, 1, 1),
            daysWithRuns: [calendar.startOfDay(for: Fixture.date(2026, 10, 12, 4, 0))])
        #expect(days.map(\.title) == ["Heute", "Gestern", "So., 11.10."])
        #expect(days.map(\.runs.isEmpty) == [false, true, false])
        let ascending = HistoryDay.group(
            runs.reversed(), calendar: calendar, now: Fixture.now, dueSince: Fixture.date(2026, 10, 12),
            daysWithRuns: [])
        #expect(ascending.map(\.title) == ["So., 11.10.", "Mo., 12.10.", "Gestern", "Heute"])
        #expect(
            HistoryDay.group(runs, calendar: calendar, now: Fixture.now, dueSince: nil, daysWithRuns: []).count == 2)
    }

    @Test func gapsCountOnlyWhileAnAutomaticPlanInTheFilterWasDue() {
        let plans = [
            Fixture.plan(createdAt: Fixture.date(2026, 3, 1)),
            Fixture.plan(id: Fixture.dataID, automatic: false, createdAt: Fixture.date(2026, 1, 1)),
        ]
        #expect(HistoryFilter().dueSince(plans: plans) == Fixture.date(2026, 3, 1))
        #expect(HistoryFilter(scope: .plan(Fixture.dataID)).dueSince(plans: plans) == nil)
        #expect(HistoryFilter(kind: .check).dueSince(plans: plans) == nil)
        #expect(HistoryFilter(scope: .target(Fixture.targetID)).dueSince(plans: plans) == Fixture.date(2026, 3, 1))
    }

    @Test func filtersByKindAndCombinesWithScope() {
        #expect(HistoryFilter(kind: .check).apply(to: runs).map(\.kind) == [.check])
        #expect(HistoryFilter(scope: .plan(Fixture.homeID), kind: .prune).apply(to: runs).isEmpty)
        #expect(HistoryFilter(scope: .target(Fixture.targetID), kind: .backup).apply(to: runs).count == 2)
    }
}

struct RunTextTests {
    private let start = Fixture.date(2026, 10, 14, 13, 2)
    private let state = Fixture.state()

    @Test func backupSummariesStayShortAndTheTooltipSaysItAll() {
        let backup = Fixture.backup(
            at: start, statistics: BackupStatistics(filesNew: 77, filesChanged: 43, bytesAdded: 59_300_000))
        #expect(RunText.summary(of: backup, in: state) == "77 neu · 43 geändert · 59,3 MB")
        #expect(
            RunText.fullSummary(of: backup, in: state) == "77 neue und 43 geänderte Dateien, 59,3 MB hinzugefügt.")
        let warning = Fixture.backup(
            status: .warning, at: start, statistics: BackupStatistics(bytesAdded: 1_500_000, unreadableFiles: ["/x"]))
        #expect(RunText.summary(of: warning, in: state) == "1 Datei nicht lesbar · 1,5 MB")
        let failed = Fixture.backup(status: .failed, at: start)
        #expect(RunText.summary(of: failed, in: state) == "Storage Box nicht erreichbar")
        #expect(RunText.fullSummary(of: failed, in: state) == "Storage Box nicht erreichbar. Netzwerk prüfen.")
        #expect(RunText.summary(of: Fixture.backup(status: .cancelled, at: start), in: state) == "Abgebrochen")
        #expect(RunText.summary(of: Fixture.backup(status: .running, at: start), in: state) == "Läuft …")
        let other = Fixture.backup(status: .failed, at: start, failure: .other("Repository gesperrt"))
        #expect(RunText.fullSummary(of: other, in: state) == "Repository gesperrt.")
    }

    @Test func checkAndPruneSummariesAvoidJargon() {
        #expect(RunText.summary(of: Fixture.check(at: start), in: state) == "Teil 7 von 12 · keine Fehler")
        let damaged = Fixture.check(status: .failed, at: start, errorCount: 2)
        #expect(RunText.summary(of: damaged, in: state) == "2 Fehler in Teil 7 von 12")
        #expect(RunText.title(of: damaged) == "Fehler gefunden")
        #expect(RunText.title(of: Fixture.check(status: .failed, at: start)) == "Fehlgeschlagen")
        #expect(RunText.summary(of: Fixture.prune(at: start), in: state) == "14 ältere Sicherungen entfernt")
        #expect(
            RunText.fullSummary(of: Fixture.prune(at: start), in: state)
                == "14 ältere Sicherungen entfernt, 2,1 GB freigegeben.")
    }

    @Test func pushFailuresSayWhatToDo() {
        #expect(RunText.pushReason(.rejected(statusCode: 404)) == "Uptime Kuma kennt diese Push-URL nicht (HTTP 404)")
        #expect(RunText.pushAdvice(.rejected(statusCode: 404)) == "Push-URL prüfen")
        #expect(RunText.pushReason(.rejected(statusCode: 500)) == "Uptime Kuma hat die Meldung abgelehnt (HTTP 500)")
        #expect(RunText.pushReason(.unreachable) == "Uptime Kuma nicht erreichbar")
    }

    @Test func subjectIsThePlanForBackupsAndTheTargetOtherwise() {
        #expect(RunText.subject(of: Fixture.backup(at: start), in: state) == "Home-Verzeichnis")
        #expect(RunText.subject(of: Fixture.check(at: start), in: state) == "Storage Box")
        #expect(RunText.subject(of: Fixture.backup(plan: UUID(), at: start), in: state) == "Gelöschter Plan")
    }

    @Test func titlesAndSymbols() {
        #expect(RunKind.allCases.map(RunText.title(of:)) == ["Sicherung", "Prüfung", "Aufräumen"])
        #expect(RunText.title(of: Fixture.backup(status: .warning, at: start)) == "Mit Warnungen")
        #expect(RunText.symbol(for: .failed) == .failure)
        #expect(RunText.listSymbol(for: .success) == nil)
        #expect(RunText.listSymbol(for: .cancelled) == .cancelled)
    }

    @Test func operationAndHeadingNameKindAndSubject() {
        #expect(RunText.operation(of: Fixture.backup(at: start), in: state) == "Sicherung · Home-Verzeichnis")
        #expect(RunText.heading(of: Fixture.check(at: start), in: state) == "Prüfung „Storage Box“")
    }
}

struct SSHKeyTests {
    @Test func installCommandEscapesThePathAndUsesTheTargetPort() {
        let target = Fixture.target()
        #expect(
            target.sshKey.installCommand(for: target)
                == "cat ~/Library/Application\\ Support/Backup-Squirrel/Keys/storage-box.pub "
                + "| ssh -p23 u123456-sub1@u123456.your-storagebox.de install-ssh-key")
        #expect(target.repository == "sftp://u123456-sub1@u123456.your-storagebox.de:23//home/restic/mac")
        let custom = Fixture.target(port: 2222)
        #expect(custom.sshKey.installCommand(for: custom).contains("ssh -p2222 "))
    }
}
