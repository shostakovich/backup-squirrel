import Foundation

enum WindowCommand: String, CaseIterable, Hashable, Sendable {
    case newPlan
    case newTarget
    case rename
    case delete
    case toggleSidebar
    case toggleInspector
    case backUpNow
    case checkNow
    case cancelRun
}

struct WindowCommands {
    var selection: SidebarItem?
    var isSidebarVisible = true
    var isInspectorVisible = true
    var isSheetOpen = false
    var state: BackupState

    func title(of command: WindowCommand) -> String {
        switch command {
        case .newPlan: "Neuer Plan"
        case .newTarget: "Neues Ziel …"
        case .rename: "Umbenennen"
        case .delete: "Löschen …"
        case .toggleSidebar: isSidebarVisible ? "Seitenleiste ausblenden" : "Seitenleiste einblenden"
        case .toggleInspector: isInspectorVisible ? "Informationen ausblenden" : "Informationen einblenden"
        case .backUpNow: "Jetzt sichern"
        case .checkNow: "Jetzt prüfen"
        case .cancelRun: "\(RunText.title(of: state.activeRun?.kind ?? .backup)) abbrechen"
        }
    }

    func isEnabled(_ command: WindowCommand) -> Bool {
        if isSheetOpen { return false }
        let isIdle = state.activeRun == nil
        switch command {
        case .newPlan, .newTarget, .toggleSidebar:
            return true
        case .rename, .delete:
            return selection != nil && selection != .history
        case .toggleInspector:
            return selection == .history
        case .backUpNow:
            guard case .plan(let id) = selection, let plan = state.plan(id) else { return false }
            return isIdle && state.target(plan.targetID) != nil && !plan.sourceFolders.isEmpty
                && state.system.missingVolume(for: plan.sourceFolders) == nil
        case .checkNow:
            guard case .target(let id) = selection else { return false }
            return isIdle && state.target(id) != nil
        case .cancelRun:
            return !isIdle
        }
    }
}
