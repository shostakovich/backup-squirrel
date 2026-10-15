import SwiftUI

struct PlanDetailView: View {
    private enum Frequency: Hashable {
        case hours(Int)
        case daily
    }

    private enum ExclusionRow: Hashable {
        case exclusion(Exclusion)
        case draft
    }

    private enum FolderChoice {
        case sources
        case exclusions
    }

    let model: AppModel
    let router: WindowRouter
    @Binding var plan: Plan
    @State private var selectedFolders: Set<URL> = []
    @State private var selectedExclusions: Set<ExclusionRow> = []
    @State private var isChoosingFolders = false
    @State private var folderChoice = FolderChoice.sources
    @State private var draftPattern: String?
    @State private var editedPattern: String?
    @FocusState private var isEditingPattern: Bool
    @FocusState private var isEditingPushURL: Bool

    private static let pushURLRow = "pushURL"

    var body: some View {
        let state = model.state
        let text = StatusText(calendar: model.calendar)
        ScrollViewReader { proxy in
            Form {
                SystemProblemsSection(problems: systemProblems(state: state, text: text), text: text) { problem in
                    SystemServices.fix(problem) { model.refreshSystem() }
                }
                Section {
                    StatusHeaderView(header: text.header(for: plan, in: state), isEnabled: isEnabled, perform: perform)
                }
                recentRunsSection(state: state)
                targetAndScheduleSection
                sourceFoldersSection
                exclusionsSection
                uptimeKumaSection(state: state, text: text)
            }
            .formStyle(.grouped)
            .onChange(of: router.editsPushURL, initial: true) { _, edits in
                guard edits else { return }
                router.editsPushURL = false
                withAnimation { proxy.scrollTo(Self.pushURLRow, anchor: .center) }
                isEditingPushURL = true
            }
        }
        .navigationTitle(plan.name)
        .navigationSubtitle(text.windowSubtitle(for: plan, in: state))
        .fileImporter(
            isPresented: $isChoosingFolders,
            allowedContentTypes: [.folder], allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            switch folderChoice {
            case .sources: plan.sourceFolders += urls.filter { !plan.sourceFolders.contains($0) }
            case .exclusions: plan.exclusions += urls.map(Exclusion.path).filter { !plan.exclusions.contains($0) }
            }
        }
    }

    // MARK: Status

    /// Full Disk Access shows only on plans that need it; the other problems concern every automatic plan.
    private func systemProblems(state: BackupState, text: StatusText) -> [SystemProblem] {
        text.evaluator.systemProblems(in: state).filter { problem in
            switch problem {
            case .noFullDiskAccess: text.evaluator.needsFullDiskAccess(plan)
            case .notOpeningAtLogin, .notificationsOff: plan.backsUpAutomatically
            }
        }
    }

    private func isEnabled(_ action: StatusHeader.Action) -> Bool {
        switch action {
        case .start(let request): model.canStart(request)
        case .cancel: model.isBusy
        case .resendReport: !model.reportingPlans.contains(plan.id)
        case .showRun, .showUnreadableFiles, .editPushURL: true
        }
    }

    private func perform(_ action: StatusHeader.Action) {
        switch action {
        case .start(let request): model.start(request)
        case .cancel: model.cancelActiveRun()
        case .showRun(let id): router.showRun(id)
        case .showUnreadableFiles(let id): router.showRun(id, revealingUnreadableFiles: true)
        case .editPushURL: router.editsPushURL = true
        case .resendReport:
            let id = plan.id
            Task { await model.resendReport(for: id) }
        }
    }

    // MARK: Recent runs

    private func recentRunsSection(state: BackupState) -> some View {
        let runs = state.runs.filter { $0.planID == plan.id && $0.status != .running }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(5)
        return RecentRunsSection(
            runs: Array(runs), state: state, calendar: model.calendar, emptyText: "Noch keine Sicherungen",
            showRun: { router.showRun($0) }, showAll: { router.showHistory(of: .plan(plan.id)) })
    }

    // MARK: Source folders

