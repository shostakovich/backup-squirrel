import Foundation
import Testing

@testable import BackupSquirrel

struct StatusMenuTests {
    private let menu = StatusMenu(calendar: Fixture.calendar, home: Fixture.home)
    private let lastHour = Fixture.date(2026, 10, 14, 13, 2)
    private var data: Plan { Fixture.plan(id: Fixture.dataID, name: "Daten") }

    private func entry(_ id: String, in entries: [MenuEntry]) -> MenuEntry? {
        entries.first { $0.id == id }
    }

    @Test func aHealthyHeadlineIsADisabledStatusEntryWithAPlainCheckmark() {
        let entries = menu.entries(for: Fixture.state(runs: [Fixture.backup(at: lastHour)]))
        #expect(entries.first?.role == .status)
        #expect(entries.first?.title == "Alle Sicherungen aktuell")
        #expect(entries.first?.subtitle == "Zuletzt gesichert: heute, 13:05")
        #expect(entries.first?.symbol == .menuOK)
        #expect(entries.first?.isEnabled == false)
        #expect(entries.first?.action == nil)
    }

    @Test func aProblemHeadlineOpensTheAffectedPlan() {
        let runs = [
            Fixture.backup(at: lastHour), Fixture.backup(plan: Fixture.dataID, at: lastHour.addingTimeInterval(-3600)),
            Fixture.backup(plan: Fixture.dataID, status: .failed, at: lastHour),
        ]
        let entries = menu.entries(for: Fixture.state(plans: [Fixture.plan(), data], runs: runs))
        #expect(entries.first?.isEnabled == true)
        #expect(entries.first?.action == .showPlan(Fixture.dataID))
        #expect(entries.first?.symbol == .failure)
    }

    @Test func notSetUpOffersTheSetUpInAGroupOfItsOwn() {
        let entries = menu.entries(for: Fixture.state(plans: [], targets: []))
        #expect(entries.first?.title == "Nicht eingerichtet")
        #expect(entries.first?.symbol == .menuNotSetUp)
        #expect(entries.first?.isEnabled == false)
        #expect(entries.dropFirst().first?.role == .separator)
        #expect(entry("setup", in: entries)?.title == "Backup-Squirrel einrichten …")
        #expect(entry("setup", in: entries)?.action == .setUp)
        #expect(entry("plans.header", in: entries) == nil)
        #expect(entry("backup", in: entries)?.isEnabled == false)
    }

    @Test func problemsOfThisMacAreActionsNamedByWhatFixesThem() {
        let state = Fixture.state(
            plans: [Fixture.plan(sourceFolders: [Fixture.home])], runs: [Fixture.backup(at: lastHour)],
            system: SystemState(hasFullDiskAccess: false, opensAtLogin: false, notifications: .denied))
        let entries = menu.entries(for: state)
        let access = entry("system.noFullDiskAccess", in: entries)
        #expect(access?.title == "Festplattenvollzugriff erlauben …")
        #expect(access?.subtitle == "Ohne ihn werden einige Dateien nicht gesichert")
        #expect(access?.action == .fix(.noFullDiskAccess))
        #expect(access?.symbol == .warning)
        let login = entry("system.notOpeningAtLogin", in: entries)
        #expect(login?.title == "Beim Anmelden öffnen …")
        #expect(login?.subtitle == "Backup-Squirrel startet derzeit nicht automatisch")
        let notifications = entry("system.notificationsOff", in: entries)
        #expect(notifications?.title == "Mitteilungen erlauben …")
        #expect(notifications?.subtitle == "Probleme werden sonst nur im Menü angezeigt")
        #expect(notifications?.action == .fix(.notificationsOff))
    }

    @Test func everyPlanAndTargetRowHasASymbolButOnlyExceptionsAreColoured() {
        let runs = [Fixture.backup(at: lastHour), Fixture.backup(plan: Fixture.dataID, status: .warning, at: lastHour)]
        let entries = menu.entries(for: Fixture.state(plans: [Fixture.plan(), data], runs: runs))
        #expect(entry("plans.header", in: entries)?.title == "Pläne")
        #expect(entry("targets.header", in: entries)?.title == "Ziele")
        let home = entry("plan.\(Fixture.homeID)", in: entries)
        #expect(home?.subtitle == "Gesichert heute, 13:05")
        #expect(home?.symbol == .menuOK)
        #expect(home?.action == .showPlan(Fixture.homeID))
        #expect(entry("plan.\(Fixture.dataID)", in: entries)?.symbol == .warning)
        let target = entry("target.\(Fixture.targetID)", in: entries)
        #expect(target?.action == .showTarget(Fixture.targetID))
        #expect(target?.symbol != nil)
        let rows = entries.filter { $0.id.hasPrefix("plan.") || $0.id.hasPrefix("target.") }
        #expect(rows.allSatisfy { $0.symbol != nil })
    }

