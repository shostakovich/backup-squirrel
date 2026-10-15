import SwiftUI

struct SidebarView: View {
    let model: AppModel
    @Bindable var router: WindowRouter
    @State private var nameBeforeRenaming = ""
    @FocusState private var renameFocus: SidebarItem?

    var body: some View {
        let state = model.state
        let text = StatusText(calendar: model.calendar)
        List(selection: $router.selection) {
            Label("Verlauf", systemImage: "clock.arrow.circlepath")
                .tag(SidebarItem.history)

            Section {
                ForEach(model.plans) { plan in
                    row(
                        .plan(plan.id), name: plan.name, systemImage: "folder",
                        trailing: trailing(
                            text.sidebarSymbol(for: text.evaluator.status(of: plan, in: state).health), state)
                    )
                }
                if model.plans.isEmpty { placeholder("Noch kein Plan") }
            } header: {
                sectionHeader("Pläne", addTitle: "Neuer Plan", add: addPlan)
            }

            Section {
                ForEach(model.targets) { target in
                    row(
                        .target(target.id), name: target.name, systemImage: "externaldrive.connected.to.line.below",
                        trailing: trailing(
                            text.sidebarSymbol(for: text.evaluator.status(of: target, in: state).health), state)
                    )
                }
                if model.targets.isEmpty { placeholder("Noch kein Ziel") }
            } header: {
                sectionHeader("Ziele", addTitle: "Neues Ziel …", add: addTarget)
            }
        }
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if let item = items.first, items.count == 1 { contextMenu(for: item) }
        } primaryAction: { items in
            if let item = items.first, items.count == 1 { beginRenaming(item) }
        }
        .onDeleteCommand {
            if let selection = router.selection, selection != .history { router.pendingDeletion = selection }
        }
        .onChange(of: renameFocus) { _, focus in
            if focus == nil { endRenaming() }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { router.pendingDeletion != nil }, set: { if !$0 { router.pendingDeletion = nil } }),
            presenting: router.pendingDeletion
        ) { item in
            Button("Löschen", role: .destructive) { delete(item) }
        } message: { item in
            switch item {
            case .plan: Text("Die Sicherungen auf dem Ziel bleiben erhalten.")
            case .target: Text("Pläne mit diesem Ziel haben danach kein Ziel mehr. Das Repository bleibt erhalten.")
            case .history: EmptyView()
            }
        }
    }

    private func row(_ item: SidebarItem, name: String, systemImage: String, trailing: some View) -> some View {
        HStack(spacing: 6) {
            Label {
                if router.renaming == item {
                    TextField("Name", text: nameBinding(for: item))
                        .labelsHidden()
                        .focused($renameFocus, equals: item)
                        .onSubmit { renameFocus = nil }
                        .onAppear {
                            nameBeforeRenaming = name
                            renameFocus = item
                        }
                } else {
                    Text(name)
                }
            } icon: {
                Image(systemName: systemImage)
            }
            Spacer(minLength: 4)
            trailing
        }
        .tag(item)
    }

    @ViewBuilder
    private func trailing(_ symbol: StatusSymbol?, _ state: BackupState) -> some View {
        if symbol == .running {
            ProgressView()
                .controlSize(.small)
                .help(state.progress.map { "Läuft – \(GermanFormat.percent($0.fractionCompleted))" } ?? "Läuft")
        } else if let symbol {
            StatusSymbolView(symbol: symbol)
                .imageScale(.small)
        }
    }

    private func placeholder(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.tertiary)
            .selectionDisabled()
    }

    private func sectionHeader(_ title: String, addTitle: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(addTitle, systemImage: "plus", action: add)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(addTitle)
        }
    }

    @ViewBuilder
    private func contextMenu(for item: SidebarItem) -> some View {
        switch item {
        case .history:
            EmptyView()
        case .plan(let id):
            Button("Jetzt sichern") { model.start(.backup(id)) }
                .disabled(model.plan(id).map { !model.canBackUp($0) } ?? true)
            Button("Umbenennen") { beginRenaming(item) }
            Divider()
            Button("Löschen …", role: .destructive) { router.pendingDeletion = item }
        case .target(let id):
            Button("Jetzt prüfen") { model.start(.check(id)) }
                .disabled(model.isBusy)
            Button("Umbenennen") { beginRenaming(item) }
            Divider()
            Button("Löschen …", role: .destructive) { router.pendingDeletion = item }
        }
    }

    private func addPlan() {
        let id = model.addPlan()
        router.selection = .plan(id)
        router.renaming = .plan(id)
    }

    private func addTarget() {
        router.targetSetup = model.makeTargetSetup()
    }

    private func beginRenaming(_ item: SidebarItem) {
        guard item != .history else { return }
        router.renaming = item
    }

    private func endRenaming() {
        guard let item = router.renaming else { return }
        if name(of: item).trimmingCharacters(in: .whitespaces).isEmpty {
            nameBinding(for: item).wrappedValue = nameBeforeRenaming
        }
        router.renaming = nil
    }

    private func name(of item: SidebarItem) -> String {
        nameBinding(for: item).wrappedValue
    }

    private func nameBinding(for item: SidebarItem) -> Binding<String> {
        switch item {
        case .plan(let id):
            Binding(
                get: { model.plan(id)?.name ?? "" },
                set: { name in model.binding(forPlan: id)?.wrappedValue.name = name })
        case .target(let id):
            Binding(
                get: { model.target(id)?.name ?? "" },
                set: { name in model.binding(forTarget: id)?.wrappedValue.name = name })
        case .history:
            .constant("Verlauf")
        }
    }

    private var deletionTitle: String {
        switch router.pendingDeletion {
        case .plan(let id): "Plan \(GermanFormat.quoted(model.plan(id)?.name ?? "")) löschen?"
        case .target(let id): "Ziel \(GermanFormat.quoted(model.target(id)?.name ?? "")) löschen?"
        case .history, nil: ""
        }
    }

    private func delete(_ item: SidebarItem) {
        switch item {
        case .plan(let id): model.deletePlan(id)
        case .target(let id): model.deleteTarget(id)
        case .history: return
        }
        if router.selection == item { router.selection = .history }
    }
}
