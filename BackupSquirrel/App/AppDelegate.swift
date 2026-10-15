import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let router = WindowRouter()
    private var model: AppModel?
    private var statusItemController: StatusItemController?
    private var notificationController: NotificationController?
    private var mainWindowController: MainWindowController?
    private var mainMenuController: MainMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
            if let path = UserDefaults.standard.string(forKey: "renderSnapshots") {
                SnapshotRenderer(directory: URL(fileURLWithPath: path, isDirectory: true)).renderAll()
                NSApp.terminate(nil)
                return
            }
        #endif

        SystemServices.registerLoginItemIfInstalled()
        let model = Self.makeModel()
        model.startClock()
        self.model = model
        let mainMenuController = MainMenuController { [weak self] in
            self?.windowCommands()
        } perform: { [weak self] command in
            self?.perform(command)
        }
        self.mainMenuController = mainMenuController
        NSApp.mainMenu = MainMenu.make(commands: mainMenuController)
        statusItemController = StatusItemController(model: model) { [weak self] action in
            self?.perform(action)
        }
        notificationController = NotificationController(
            model: model, store: NotifiedAlerts(defaults: .standard),
            perform: { [weak self] action in self?.perform(action) },
            run: { [weak self] command in self?.run(command) })
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated { model?.noteWake() }
        }
        Task {
            await SystemServices.refreshNotificationPermission()
            model.refreshSystem()
        }
        if model.targets.isEmpty { perform(.setUp) }
        #if DEBUG
            if let name = UserDefaults.standard.string(forKey: "openWindow") {
                showWindow(name == "plan" ? model.plans.first.map { .plan($0.id) } : .history)
            }
        #endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let model else { return }
        Task {
            await SystemServices.refreshNotificationPermission()
            model.refreshSystem()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        perform(.showPlansAndTargets)
        return false
    }

    private func perform(_ action: MenuAction) {
        guard let model else { return }
        switch action {
        case .backUp(let planID): model.start(.backup(planID))
        case .backUpAll: model.backUpAllPlans()
        case .cancelRun: model.cancelActiveRun()
        case .showPlan(let planID): showWindow(.plan(planID))
        case .showTarget(let targetID): showWindow(.target(targetID))
        case .showHistory: showWindow(.history)
        case .showRun(let runID):
            router.showRun(runID)
            showWindow(.history)
        case .showPlansAndTargets:
            switch router.selection {
            case .plan, .target: showWindow(router.selection)
            case .history, nil:
                showWindow(model.plans.first.map { .plan($0.id) } ?? model.targets.first.map { .target($0.id) })
            }
        case .setUp: setUp(model)
        case .fix(let problem): SystemServices.fix(problem) { model.refreshSystem() }
        case .quit: NSApp.terminate(nil)
        }
    }

    private func run(_ command: AlertCommand) {
        guard let model else { return }
        switch command {
        case .start(let request): model.request(request)
        case .resendReport(let planID): Task { await model.resendReport(for: planID) }
        }
    }

    private func perform(_ command: WindowCommand) {
        guard let model else { return }
        switch command {
        case .newPlan:
            let id = model.addPlan()
            showWindow(.plan(id))
            router.renaming = .plan(id)
        case .newTarget:
            showWindow(router.selection)
            router.targetSetup = TargetSetup(target: model.makeTargetDraft(), isOnboarding: model.plans.isEmpty)
        case .rename:
            if router.selection != .history { router.renaming = router.selection }
        case .delete:
            if router.selection != .history { router.pendingDeletion = router.selection }
        case .toggleSidebar: router.isSidebarVisible.toggle()
        case .toggleInspector: router.isInspectorPresented.toggle()
        case .backUpNow:
            if case .plan(let id) = router.selection { model.start(.backup(id)) }
        case .checkNow:
            if case .target(let id) = router.selection { model.start(.check(id)) }
        case .cancelRun: model.cancelActiveRun()
        }
    }

    private func windowCommands() -> WindowCommands? {
        guard let model, let window = mainWindowController?.window, window.isVisible else { return nil }
        return WindowCommands(
            selection: router.selection, isSidebarVisible: router.isSidebarVisible,
            isInspectorVisible: router.isInspectorPresented,
            isSheetOpen: router.targetSetup != nil || window.attachedSheet != nil, state: model.state)
    }

    private func setUp(_ model: AppModel) {
        switch StatusEvaluator(calendar: model.calendar).setupGap(in: model.state) {
        case .noTarget:
            showWindow(router.selection)
            if router.targetSetup == nil {
                router.targetSetup = TargetSetup(target: model.makeTargetDraft(), isOnboarding: model.plans.isEmpty)
            }
        case .noPlan:
            let id = model.addPlan()
            showWindow(.plan(id))
            router.renaming = .plan(id)
        case .nothingAutomatic, nil:
            showWindow(model.plans.first.map { .plan($0.id) })
        }
    }

    private func showWindow(_ selection: SidebarItem?) {
        guard let model else { return }
        router.selection = selection
        let controller = mainWindowController ?? MainWindowController(model: model, router: router)
        mainWindowController = controller
        controller.present()
    }

    private static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
    }

    /// A chosen scenario also simulates the state of this Mac; otherwise this Mac is asked.
    private static func makeModel() -> AppModel {
        #if DEBUG
            if let name = UserDefaults.standard.string(forKey: "scenario"),
                let scenario = SampleScenario(rawValue: name)
            {
                return scenario.makeModel()
            }
        #endif
        return SampleScenario.running.makeModel(inspectSystem: SystemServices.inspect)
    }
}
