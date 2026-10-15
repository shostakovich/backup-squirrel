import Foundation

enum MenuAction: Hashable, Sendable {
    case backUp(Plan.ID)
    case backUpAll
    case cancelRun
    case showPlan(Plan.ID)
    case showTarget(Target.ID)
    case showHistory
    case showRun(Run.ID)
    case showPlansAndTargets
    case setUp
    case fix(SystemProblem)
    case quit
}

struct MenuEntry: Hashable, Sendable {
    enum Role: Hashable, Sendable {
        case status
        case header
        case item
        case separator
    }

    var id: String
    var role: Role
    var title = ""
    var subtitle: String?
    var symbol: StatusSymbol?
    var isEnabled = true
    /// Always combined with the command key.
    var keyEquivalent = ""
    var action: MenuAction?
    var children: [MenuEntry] = []

    static func separator(_ id: String) -> MenuEntry {
        MenuEntry(id: id, role: .separator, isEnabled: false)
    }

    static func header(_ id: String, _ title: String) -> MenuEntry {
        MenuEntry(id: id, role: .header, title: title, isEnabled: false)
    }

    /// Entries with the same shape can be updated in place while the menu is open.
    var shape: [String] {
        [id] + children.flatMap(\.shape)
    }
}

struct StatusMenu {
    let calendar: Calendar
    var home: URL?

    init(calendar: Calendar, home: URL? = nil) {
        self.calendar = calendar
        self.home = home
    }

    /// Items are disabled rather than hidden, so a run starting or ending changes no item but the texts.
    func entries(for state: BackupState) -> [MenuEntry] {
        let text = StatusText(calendar: calendar, home: home)
        let evaluator = text.evaluator
        let headline = text.headline(for: state)
        let setupGap = evaluator.setupGap(in: state)
        let firstProblem = state.activeRun == nil ? evaluator.problems(in: state).first : nil
        var entries: [MenuEntry] = [
            MenuEntry(
                id: "status",
                role: .status,
                title: headline.title,
                subtitle: headline.subtitle,
                symbol: text.headlineSymbol(for: state),
                isEnabled: firstProblem != nil,
                action: firstProblem.map { problem in
                    switch problem.subject {
                    case .plan(let id): .showPlan(id)
                    case .target(let id): .showTarget(id)
                    }
                }
            )
        ]
        for problem in evaluator.systemProblems(in: state) {
            entries.append(
                MenuEntry(
                    id: "system.\(problem)",
                    role: .item,
                    title: text.actionTitle(for: problem),
                    subtitle: text.consequence(of: problem),
                    symbol: .warning,
                    action: .fix(problem)
                )
            )
        }
        if setupGap != nil {
            entries.append(.separator("setup.separator"))
            entries.append(MenuEntry(id: "setup", role: .item, title: "Backup-Squirrel einrichten …", action: .setUp))
        }

        if !state.plans.isEmpty {
            entries.append(.separator("plans.separator"))
            entries.append(.header("plans.header", "Pläne"))
            for plan in state.plans {
                entries.append(
                    MenuEntry(
                        id: "plan.\(plan.id)",
                        role: .item,
                        title: plan.name,
                        subtitle: text.summary(of: plan, in: state),
                        symbol: text.menuSymbol(for: evaluator.status(of: plan, in: state).health),
                        action: .showPlan(plan.id)
                    )
                )
            }
        }
        if !state.targets.isEmpty {
            if state.plans.isEmpty { entries.append(.separator("targets.separator")) }
            entries.append(.header("targets.header", "Ziele"))
            for target in state.targets {
                entries.append(
                    MenuEntry(
                        id: "target.\(target.id)",
                        role: .item,
                        title: target.name,
                        subtitle: text.summary(of: target, in: state),
                        symbol: text.menuSymbol(for: evaluator.status(of: target, in: state).health),
                        action: .showTarget(target.id)
                    )
                )
            }
        }

        entries.append(.separator("actions.separator"))
        entries.append(backUpEntry(for: state))
        entries.append(
            MenuEntry(
                id: "cancel",
                role: .item,
                title: "\(RunText.title(of: state.activeRun?.kind ?? .backup)) abbrechen",
                isEnabled: state.activeRun != nil,
                keyEquivalent: ".",
                action: .cancelRun
            ))
        entries += [
            .separator("window.separator"),
            MenuEntry(id: "plansAndTargets", role: .item, title: "Pläne und Ziele", action: .showPlansAndTargets),
            MenuEntry(id: "history", role: .item, title: "Verlauf anzeigen", action: .showHistory),
            .separator("quit.separator"),
            MenuEntry(id: "quit", role: .item, title: "Backup-Squirrel beenden", keyEquivalent: "q", action: .quit),
        ]
        return entries
    }

    private func backUpEntry(for state: BackupState) -> MenuEntry {
        let isIdle = state.activeRun == nil
        let runnable = state.plans.filter {
            state.target($0.targetID) != nil && !$0.sourceFolders.isEmpty
        }
        let isAvailable: (Plan) -> Bool = { isIdle && state.system.missingVolume(for: $0.sourceFolders) == nil }
        if runnable.count == 1, let plan = runnable.first {
            return MenuEntry(
                id: "backup", role: .item, title: "Jetzt sichern", isEnabled: isAvailable(plan),
                action: .backUp(plan.id))
        }
        var children = runnable.map { plan in
            MenuEntry(
                id: "backup.\(plan.id)", role: .item, title: plan.name, isEnabled: isAvailable(plan),
                action: .backUp(plan.id))
        }
        if runnable.count > 1 {
            children.append(.separator("backup.separator"))
            children.append(
                MenuEntry(id: "backup.all", role: .item, title: "Alle Pläne", isEnabled: isIdle, action: .backUpAll))
        }
        return MenuEntry(
            id: "backup", role: .item, title: "Jetzt sichern", isEnabled: isIdle && !runnable.isEmpty,
            children: children)
    }
}
