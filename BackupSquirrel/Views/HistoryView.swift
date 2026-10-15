import SwiftUI

struct HistoryView: View {
    let model: AppModel
    @Bindable var router: WindowRouter
    @State private var sortOrder = [KeyPathComparator(\HistoryRow.date, order: .reverse)]
    /// A day row, kept apart so the selection can rest on it while arrowing through the table.
    @State private var selectedDayRow: HistoryRow.ID?

    var body: some View {
        let state = model.state
        if state.runs.isEmpty {
            ContentUnavailableView {
                Label("Noch kein Verlauf", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Sicherungen, Prüfungen und Aufräumvorgänge erscheinen hier, sobald sie gelaufen sind.")
            } actions: {
                if model.targets.isEmpty {
                    Button("Backup-Squirrel einrichten …") {
                        router.targetSetup = TargetSetup(
                            target: model.makeTargetDraft(), isOnboarding: model.plans.isEmpty)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Verlauf")
        } else {
            history(state: state)
        }
    }

    private func history(state: BackupState) -> some View {
        let filter = router.historyFilter
        let ascending = sortOrder.first?.order == .forward
        let runs = filter.apply(to: state.runs).sorted {
            ascending ? $0.startedAt < $1.startedAt : $0.startedAt > $1.startedAt
        }
        let calendar = model.calendar
        let daysWithRuns = Set(
            HistoryFilter(scope: filter.scope).apply(to: state.runs).map { calendar.startOfDay(for: $0.startedAt) })
        let days = HistoryDay.group(
            runs, calendar: calendar, now: state.now, dueSince: filter.dueSince(plans: state.plans),
            daysWithRuns: daysWithRuns)
        return table(days: days, state: state)
            .overlay {
                if runs.isEmpty {
                    ContentUnavailableView {
                        Label("Keine passenden Einträge", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Für diesen Filter gibt es keine Einträge im Verlauf.")
                    } actions: {
                        Button("Filter zurücksetzen") { router.historyFilter = HistoryFilter() }
                    }
                }
            }
            .navigationTitle("Verlauf")
            .navigationSubtitle(subtitle(shown: runs.count, total: state.runs.count))
            .toolbar {
                ToolbarItem {
                    filterMenu
                }
            }
            .inspector(isPresented: $router.isInspectorPresented) {
                Group {
                    if let run = state.runs.first(where: { $0.id == router.selectedRunID }) {
                        RunInspectorView(model: model, router: router, run: run, state: state)
                            .id(run.id)
                    } else if let day = days.first(where: { HistoryRow.day($0).id == selectedDayRow }),
                        day.runs.isEmpty
                    {
                        ContentUnavailableView(
                            "Keine Läufe", systemImage: "moon.zzz",
                            description: Text(
                                "An diesem Tag lief nichts, obwohl ein Plan fällig war. Der Mac war ausgeschaltet "
                                    + "oder schlief, oder Backup-Squirrel lief nicht."))
                    } else {
                        ContentUnavailableView(
                            "Kein Eintrag ausgewählt", systemImage: "list.bullet.rectangle",
                            description: Text("Einen Eintrag auswählen, um Details und die restic-Ausgabe zu sehen."))
                    }
                }
                .inspectorColumnWidth(min: 290, ideal: 300, max: 520)
                .toolbar {
                    Button {
                        router.isInspectorPresented.toggle()
                    } label: {
                        Label("Informationen", systemImage: "sidebar.trailing")
                    }
                    .help(router.isInspectorPresented ? "Informationen ausblenden" : "Informationen einblenden")
                }
            }
    }

    /// Writes only real changes, so the table never reloads from inside its own delegate call.
    private var selection: Binding<HistoryRow.ID?> {
        Binding {
            selectedDayRow ?? router.selectedRunID?.uuidString
        } set: { id in
            let runID = id.flatMap(UUID.init(uuidString:))
            let dayRow = runID == nil ? id : nil
            if dayRow != selectedDayRow { selectedDayRow = dayRow }
            guard runID != router.selectedRunID else { return }
            router.selectedRunID = runID
            router.revealsUnreadableFiles = false
        }
    }

    /// Grouped by day, so the time column only needs the time.
    private func table(days: [HistoryDay], state: BackupState) -> some View {
        let dates = RelativeDateText(calendar: model.calendar)
        return Table(of: HistoryRow.self, selection: selection, sortOrder: $sortOrder) {
            TableColumn("") { row in
                if let run = row.run, let symbol = RunText.listSymbol(for: run.status) {
                    StatusSymbolView(symbol: symbol)
                }
            }
            .width(18)
            TableColumn("Zeit", value: \.date) { row in
                switch row {
                case .day(let day):
                    Text(day.title)
                        .fontWeight(.semibold)
                case .run(let run):
                    Text(dates.time(run.startedAt))
                        .monospacedDigit()
                }
            }
            .width(min: 76, ideal: 80, max: 120)
            TableColumn("Vorgang") { row in
                switch row {
                case .day(let day):
                    if day.runs.isEmpty {
                        Text("Keine Läufe")
                            .foregroundStyle(.secondary)
                    }
                case .run(let run):
                    Text(RunText.operation(of: run, in: state))
                }
            }
            .width(min: 205, ideal: 215, max: 300)
            TableColumn("Ergebnis") { row in
                if let run = row.run {
                    Text(RunText.summary(of: run, in: state))
                        .foregroundStyle(.secondary)
                        .help(RunText.fullSummary(of: run, in: state))
                }
            }
            TableColumn("Dauer") { row in
                Text(row.run?.duration.map(GermanFormat.duration) ?? "")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 56, max: 80)
        } rows: {
            ForEach(days.flatMap(\.rows)) { row in
                TableRow(row)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Plan oder Ziel", selection: $router.historyFilter.scope) {
                Text("Alle Pläne und Ziele").tag(HistoryScope.all)
                ForEach(model.plans) { plan in
                    Text(plan.name).tag(HistoryScope.plan(plan.id))
                }
                ForEach(model.targets) { target in
                    Text(target.name).tag(HistoryScope.target(target.id))
                }
            }
            .pickerStyle(.inline)
            Picker("Vorgang", selection: $router.historyFilter.kind) {
                Text("Alle Vorgänge").tag(RunKind?.none)
                ForEach(RunKind.allCases, id: \.self) { kind in
                    Text(RunText.title(of: kind)).tag(RunKind?.some(kind))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Nur Probleme", isOn: $router.historyFilter.onlyProblems)
            if router.historyFilter.isActive {
                Divider()
                Button("Filter zurücksetzen") { router.historyFilter = HistoryFilter() }
            }
        } label: {
            Label(
                "Filter",
                systemImage: router.historyFilter.isActive
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Verlauf filtern")
    }

    private func subtitle(shown: Int, total: Int) -> String {
        if shown == total { return total == 1 ? "1 Eintrag" : "\(GermanFormat.count(total)) Einträge" }
        return "\(GermanFormat.count(shown)) von \(GermanFormat.count(total)) Einträgen"
    }
}
