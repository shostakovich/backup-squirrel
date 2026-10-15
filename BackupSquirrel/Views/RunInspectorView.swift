import AppKit
import SwiftUI

struct RunInspectorView: View {
    private static let unreadableFilesID = "unreadableFiles"

    let model: AppModel
    let router: WindowRouter
    let run: Run
    let state: BackupState
    @State private var isUnreadableExpanded = true
    @State private var isOutputExpanded = false

    private var dates: RelativeDateText { RelativeDateText(calendar: model.calendar) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 5) {
                        row("Status", RunText.title(of: run))
                        row(run.planID == nil ? "Ziel" : "Plan", RunText.subject(of: run, in: state))
                        row("Gestartet", dates.standalone(for: run.startedAt, now: state.now))
                        if let finishedAt = run.finishedAt, let duration = run.duration {
                            row("Beendet", dates.standalone(for: finishedAt, now: state.now))
                            row("Dauer", GermanFormat.preciseDuration(duration))
                        }
                        if run.status == .failed, run.couldNotRun {
                            row("Fehler", RunText.failureSentence(of: run, in: state), isPrimary: true)
                        }
                        result
                    }
                    unreadableFiles
                        .id(Self.unreadableFilesID)
                    DisclosureGroup("restic-Ausgabe", isExpanded: $isOutputExpanded) {
                        Text(run.output.isEmpty ? "Keine Ausgabe" : run.output)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(run.output.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                guard router.revealsUnreadableFiles else { return }
                isUnreadableExpanded = true
                proxy.scrollTo(Self.unreadableFilesID, anchor: .top)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusSymbolView(symbol: RunText.symbol(for: run.status))
                .font(.system(size: 24))
            VStack(alignment: .leading, spacing: 1) {
                Text(RunText.heading(of: run, in: state))
                    .font(.headline)
                Text(
                    [
                        dates.standalone(for: run.startedAt, now: state.now),
                        run.duration.map { "Dauer \(GermanFormat.duration($0))" },
                    ]
                    .compactMap { $0 }.joined(separator: " · ")
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String, isPrimary: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .foregroundStyle(isPrimary ? .primary : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resultHeading: some View {
        GridRow {
            Text("Ergebnis")
                .font(.headline)
                .gridCellColumns(2)
                .padding(.top, 10)
        }
    }

    @ViewBuilder
    private var result: some View {
        switch run.details {
        case .backup(let statistics) where run.producedSnapshot:
            resultHeading
            row("Neu", GermanFormat.count(statistics.filesNew))
            row("Geändert", GermanFormat.count(statistics.filesChanged))
            row("Unverändert", GermanFormat.count(statistics.filesUnmodified))
            row("Hinzugefügt", GermanFormat.bytes(statistics.bytesAdded))
            if let snapshotID = statistics.snapshotID {
                GridRow {
                    Text("Snapshot")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(snapshotID)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        CopyButton(value: snapshotID, help: "Snapshot-ID kopieren")
                            .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                }
            }
            if let push = run.monitorPush {
                row(
                    "Uptime Kuma", push.failure.map(RunText.pushReason) ?? "Gemeldet", isPrimary: push.failure != nil)
            }
        case .check(let statistics) where run.completedCheck:
            resultHeading
            row("Geprüft", RunText.checkSubset(statistics))
            row("Fehler", GermanFormat.count(statistics.errorCount), isPrimary: statistics.errorCount > 0)
        case .prune(let statistics) where run.status == .success:
            resultHeading
            row("Entfernt", RunText.olderBackupsRemoved(statistics.snapshotsRemoved))
            row("Freigegeben", GermanFormat.bytes(statistics.bytesFreed))
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var unreadableFiles: some View {
        if case .backup(let statistics) = run.details, !statistics.unreadableFiles.isEmpty {
            DisclosureGroup(
                "Nicht lesbare Dateien (\(GermanFormat.count(statistics.unreadableFiles.count)))",
                isExpanded: $isUnreadableExpanded
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(statistics.unreadableFiles, id: \.self) { path in
                        unreadableFile(URL(fileURLWithPath: path))
                    }
                    if !state.system.hasFullDiskAccess {
                        VStack(alignment: .leading, spacing: 6) {
                            Label {
                                Text("Ohne Festplattenvollzugriff kann Backup-Squirrel diese Dateien nicht lesen.")
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                StatusSymbolView(symbol: .warning)
                            }
                            Button("Systemeinstellungen öffnen …") { SystemServices.openFullDiskAccessSettings() }
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func unreadableFile(_ url: URL) -> some View {
        let isExcluded = run.planID.flatMap { model.plan($0)?.exclusions.contains(.path(url)) } ?? true
        return VStack(alignment: .leading, spacing: 4) {
            Text(url.lastPathComponent)
            Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if let planID = run.planID {
                    Button(isExcluded ? "Ausgeschlossen" : "Vom Plan ausschließen") {
                        model.exclude(url, fromPlan: planID)
                    }
                    .disabled(isExcluded)
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .help(url.path)
        .contextMenu {
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            if let planID = run.planID {
                Button("Vom Plan ausschließen") { model.exclude(url, fromPlan: planID) }
                    .disabled(isExcluded)
            }
        }
    }
}
