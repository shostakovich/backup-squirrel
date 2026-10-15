import SwiftUI

struct StatusHeaderView: View {
    let header: StatusHeader
    let isEnabled: (StatusHeader.Action) -> Bool
    let perform: (StatusHeader.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                StatusSymbolView(symbol: header.symbol)
                    .font(.system(size: 30))
                    .frame(width: 34, height: 34)
                    .padding(.top, -6)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(header.title)
                            .font(.title3.weight(.semibold))
                        if let message = header.message {
                            Text(message)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(header.details, id: \.self) { detail in
                            Text(detail)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        ForEach(header.buttons, id: \.self) { button in
                            headerButton(button)
                        }
                    }
                    .fixedSize()
                }
            }
            if header.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = header.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    if let detail = header.progressDetail {
                        Text(detail)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func headerButton(_ button: StatusHeader.Button) -> some View {
        if button.isProminent {
            Button(button.title) { perform(button.action) }
                .buttonStyle(.borderedProminent)
                .disabled(!isEnabled(button.action))
        } else {
            Button(button.title) { perform(button.action) }
                .disabled(!isEnabled(button.action))
        }
    }
}

struct SystemProblemsSection: View {
    let problems: [SystemProblem]
    let text: StatusText
    let fix: (SystemProblem) -> Void

    var body: some View {
        if !problems.isEmpty {
            Section {
                ForEach(problems, id: \.self) { problem in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        StatusSymbolView(symbol: .warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(text.title(for: problem))
                            Text(text.detail(for: problem))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button(text.actionTitle(for: problem)) { fix(problem) }
                            .fixedSize()
                    }
                }
            } header: {
                Text("Dieser Mac")
            }
        }
    }
}

struct RecentRunsSection: View {
    let runs: [Run]
    let state: BackupState
    let calendar: Calendar
    let emptyText: String
    let showRun: (Run.ID) -> Void
    let showAll: () -> Void

    var body: some View {
        let dates = RelativeDateText(calendar: calendar)
        Section {
            if runs.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            }
            ForEach(runs) { run in
                Button {
                    showRun(run.id)
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            if let symbol = RunText.listSymbol(for: run.status) {
                                StatusSymbolView(symbol: symbol)
                            }
                        }
                        .frame(width: 16)
                        Text(dates.standalone(for: run.startedAt, now: state.now))
                            .frame(width: 128, alignment: .leading)
                        if state.plans.isEmpty || run.planID == nil {
                            Text(RunText.title(of: run.kind))
                                .frame(width: 72, alignment: .leading)
                        }
                        Text(RunText.summary(of: run, in: state))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(RunText.fullSummary(of: run, in: state))
                        Spacer(minLength: 8)
                        Text(run.duration.map(GermanFormat.duration) ?? "")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Im Verlauf zeigen")
            }
        } header: {
            HStack {
                Text("Letzte Läufe")
                Spacer()
                Button("Alle im Verlauf anzeigen", action: showAll)
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }
}

struct AddRemoveBar<AddButton: View>: View {
    let canRemove: Bool
    let remove: () -> Void
    @ViewBuilder let add: () -> AddButton

    var body: some View {
        HStack(spacing: 2) {
            add()
            Divider()
                .frame(height: 14)
            Button("Entfernen", systemImage: "minus", action: remove)
                .labelStyle(.iconOnly)
                .frame(width: 22, height: 18)
                .disabled(!canRemove)
                .help("Auswahl entfernen")
            Spacer()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

struct EmbeddedList<Value: Hashable, Row: View>: View {
    static var rowHeight: CGFloat { 26 }

    let values: [Value]
    @Binding var selection: Set<Value>
    let emptyText: String
    let remove: (Set<Value>) -> Void
    var primaryAction: ((Value) -> Void)?
    @ViewBuilder let row: (Value) -> Row

    var body: some View {
        if values.isEmpty {
            Text(emptyText)
                .foregroundStyle(.secondary)
        } else {
            List(selection: $selection) {
                ForEach(values, id: \.self) { value in
                    row(value)
                        .frame(height: Self.rowHeight)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .frame(height: CGFloat(values.count) * Self.rowHeight)
            .onDeleteCommand { remove(selection) }
            .contextMenu(forSelectionType: Value.self) { items in
                if !items.isEmpty {
                    Button("Entfernen") { remove(items) }
                }
            } primaryAction: { items in
                if items.count == 1, let item = items.first { primaryAction?(item) }
            }
        }
    }
}
