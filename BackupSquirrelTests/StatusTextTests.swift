import Foundation
import Testing

@testable import BackupSquirrel

struct StatusTextTests {
    private let text = StatusText(calendar: Fixture.calendar, home: Fixture.home)
    private let lastHour = Fixture.date(2026, 10, 14, 13, 2)
    private let threeAM = TimeOfDay(hour: 3, minute: 0)
    private var data: Plan { Fixture.plan(id: Fixture.dataID, name: "Daten", schedule: .daily(at: threeAM)) }

    // MARK: Headline

    @Test func runningBackupShowsPlanPercentFilesAndRemainingTime() {
        let state = Fixture.state(runs: [Fixture.backup(status: .running, at: lastHour)], progress: Fixture.progress())
        #expect(text.headline(for: state).title == "Sichert „Home-Verzeichnis“ – 43 %")
        #expect(text.headline(for: state).subtitle == "12.345 von 28.901 Dateien · noch ca. 18 Min.")
    }

    @Test func runningBackupBeforeTheFirstProgressReport() {
        let state = Fixture.state(runs: [Fixture.backup(status: .running, at: lastHour)])
        #expect(text.headline(for: state).title == "Sichert „Home-Verzeichnis“ …")
        #expect(text.headline(for: state).subtitle == "Wird vorbereitet")
    }

    @Test func runningCheckAndPruneNameTheTarget() {
        var check = Fixture.state(
            runs: [Fixture.check(status: .running, at: Fixture.now)],
            progress: Fixture.progress(filesDone: 206, filesTotal: 0, secondsRemaining: 240))
        check.progress?.fractionCompleted = 0.5
        #expect(text.headline(for: check).title == "Prüft „Storage Box“ – 50 %")
        #expect(text.headline(for: check).subtitle == "Teil 7 von 12 · noch ca. 4 Min.")

        var prune = Fixture.state(runs: [Fixture.prune(status: .running, at: Fixture.now)], progress: check.progress)
        prune.progress?.fractionCompleted = 0.1
        #expect(text.headline(for: prune).title == "Räumt „Storage Box“ auf – 10 %")
    }

    @Test func allCurrentWithOnePlanNamesItsLastSnapshot() {
        let headline = text.headline(for: Fixture.state(runs: [Fixture.backup(at: lastHour)]))
        #expect(headline.title == "Alle Sicherungen aktuell")
        #expect(headline.subtitle == "Zuletzt gesichert: heute, 13:02")
    }

