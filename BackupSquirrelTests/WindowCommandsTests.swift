import Foundation
import Testing

@testable import BackupSquirrel

struct WindowCommandsTests {
    private let idle = Fixture.state(runs: [Fixture.backup(at: Fixture.date(2026, 10, 14, 13, 2))])
    private let running = Fixture.state(runs: [Fixture.backup(status: .running, at: Fixture.now)])

    @Test func backUpNowAndCheckNowFollowTheSelection() {
        let plan = WindowCommands(selection: .plan(Fixture.homeID), state: idle)
        #expect(plan.isEnabled(.backUpNow))
        #expect(!plan.isEnabled(.checkNow))
        let target = WindowCommands(selection: .target(Fixture.targetID), state: idle)
        #expect(!target.isEnabled(.backUpNow))
        #expect(target.isEnabled(.checkNow))
        #expect(!WindowCommands(selection: .history, state: idle).isEnabled(.backUpNow))
    }

    @Test func aRunDisablesStartingAndEnablesCancelling() {
        let commands = WindowCommands(selection: .plan(Fixture.homeID), state: running)
        #expect(!commands.isEnabled(.backUpNow))
        #expect(commands.isEnabled(.cancelRun))
        #expect(commands.title(of: .cancelRun) == "Sicherung abbrechen")
        #expect(!WindowCommands(selection: .plan(Fixture.homeID), state: idle).isEnabled(.cancelRun))
        let check = Fixture.state(runs: [Fixture.check(status: .running, at: Fixture.now)])
        #expect(WindowCommands(selection: .history, state: check).title(of: .cancelRun) == "Prüfung abbrechen")
    }

    @Test func renameAndDeleteNeedAPlanOrTarget() {
        #expect(WindowCommands(selection: .plan(Fixture.homeID), state: idle).isEnabled(.rename))
        #expect(WindowCommands(selection: .target(Fixture.targetID), state: idle).isEnabled(.delete))
        #expect(!WindowCommands(selection: .history, state: idle).isEnabled(.rename))
        #expect(!WindowCommands(selection: nil, state: idle).isEnabled(.delete))
    }

    @Test func viewCommandsSayWhatTheyWillDo() {
        let shown = WindowCommands(selection: .history, state: idle)
        #expect(shown.title(of: .toggleSidebar) == "Seitenleiste ausblenden")
        #expect(shown.title(of: .toggleInspector) == "Informationen ausblenden")
        #expect(shown.isEnabled(.toggleInspector))
        let hidden = WindowCommands(
            selection: .history, isSidebarVisible: false, isInspectorVisible: false, state: idle)
        #expect(hidden.title(of: .toggleSidebar) == "Seitenleiste einblenden")
        #expect(hidden.title(of: .toggleInspector) == "Informationen einblenden")
        #expect(!WindowCommands(selection: .plan(Fixture.homeID), state: idle).isEnabled(.toggleInspector))
    }

    @Test func anOpenSheetDisablesEveryWindowCommand() {
        let commands = WindowCommands(selection: .plan(Fixture.homeID), isSheetOpen: true, state: running)
        #expect(WindowCommand.allCases.allSatisfy { !commands.isEnabled($0) })
    }
}
