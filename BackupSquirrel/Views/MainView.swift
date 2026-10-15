import SwiftUI

struct MainView: View {
    let model: AppModel
    @Bindable var router: WindowRouter

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(model: model, router: router)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 780, minHeight: 480)
        .sheet(item: $router.targetSetup) { setup in
            TargetSetupSheet(model: model, router: router, setup: setup)
        }
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            router.isSidebarVisible ? .all : .detailOnly
        } set: { visibility in
            router.isSidebarVisible = visibility != .detailOnly
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch router.selection {
        case .history:
            HistoryView(model: model, router: router)
        case .plan(let id):
            if let plan = model.binding(forPlan: id) {
                PlanDetailView(model: model, router: router, plan: plan)
                    .id(id)
            } else {
                nothingSelected
            }
        case .target(let id):
            if let target = model.binding(forTarget: id) {
                TargetDetailView(model: model, router: router, target: target)
                    .id(id)
            } else {
                nothingSelected
            }
        case nil:
            nothingSelected
        }
    }

    @ViewBuilder
    private var nothingSelected: some View {
        if model.targets.isEmpty {
            ContentUnavailableView {
                Label("Noch nicht eingerichtet", systemImage: "externaldrive.badge.plus")
            } description: {
                Text("Zuerst ein Ziel hinzufügen, zum Beispiel eine Storage Box. Danach folgt der erste Plan.")
            } actions: {
                Button("Backup-Squirrel einrichten …") {
                    router.targetSetup = TargetSetup(target: model.makeTargetDraft(), isOnboarding: model.plans.isEmpty)
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Einrichtung")
        } else if model.plans.isEmpty {
            ContentUnavailableView {
                Label("Noch kein Plan", systemImage: "folder.badge.plus")
            } description: {
                Text("Ein Plan legt fest, welche Ordner wann auf welches Ziel gesichert werden.")
            } actions: {
                Button("Plan hinzufügen") {
                    let id = model.addPlan()
                    router.selection = .plan(id)
                    router.renaming = .plan(id)
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Einrichtung")
        } else {
            ContentUnavailableView {
                Label("Nichts ausgewählt", systemImage: "sidebar.left")
            } description: {
                Text("Einen Plan, ein Ziel oder den Verlauf in der Seitenleiste auswählen.")
            }
            .navigationTitle("Pläne und Ziele")
        }
    }
}
