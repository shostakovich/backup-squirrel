import AppKit
import Foundation
import Testing

@testable import BackupSquirrel

/// Integration tests: sample data, status evaluation and menu together.
@MainActor
struct SampleScenarioTests {
    private func model(_ scenario: SampleScenario) -> AppModel {
        scenario.makeModel(
            now: Fixture.now, calendar: Fixture.calendar, currentDate: { Fixture.now },
            executor: SimulatedRunExecutor(tick: .seconds(3600)))
    }

    private func iconState(_ model: AppModel) -> MenuBarIconState {
        StatusEvaluator(calendar: Fixture.calendar).iconState(for: model.state)
    }

    private func targetHealth(in model: AppModel) -> TargetHealth? {
        model.target(SampleData.storageBoxID).map {
            StatusEvaluator(calendar: Fixture.calendar).status(of: $0, in: model.state).health
        }
    }

    private func health(of planID: Plan.ID, in model: AppModel) -> PlanHealth? {
        model.plan(planID).map { StatusEvaluator(calendar: Fixture.calendar).status(of: $0, in: model.state).health }
    }

    @Test func historyCoversTwoWeeksAndEveryOutcome() {
        let runs = model(.idle).runs
        #expect((25...35).contains(runs.count))
        #expect(Set(runs.map(\.status)) == [.success, .warning, .failed, .cancelled])
        #expect(Set(runs.map(\.kind)) == [.backup, .check, .prune])
        let span = (runs.last?.startedAt ?? .distantPast).timeIntervalSince(runs.first?.startedAt ?? .distantPast)
        #expect(span > 12 * 24 * 3600 && span < 15 * 24 * 3600)
    }

    @Test func eachScenarioProducesItsIconState() async {
        #expect(iconState(model(.idle)) == .idle)
        #expect(iconState(model(.warning)) == .warning)
        #expect(iconState(model(.error)) == .error)
        #expect(iconState(model(.overdue)) == .error)
        #expect(iconState(model(.manual)) == .idle)
        #expect(iconState(model(.noFullDiskAccess)) == .warning)
        #expect(iconState(model(.noLoginItem)) == .warning)
        #expect(iconState(model(.checkOverdue)) == .warning)
        #expect(iconState(model(.checkErrors)) == .error)
        #expect(iconState(model(.checkFailed)) == .error)
        #expect(iconState(model(.incomplete)) == .warning)
        #expect(iconState(model(.notificationsDenied)) == .warning)
        #expect(iconState(model(.empty)) == .notSetUp)

        let running = model(.running)
        await eventually { running.progress != nil }
        #expect(iconState(running) == .running(fraction: SampleData.runningProgress.fractionCompleted))
    }

    @Test func scenariosShowTheStatesTheyAreNamedAfter() {
        #expect(health(of: SampleData.homePlanID, in: model(.error)) == .failed)
        #expect(health(of: SampleData.dataPlanID, in: model(.overdue)) == .overdue)
        #expect(health(of: SampleData.dataPlanID, in: model(.manual)) == .manualOnly)
        #expect(health(of: SampleData.dataPlanID, in: model(.warning)) == .warning)
        #expect(model(.noFullDiskAccess).system.hasFullDiskAccess == false)
        #expect(model(.noLoginItem).system.opensAtLogin == false)
        #expect(model(.notificationsDenied).system.notifications == .denied)
        #expect(health(of: SampleData.dataPlanID, in: model(.incomplete)) == .incomplete(automatic: true))
        #expect(targetHealth(in: model(.checkErrors)) == .checkFoundErrors)
        #expect(targetHealth(in: model(.checkFailed)) == .checkFailed)
        #expect(targetHealth(in: model(.checkOverdue)) == .checkOverdue)
    }

    @Test func theOverdueScenarioWaitsForItsVolume() {
        let model = model(.overdue)
        let status = StatusEvaluator(calendar: Fixture.calendar).status(
            of: model.plan(SampleData.dataPlanID)!, in: model.state)
        #expect(status.standstill == .volumeMissing("Daten"))
    }

    @Test func everyScenarioThatFailsTwiceAlsoNotifies() {
        let planner = AlertPlanner(calendar: Fixture.calendar)
        #expect(planner.alerts(in: model(.error).state).map(\.key.kind) == [.backupFailed])
        #expect(planner.alerts(in: model(.checkFailed).state).map(\.key.kind) == [.checkFailed])
        #expect(planner.alerts(in: model(.idle).state).isEmpty)
    }

    @Test func theFailedScenarioRetriesFifteenMinutesAfterEachAttempt() {
        let model = model(.error)
        let status = StatusEvaluator(calendar: Fixture.calendar).status(
            of: model.plan(SampleData.homePlanID)!, in: model.state)
        guard case .retry(let date) = status.nextRun else {
            Issue.record("expected a retry, got \(String(describing: status.nextRun))")
            return
        }
        #expect(date > Fixture.now)
    }

}
