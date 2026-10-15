import Foundation
import Observation

enum SidebarItem: Hashable, Sendable {
    case history
    case plan(Plan.ID)
    case target(Target.ID)
}

@MainActor
@Observable
final class WindowRouter {
    var selection: SidebarItem?
    var selectedRunID: Run.ID?
    var isInspectorPresented = true
    var isSidebarVisible = true
    var historyFilter = HistoryFilter()
    var targetSetup: TargetSetup?
    var renaming: SidebarItem?
    var pendingDeletion: SidebarItem?
    /// Set by "Dateien anzeigen", so the inspector opens the list of unreadable files.
    var revealsUnreadableFiles = false
    /// Set by "Push-URL bearbeiten"; the plan page scrolls to the field and focuses it.
    var editsPushURL = false

    init(selection: SidebarItem? = .history) {
        self.selection = selection
    }

    func showRun(_ id: Run.ID, revealingUnreadableFiles: Bool = false) {
        historyFilter = HistoryFilter()
        selection = .history
        selectedRunID = id
        isInspectorPresented = true
        revealsUnreadableFiles = revealingUnreadableFiles
    }

    func showHistory(of scope: HistoryScope) {
        historyFilter = HistoryFilter(scope: scope)
        selection = .history
    }
}