    @Test func withOneRunnablePlanBackUpNowIsAPlainItem() {
        let entries = menu.entries(
            for: Fixture.state(plans: [Fixture.plan(), Fixture.plan(id: UUID(), targetID: nil)]))
        let backUp = entry("backup", in: entries)
        #expect(backUp?.children.isEmpty == true)
        #expect(backUp?.action == .backUp(Fixture.homeID))
    }

    @Test func withSeveralRunnablePlansBackUpNowListsThemAndAll() {
        let plans = [
            Fixture.plan(), data, Fixture.plan(id: UUID(), name: "Nur manuell", automatic: false),
            Fixture.plan(id: UUID(), name: "Ohne Ziel", targetID: nil),
        ]
        let children = entry("backup", in: menu.entries(for: Fixture.state(plans: plans)))?.children ?? []
        #expect(children.map(\.title) == ["Home-Verzeichnis", "Daten", "Nur manuell", "", "Alle Pläne"])
        #expect(children.first?.action == .backUp(Fixture.homeID))
        #expect(children.last?.action == .backUpAll)
    }

    @Test func aRunDisablesBackUpNowAndEnablesCancelInsteadOfSwappingThem() {
        let idle = menu.entries(for: Fixture.state(runs: [Fixture.backup(at: lastHour)]))
        #expect(entry("backup", in: idle)?.isEnabled == true)
        #expect(entry("cancel", in: idle)?.isEnabled == false)
        #expect(entry("cancel", in: idle)?.title == "Sicherung abbrechen")

        let running = menu.entries(
            for: Fixture.state(runs: [Fixture.backup(status: .running, at: lastHour)], progress: Fixture.progress()))
        #expect(entry("backup", in: running)?.isEnabled == false)
        let cancel = entry("cancel", in: running)
        #expect(cancel?.isEnabled == true)
        #expect(cancel?.keyEquivalent == ".")
        #expect(cancel?.action == .cancelRun)
        #expect(idle.flatMap(\.shape) == running.flatMap(\.shape))

        let check = menu.entries(for: Fixture.state(runs: [Fixture.check(status: .running, at: Fixture.now)]))
        #expect(entry("cancel", in: check)?.title == "Prüfung abbrechen")
    }

    @Test func aPlanOnADisconnectedVolumeCannotBeBackedUpNow() {
        let external = Fixture.plan(sourceFolders: [URL(fileURLWithPath: "/Volumes/Daten", isDirectory: true)])
        let entries = menu.entries(
            for: Fixture.state(plans: [external], system: SystemState(mountedVolumes: ["/"])))
        #expect(entry("backup", in: entries)?.isEnabled == false)
    }

    @Test func theWindowItemsNameWhatTheyShowAndHaveNoSettingsShortcut() {
        let entries = menu.entries(for: Fixture.state())
        #expect(entry("plansAndTargets", in: entries)?.title == "Pläne und Ziele")
        #expect(entry("plansAndTargets", in: entries)?.keyEquivalent == "")
        #expect(entry("history", in: entries)?.title == "Verlauf anzeigen")
        #expect(!entries.contains { $0.title.hasPrefix("Einstellungen") })
        #expect(entries.last?.title == "Backup-Squirrel beenden")
        #expect(entries.last?.keyEquivalent == "q")
        #expect(entries.last?.action == .quit)
    }

    @Test func progressUpdatesKeepTheMenuShapeSoItCanUpdateInPlace() {
        let runs = [Fixture.backup(status: .running, at: lastHour)]
        let before = menu.entries(for: Fixture.state(runs: runs, progress: Fixture.progress(filesDone: 100)))
        let after = menu.entries(for: Fixture.state(runs: runs, progress: Fixture.progress(filesDone: 200)))
        #expect(before.flatMap(\.shape) == after.flatMap(\.shape))
        #expect(before.first?.subtitle != after.first?.subtitle)
    }
}