    private var sourceFoldersSection: some View {
        Section {
            EmbeddedList(
                values: plan.sourceFolders, selection: $selectedFolders, emptyText: "Noch keine Ordner ausgewählt",
                remove: removeFolders
            ) { folder in
                FileRow(url: folder)
            }
            AddRemoveBar(canRemove: !selectedFolders.isEmpty, remove: { removeFolders(selectedFolders) }) {
                Button("Ordner hinzufügen …", systemImage: "plus") { chooseFolders(for: .sources) }
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 18)
                    .help("Ordner hinzufügen …")
            }
        } header: {
            Text("Quellordner")
        }
    }

    private func chooseFolders(for choice: FolderChoice) {
        folderChoice = choice
        isChoosingFolders = true
    }

    private func removeFolders(_ folders: Set<URL>) {
        plan.sourceFolders.removeAll { folders.contains($0) }
        selectedFolders.subtract(folders)
    }

    // MARK: Exclusions

    private var exclusionRows: [ExclusionRow] {
        plan.exclusions.map(ExclusionRow.exclusion) + (draftPattern == nil ? [] : [.draft])
    }

    private var exclusionsSection: some View {
        Section {
            EmbeddedList(
                values: exclusionRows, selection: $selectedExclusions, emptyText: "Keine Ausschlüsse",
                remove: removeExclusions, primaryAction: beginEditing
            ) { row in
                exclusionRow(row)
            }
            AddRemoveBar(canRemove: !selectedExclusions.isEmpty, remove: { removeExclusions(selectedExclusions) }) {
                Menu {
                    Button("Ordner auswählen …") { chooseFolders(for: .exclusions) }
                    Button("Muster hinzufügen") { beginDraft() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .frame(width: 22, height: 18)
                .help("Ausschluss hinzufügen")
            }
        } header: {
            Text("Ausschlüsse")
        } footer: {
            Text("Muster wie bei „restic --exclude“, zum Beispiel *.tmp oder node_modules.")
        }
    }

    @ViewBuilder
    private func exclusionRow(_ row: ExclusionRow) -> some View {
        switch row {
        case .exclusion(.path(let url)):
            FileRow(url: url)
        case .exclusion(.pattern(let pattern)):
            PatternRow {
                if editedPattern == pattern {
                    patternField(text: Binding(get: { editedPattern ?? "" }, set: { editedPattern = $0 })) {
                        commitEdit(of: pattern)
                    }
                } else {
                    Text(pattern)
                        .font(.callout.monospaced())
                }
            }
        case .draft:
            PatternRow {
                patternField(
                    text: Binding(get: { draftPattern ?? "" }, set: { draftPattern = $0 }), commit: commitDraft)
            }
        }
    }

    private func patternField(text: Binding<String>, commit: @escaping () -> Void) -> some View {
        TextField("Muster", text: text, prompt: Text(verbatim: "*.tmp"))
            .labelsHidden()
            .font(.callout.monospaced())
            .focused($isEditingPattern)
            .onSubmit(commit)
            .onChange(of: isEditingPattern) { _, isFocused in
                if !isFocused { commit() }
            }
            .onAppear { isEditingPattern = true }
    }

    private func beginDraft() {
        editedPattern = nil
        draftPattern = ""
    }

    private func beginEditing(_ row: ExclusionRow) {
        guard case .exclusion(.pattern(let pattern)) = row else { return }
        draftPattern = nil
        editedPattern = pattern
    }

    private func commitDraft() {
        guard let draft = draftPattern else { return }
        let pattern = draft.trimmingCharacters(in: .whitespaces)
        if !pattern.isEmpty, !plan.exclusions.contains(.pattern(pattern)) {
            plan.exclusions.append(.pattern(pattern))
        }
        draftPattern = nil
    }

    private func commitEdit(of original: String) {
        guard let edited = editedPattern else { return }
        let pattern = edited.trimmingCharacters(in: .whitespaces)
        if let index = plan.exclusions.firstIndex(of: .pattern(original)) {
            if pattern.isEmpty {
                plan.exclusions.remove(at: index)
            } else if pattern == original || !plan.exclusions.contains(.pattern(pattern)) {
                plan.exclusions[index] = .pattern(pattern)
            }
        }
        editedPattern = nil
    }

    private func removeExclusions(_ rows: Set<ExclusionRow>) {
        for row in rows {
            switch row {
            case .exclusion(let exclusion): plan.exclusions.removeAll { $0 == exclusion }
            case .draft: draftPattern = nil
            }
        }
        selectedExclusions.subtract(rows)
    }

    // MARK: Target and schedule

    private var targetAndScheduleSection: some View {
        Section {
            Picker("Ziel", selection: $plan.targetID) {
                Text("Kein Ziel").tag(Target.ID?.none)
                ForEach(model.targets) { target in
                    Text(target.name).tag(Target.ID?.some(target.id))
                }
            }
            LabeledContent("Automatisch sichern") {
                Toggle("Automatisch sichern", isOn: $plan.backsUpAutomatically)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            Group {
                Picker("Häufigkeit", selection: frequency) {
                    ForEach(Schedule.intervalHours, id: \.self) { hours in
                        Text(hours == 1 ? "Stündlich" : "Alle \(hours) Stunden").tag(Frequency.hours(hours))
                    }
                    Text("Täglich").tag(Frequency.daily)
                }
                if case .daily = plan.schedule {
                    DatePicker("Uhrzeit", selection: dailyTime, displayedComponents: .hourAndMinute)
                }
            }
            .disabled(!plan.backsUpAutomatically)
        } header: {
            Text("Ziel und Zeitplan")
        } footer: {
            Text(
                "Sichert im gewählten Rhythmus, solange Backup-Squirrel läuft. Verpasste Sicherungen werden nachgeholt."
            )
        }
    }

    private var frequency: Binding<Frequency> {
        Binding {
            switch plan.schedule {
            case .everyHours(let hours): .hours(hours)
            case .daily: .daily
            }
        } set: { frequency in
            switch frequency {
            case .hours(let hours): plan.schedule = .everyHours(hours)
            case .daily:
                if case .everyHours = plan.schedule { plan.schedule = .daily(at: TimeOfDay(hour: 3, minute: 0)) }
            }
        }
    }

    private var dailyTime: Binding<Date> {
        let calendar = model.calendar
        return Binding {
            guard case .daily(let time) = plan.schedule else { return model.now }
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: model.now) ?? model.now
        } set: { date in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            plan.schedule = .daily(at: TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0))
        }
    }

    // MARK: Uptime Kuma

    private func uptimeKumaSection(state: BackupState, text: StatusText) -> some View {
        let status = text.evaluator.status(of: plan, in: state)
        let dates = RelativeDateText(calendar: model.calendar)
        let threshold = StatusEvaluator.overdueIntervals * plan.schedule.nominalInterval
        return Section {
            TextField(
                "Push-URL", text: $plan.uptimeKumaPushURL,
                prompt: Text(verbatim: "https://uptime.example.com/api/push/…")
            )
            .truncationMode(.middle)
            .focused($isEditingPushURL)
            .help(plan.uptimeKumaPushURL)
            .id(Self.pushURLRow)
            if plan.reportsToUptimeKuma {
                LabeledContent(
                    "Zuletzt gemeldet",
                    value: status.lastReport.map { dates.standalone(for: $0, now: state.now) } ?? "Noch nie")
                if let failure = status.failedReport {
                    Label {
                        Text(RunText.pushReason(failure))
                    } icon: {
                        StatusSymbolView(symbol: .warning)
                    }
                }
            }
        } header: {
            Text("Uptime Kuma")
        } footer: {
            if plan.backsUpAutomatically {
                Text(
                    "Ruft diese URL nach jeder erfolgreichen Sicherung auf. In Uptime Kuma als Intervall mindestens "
                        + "\(GermanFormat.hours(threshold)) (\(GermanFormat.count(Int(threshold))) Sekunden) einstellen."
                )
            } else {
                Text(
                    "Dieser Plan sichert nur manuell. Uptime Kuma meldet deshalb einen Ausfall, sobald das Intervall "
                        + "abläuft.")
            }
        }
    }
}