    @Test func allCurrentWithSeveralPlansLeavesTheDatesToThePlanRows() {
        let runs = [
            Fixture.backup(at: lastHour), Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 14, 3, 0)),
        ]
        let headline = text.headline(for: Fixture.state(plans: [Fixture.plan(), data], runs: runs))
        #expect(headline.title == "Alle Sicherungen aktuell")
        #expect(headline.subtitle == nil)
    }

    @Test func notSetUpSaysWhatIsMissing() {
        #expect(
            text.headline(for: Fixture.state(plans: [], targets: [])) == (
                "Nicht eingerichtet", "Noch kein Ziel eingerichtet"
            ))
        #expect(text.headline(for: Fixture.state(plans: [])) == ("Nicht eingerichtet", "Noch kein Plan eingerichtet"))
        #expect(
            text.headline(for: Fixture.state(plans: [Fixture.plan(automatic: false)]))
                == ("Nicht eingerichtet", "Kein Plan sichert automatisch"))
    }

    @Test func anAutomaticPlanWithoutTargetSaysItDoesNotBackUp() {
        let orphan = Fixture.plan(id: Fixture.dataID, name: "Daten", targetID: nil)
        let runs = [
            Fixture.backup(at: lastHour), Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 13, 3, 0)),
        ]
        let state = Fixture.state(plans: [Fixture.plan(), orphan], runs: runs)
        #expect(text.headline(for: state) == ("„Daten“ sichert nicht automatisch", "Kein Ziel ausgewählt"))
        #expect(text.summary(of: orphan, in: state) == "Kein Ziel ausgewählt · zuletzt gesichert gestern, 03:00")
        #expect(text.menuSymbol(for: PlanHealth.incomplete(automatic: true)) == .warning)
    }

    @Test func oneFailedPlanIsNamedWithItsLastSnapshot() {
        let runs = [
            Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 13, 3, 0)),
            Fixture.backup(plan: Fixture.dataID, status: .failed, at: Fixture.date(2026, 10, 14, 3, 0)),
            Fixture.backup(at: lastHour),
        ]
        let headline = text.headline(for: Fixture.state(plans: [Fixture.plan(), data], runs: runs))
        #expect(headline.title == "Sicherung von „Daten“ fehlgeschlagen")
        #expect(headline.subtitle == "Zuletzt gesichert: gestern, 03:00")
    }

    @Test func theNewestSnapshotOfAnotherPlanNeverMasksAStalePlan() {
        let runs = [
            Fixture.backup(at: lastHour), Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 11, 3, 0)),
        ]
        let headline = text.headline(for: Fixture.state(plans: [Fixture.plan(), data], runs: runs))
        #expect(headline.title == "„Daten“ seit 3 Tagen nicht gesichert")
        #expect(headline.subtitle == "Zuletzt gesichert: So., 11.10., 03:00")
    }

    @Test func overdueCountsHoursBelowTwoDays() {
        let runs = [Fixture.backup(at: Fixture.date(2026, 10, 14, 8, 2))]
        #expect(
            text.headline(for: Fixture.state(runs: runs)).title == "„Home-Verzeichnis“ seit 5 Stunden nicht gesichert")
    }

    @Test func aPlanThatNeverRanIsOverdueAsNeverBackedUp() {
        let headline = text.headline(for: Fixture.state(plans: [data]))
        #expect(headline.title == "„Daten“ noch nie gesichert")
        #expect(headline.subtitle == nil)
    }

    @Test func severalProblemsAreCountedAndNamed() {
        let runs = [
            Fixture.backup(status: .failed, at: lastHour),
            Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 11, 3, 0)),
        ]
        let headline = text.headline(for: Fixture.state(plans: [Fixture.plan(), data], runs: runs))
        #expect(headline.title == "2 Pläne mit Problemen")
        #expect(headline.subtitle == "„Home-Verzeichnis“, „Daten“")

        let withTarget = Fixture.state(runs: [
            Fixture.backup(status: .failed, at: lastHour), Fixture.check(status: .failed, at: lastHour),
        ])
        #expect(text.headline(for: withTarget).title == "1 Plan und 1 Ziel mit Problemen")
    }

    @Test func warningsAndTargetProblemsHaveTheirOwnHeadline() {
        let unreadable = Fixture.backup(
            status: .warning, at: lastHour, statistics: BackupStatistics(unreadableFiles: ["/a", "/b", "/c"]))
        #expect(
            text.headline(for: Fixture.state(runs: [unreadable])).title == "„Home-Verzeichnis“: 3 Dateien nicht lesbar")

        let damaged = Fixture.check(status: .failed, at: Fixture.date(2026, 10, 12, 4, 0), errorCount: 3)
        let errors = text.headline(for: Fixture.state(runs: [Fixture.backup(at: lastHour), damaged]))
        #expect(errors == ("Fehler in den Sicherungen auf „Storage Box“", "3 Fehler in Teil 7 von 12"))

        let unreachable = Fixture.check(status: .failed, at: Fixture.date(2026, 10, 14, 13, 10))
        let couldNotRun = text.headline(for: Fixture.state(runs: [Fixture.backup(at: lastHour), unreachable]))
        #expect(couldNotRun == ("Prüfung von „Storage Box“ konnte nicht laufen", "Storage Box nicht erreichbar"))

        let oldCheck = Fixture.check(at: Fixture.date(2026, 9, 28, 4, 0))
        let overdue = text.headline(for: Fixture.state(runs: [Fixture.backup(at: lastHour), oldCheck]))
        #expect(overdue == ("Prüfung von „Storage Box“ überfällig", "Zuletzt geprüft: Mo., 28.09."))
    }

    @Test func aProblemOfThisMacIsTheHeadlineWhenItIsTheOnlyOne() {
        let healthy = [Fixture.backup(at: lastHour)] + Fixture.maintenance()
        let state = Fixture.state(runs: healthy, system: SystemState(opensAtLogin: false))
        #expect(
            text.headline(for: state) == ("Startet nicht automatisch bei der Anmeldung", "Alle Sicherungen aktuell"))
        #expect(text.tooltip(for: state) == "Alle Sicherungen aktuell – startet nicht automatisch bei der Anmeldung")
        #expect(text.headlineSymbol(for: state) == .warning)

        let two = Fixture.state(runs: healthy, system: SystemState(opensAtLogin: false, notifications: .denied))
        #expect(text.headline(for: two).title == "2 Probleme auf diesem Mac")
        #expect(
            text.tooltip(for: two)
                == "Alle Sicherungen aktuell – startet nicht automatisch bei der Anmeldung, Mitteilungen nicht erlaubt")
    }

    @Test func theTooltipAddsProblemsOfThisMacToABackupProblem() {
        let state = Fixture.state(
            runs: [
                Fixture.backup(at: lastHour.addingTimeInterval(-3600)), Fixture.backup(status: .failed, at: lastHour),
            ]
                + Fixture.maintenance(),
            system: SystemState(hasFullDiskAccess: false))
        #expect(
            text.tooltip(for: state) == "Sicherung von „Home-Verzeichnis“ fehlgeschlagen – kein Festplattenvollzugriff")
        #expect(text.tooltip(for: Fixture.state(runs: [Fixture.backup(at: lastHour)])) == "Alle Sicherungen aktuell")
    }

    @Test func problemsOfThisMacSayWhatFixesThem() {
        #expect(text.actionTitle(for: .noFullDiskAccess) == "Festplattenvollzugriff erlauben …")
        #expect(text.consequence(of: .noFullDiskAccess) == "Ohne ihn werden einige Dateien nicht gesichert")
        #expect(text.actionTitle(for: .notOpeningAtLogin) == "Beim Anmelden öffnen …")
        #expect(text.consequence(of: .notOpeningAtLogin) == "Backup-Squirrel startet derzeit nicht automatisch")
        #expect(text.actionTitle(for: .notificationsOff) == "Mitteilungen erlauben …")
        #expect(text.consequence(of: .notificationsOff) == "Probleme werden sonst nur im Menü angezeigt")
    }

    // MARK: Menu rows

    @Test func aHealthyPlanRowSaysOnlyWhenItWasBackedUp() {
        #expect(
            text.summary(of: Fixture.plan(), in: Fixture.state(runs: [Fixture.backup(at: lastHour)]))
                == "Gesichert heute, 13:02")
    }

    @Test func aFailedPlanRowLeadsWithTheReason() {
        let runs = [
            Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 13, 3, 0)),
            Fixture.backup(plan: Fixture.dataID, status: .failed, at: Fixture.date(2026, 10, 14, 3, 0)),
        ]
        #expect(
            text.summary(of: data, in: Fixture.state(plans: [data], runs: runs))
                == "Storage Box nicht erreichbar · zuletzt gesichert gestern, 03:00")
    }

    @Test func anOverduePlanRowCarriesTheCause() {
        let snapshot = Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 11, 3, 0))
        #expect(
            text.summary(of: data, in: Fixture.state(plans: [data], runs: [snapshot]))
                == "Seit 3 Tagen nicht gesichert · kein Versuch seit So., 11.10.")
        let failed = Fixture.backup(plan: Fixture.dataID, status: .failed, at: Fixture.date(2026, 10, 14, 3, 0))
        #expect(
            text.summary(of: data, in: Fixture.state(plans: [data], runs: [snapshot, failed]))
                == "Seit 3 Tagen nicht gesichert · Storage Box nicht erreichbar")
        var external = data
        external.sourceFolders = [URL(fileURLWithPath: "/Volumes/Daten", isDirectory: true)]
        let unplugged = Fixture.state(plans: [external], runs: [snapshot], system: SystemState(mountedVolumes: ["/"]))
        #expect(
            text.summary(of: external, in: unplugged) == "Seit 3 Tagen nicht gesichert · „Daten“ nicht angeschlossen")
    }

    @Test func otherPlanRows() {
        let manual = Fixture.plan(automatic: false)
        #expect(
            text.summary(of: manual, in: Fixture.state(plans: [manual], runs: [Fixture.backup(at: lastHour)]))
                == "Nur manuell · gesichert heute, 13:02")
        #expect(text.summary(of: manual, in: Fixture.state(plans: [manual])) == "Nur manuell · noch nie gesichert")

        let noTarget = Fixture.plan(targetID: nil)
        #expect(text.summary(of: noTarget, in: Fixture.state(plans: [noTarget])) == "Kein Ziel ausgewählt")

        let kuma = Fixture.plan(uptimeKumaPushURL: "https://uptime.example.com/api/push/abc")
        let rejected = Fixture.backup(
            at: lastHour, monitorPush: MonitorPush(sentAt: Fixture.now, failure: .rejected(statusCode: 404)))
        #expect(
            text.summary(of: kuma, in: Fixture.state(plans: [kuma], runs: [rejected]))
                == "Meldung an Uptime Kuma fehlgeschlagen · gesichert heute, 13:02")
    }

    @Test func aPlanRowMentionsACatchUpDuringTheGracePeriod() {
        let state = Fixture.state(
            runs: [Fixture.backup(at: Fixture.date(2026, 10, 14, 8, 2))],
            awakeSince: Fixture.now.addingTimeInterval(-60))
        #expect(text.summary(of: Fixture.plan(), in: state) == "Gesichert heute, 08:02 · wird nachgeholt")
    }

    @Test func targetRows() {
        #expect(
            text.summary(of: Fixture.target(), in: Fixture.state(runs: Fixture.maintenance()))
                == "Geprüft Mo., 12.10. · keine Fehler")
        let old = [Fixture.check(at: Fixture.date(2026, 9, 28, 4, 0))]
        #expect(
            text.summary(of: Fixture.target(), in: Fixture.state(runs: old))
                == "Prüfung überfällig · zuletzt geprüft Mo., 28.09.")
        let damaged = [Fixture.check(status: .failed, at: Fixture.date(2026, 10, 12, 4, 0), errorCount: 1)]
        #expect(
            text.summary(of: Fixture.target(), in: Fixture.state(runs: damaged))
                == "1 Fehler in Teil 7 von 12 · geprüft Mo., 12.10.")
        let unreachable = [
            Fixture.check(at: Fixture.date(2026, 10, 5, 4, 0)),
            Fixture.check(status: .failed, at: Fixture.date(2026, 10, 14, 13, 10)),
        ]
        #expect(
            text.summary(of: Fixture.target(), in: Fixture.state(runs: unreachable))
                == "Storage Box nicht erreichbar · zuletzt geprüft Mo., 05.10.")
        #expect(text.summary(of: Fixture.target(), in: Fixture.state()) == "Noch nicht geprüft")
    }

    @Test func everyMenuRowHasASymbolButOnlyExceptionsAreColoured() {
        #expect(text.menuSymbol(for: PlanHealth.current) == .menuOK)
        #expect(text.menuSymbol(for: PlanHealth.current).rendering == .monochrome)
        #expect(text.menuSymbol(for: PlanHealth.manualOnly) == .menuManualOnly)
        #expect(text.menuSymbol(for: PlanHealth.failed) == .failure)
        #expect(text.menuSymbol(for: PlanHealth.overdue) == .overdue)
        #expect(text.menuSymbol(for: TargetHealth.current) == .menuOK)
        #expect(text.menuSymbol(for: TargetHealth.checkOverdue) == .checkOverdue)
        #expect(StatusSymbol.checkOverdue.name == StatusSymbol.overdue.name)
        #expect(text.sidebarSymbol(for: PlanHealth.manualOnly) == .manualOnly)
        #expect(text.sidebarSymbol(for: PlanHealth.current) == nil)
    }

    // MARK: Window

    @Test func theWindowSubtitleNamesRhythmAndTarget() {
        let state = Fixture.state(plans: [Fixture.plan(), data])
        #expect(text.windowSubtitle(for: Fixture.plan(), in: state) == "Stündlich auf „Storage Box“")
        #expect(text.windowSubtitle(for: data, in: state) == "Täglich um 03:00 auf „Storage Box“")
        let fourHours = Fixture.plan(schedule: .everyHours(4))
        #expect(text.windowSubtitle(for: fourHours, in: state) == "Alle 4 Stunden auf „Storage Box“")
        #expect(text.windowSubtitle(for: Fixture.plan(automatic: false), in: state) == "Nur manuell")
        #expect(text.windowSubtitle(for: Fixture.plan(targetID: nil), in: state) == "Stündlich, kein Ziel ausgewählt")
        #expect(text.windowSubtitle(for: Fixture.target(), in: state) == "Wöchentliche Prüfung")
    }

    @Test func headerOfAHealthyPlan() {
        let header = text.header(for: Fixture.plan(), in: Fixture.state(runs: [Fixture.backup(at: lastHour)]))
        #expect(header.title == "Aktuell")
        #expect(header.symbol == .current)
        #expect(header.details == ["Zuletzt gesichert: heute, 13:02", "Nächste Sicherung: heute, 14:02"])
        #expect(header.buttons.map(\.title) == ["Jetzt sichern"])
        #expect(header.buttons.allSatisfy { !$0.isProminent })
    }

    @Test func aFailedPlanSaysWhatToDoAndWhenItTriesAgain() {
        let failed = Fixture.backup(status: .failed, at: Fixture.date(2026, 10, 14, 13, 10), duration: 30)
        let header = text.header(
            for: Fixture.plan(),
            in: Fixture.state(runs: [Fixture.backup(at: lastHour.addingTimeInterval(-3600)), failed]))
        #expect(header.title == "Sicherung fehlgeschlagen")
        #expect(header.message == "Storage Box nicht erreichbar. Netzwerk prüfen – neuer Versuch heute, 13:25.")
        #expect(header.details == ["Zuletzt gesichert: heute, 12:02"])
        #expect(header.buttons.map(\.action) == [.showRun(failed.id), .start(.backup(Fixture.homeID))])
        #expect(header.buttons.filter(\.isProminent).map(\.title) == ["Erneut versuchen"])
    }

    @Test func aRetryAlwaysNamesTheDay() {
        let failed = Fixture.backup(status: .failed, at: Fixture.date(2026, 10, 14, 13, 10), duration: 30)
        let status = StatusEvaluator(calendar: Fixture.calendar, home: Fixture.home).status(
            of: Fixture.plan(), in: Fixture.state(runs: [failed]))
        #expect(text.nextRunLine(status.nextRun!, Fixture.state()) == "Neuer Versuch: heute, 13:25")
    }

    @Test func anOverduePlanSaysWhenItIsCaughtUp() {
        var external = data
        external.sourceFolders = [URL(fileURLWithPath: "/Volumes/Daten", isDirectory: true)]
        let runs = [Fixture.backup(plan: Fixture.dataID, at: Fixture.date(2026, 10, 11, 3, 0))]
        let unplugged = Fixture.state(plans: [external], runs: runs, system: SystemState(mountedVolumes: ["/"]))
        let header = text.header(for: external, in: unplugged)
        #expect(header.title == "Seit 3 Tagen nicht gesichert")
        #expect(header.symbol == .overdue)
        #expect(header.message == "Das Volume „Daten“ ist nicht angeschlossen.")
        #expect(
            header.details == [
                "Wird nachgeholt, sobald „Daten“ angeschlossen ist", "Zuletzt gesichert: So., 11.10., 03:00",
            ])
        #expect(header.buttons.allSatisfy { !$0.isProminent })

        let idle = text.header(for: data, in: Fixture.state(plans: [data], runs: runs))
        #expect(idle.message == "Kein Versuch seit So., 11.10.")
        #expect(idle.details.first == "Wird jetzt nachgeholt")
        let busy = text.header(
            for: data,
            in: Fixture.state(
                plans: [Fixture.plan(), data], runs: runs + [Fixture.backup(status: .running, at: Fixture.now)]))
        #expect(busy.details.first == "Wird nachgeholt, sobald „Home-Verzeichnis“ fertig ist")
    }

    @Test func aRejectedPushOffersToEditTheURLAndToReportAgain() {
        let kuma = Fixture.plan(uptimeKumaPushURL: "https://uptime.example.com/api/push/abc")
        let rejected = Fixture.backup(
            at: lastHour, monitorPush: MonitorPush(sentAt: Fixture.now, failure: .rejected(statusCode: 404)))
        let header = text.header(for: kuma, in: Fixture.state(plans: [kuma], runs: [rejected]))
        #expect(header.title == "Meldung an Uptime Kuma fehlgeschlagen")
        #expect(header.message == "Uptime Kuma kennt diese Push-URL nicht (HTTP 404). Push-URL prüfen.")
        #expect(header.buttons.map(\.title) == ["Push-URL bearbeiten", "Erneut melden"])
    }

    @Test func unreadableFilesLeadToTheFiles() {
        let run = Fixture.backup(
            status: .warning, at: lastHour, statistics: BackupStatistics(unreadableFiles: ["/a", "/b"]))
        let header = text.header(for: Fixture.plan(), in: Fixture.state(runs: [run]))
        #expect(header.title == "2 Dateien nicht lesbar")
        #expect(
            header.buttons.first == StatusHeader.Button(action: .showUnreadableFiles(run.id), title: "Dateien anzeigen")
        )
        let home = Fixture.plan(sourceFolders: [Fixture.home])
        let blocked = text.header(
            for: home, in: Fixture.state(plans: [home], runs: [run], system: SystemState(hasFullDiskAccess: false)))
        #expect(blocked.message == "Ohne Festplattenvollzugriff kann Backup-Squirrel sie nicht lesen.")
    }

    @Test func headerOfAManualRunningAndIncompletePlan() {
        let manual = Fixture.plan(automatic: false)
        let manualHeader = text.header(
            for: manual, in: Fixture.state(plans: [manual], runs: [Fixture.backup(at: lastHour)]))
        #expect(manualHeader.title == "Nur manuell")
        #expect(manualHeader.details == ["Zuletzt gesichert: heute, 13:02"])

        let running = text.header(
            for: Fixture.plan(),
            in: Fixture.state(
                runs: [Fixture.backup(at: lastHour), Fixture.backup(status: .running, at: Fixture.now)],
                progress: Fixture.progress()))
        #expect(running.title == "Wird gesichert – 43 %")
        #expect(running.isRunning)
        #expect(running.buttons.map(\.action) == [.cancel])
        #expect(running.progressDetail == "12.345 von 28.901 Dateien · noch ca. 18 Min.")

        let noTarget = Fixture.plan(targetID: nil)
        let incomplete = text.header(for: noTarget, in: Fixture.state(plans: [noTarget]))
        #expect(incomplete.title == "Kein Ziel ausgewählt")
        #expect(incomplete.message == "Unter „Ziel und Zeitplan“ ein Ziel auswählen.")
        #expect(incomplete.details == ["Zuletzt gesichert: noch nie"])
        #expect(incomplete.symbol == .warning)
    }

    @Test func headerOfAHealthyTarget() {
        let header = text.header(for: Fixture.target(), in: Fixture.state(runs: Fixture.maintenance()))
        #expect(header.title == "Keine Fehler gefunden")
        #expect(header.details == ["Teil 7 von 12 geprüft am Mo., 12.10.", "Nächste Prüfung: Mo., 19.10."])
        #expect(header.buttons.map(\.action) == [.start(.check(Fixture.targetID))])
    }

    @Test func headersOfTargetProblems() {
        let lastCheck = Fixture.check(at: Fixture.date(2026, 9, 28, 4, 0), subset: 5)
        let cancelled = Fixture.check(status: .cancelled, at: Fixture.date(2026, 10, 12, 4, 0))
        let overdue = text.header(for: Fixture.target(), in: Fixture.state(runs: [lastCheck, cancelled]))
        #expect(overdue.title == "Prüfung überfällig")
        #expect(overdue.symbol == .checkOverdue)
        #expect(overdue.message == "Letzter Versuch: Mo., 12.10. – abgebrochen.")
        #expect(overdue.details == ["Wird jetzt nachgeholt", "Zuletzt geprüft: Mo., 28.09."])
        let neverTried = text.header(for: Fixture.target(), in: Fixture.state(runs: [lastCheck]))
        #expect(neverTried.message == "Seit Mo., 28.09. kein Prüfversuch.")

        let damaged = Fixture.check(status: .failed, at: Fixture.date(2026, 10, 12, 4, 0), errorCount: 3)
        let errors = text.header(for: Fixture.target(), in: Fixture.state(runs: [damaged]))
        #expect(errors.title == "Fehler in den Sicherungen gefunden")
        #expect(errors.message?.hasPrefix("3 Fehler in Teil 7 von 12.") == true)
        #expect(errors.buttons.filter(\.isProminent).map(\.title) == ["Erneut prüfen"])

        let unreachable = Fixture.check(status: .failed, at: Fixture.date(2026, 10, 14, 13, 10))
        let couldNotRun = text.header(for: Fixture.target(), in: Fixture.state(runs: [lastCheck, unreachable]))
        #expect(couldNotRun.title == "Prüfung konnte nicht laufen")
        #expect(couldNotRun.message == "Storage Box nicht erreichbar. Netzwerk prüfen – neuer Versuch heute, 13:28.")
        #expect(couldNotRun.details == ["Zuletzt geprüft: Mo., 28.09."])
    }
}
