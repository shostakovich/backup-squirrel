import AppKit
import SwiftUI

struct TargetDetailView: View {
    let model: AppModel
    let router: WindowRouter
    @Binding var target: Target
    @State private var connectionTest = ConnectionTest.idle
    @State private var isChangingPassword = false
    @State private var isEditingConnection = false

    var body: some View {
        let state = model.state
        let text = StatusText(calendar: model.calendar)
        let status = text.evaluator.status(of: target, in: state)
        Form {
            SystemProblemsSection(
                problems: text.evaluator.systemProblems(in: state).filter { $0 != .noFullDiskAccess }, text: text
            ) { problem in
                SystemServices.fix(problem) { model.refreshSystem() }
            }
            Section {
                StatusHeaderView(header: text.header(for: target, in: state), isEnabled: isEnabled, perform: perform)
            } footer: {
                Text(
                    "Jeden Tag wird ein Teil der gesicherten Daten vom Server gelesen und geprüft. "
                        + "Nach \(CheckStatistics.currentSubsetCount) Tagen ist alles einmal geprüft.")
            }
            recentRunsSection(state: state)
            connectionSection(lastConnection: status.lastConnection, state: state)
            Section {
                Picker("Upload-Limit", selection: uploadLimit) {
                    Text("Unbegrenzt").tag(Int?.none)
                    ForEach(UploadLimit.megabytesPerSecond, id: \.self) { megabytes in
                        Text(GermanFormat.rate(megabytesPerSecond: megabytes))
                            .tag(Int?.some(UploadLimit.kibPerSecond(megabytesPerSecond: megabytes)))
                    }
                }
            } footer: {
                Text("Begrenzt die Bandbreite, die Sicherungen beim Hochladen nutzen.")
            }
            passwordSection
            sshKeySection
        }
        .formStyle(.grouped)
        .navigationTitle(target.name)
        .navigationSubtitle(text.windowSubtitle(for: target, in: state))
        .sheet(isPresented: $isChangingPassword) {
            ChangePasswordSheet { password in await model.changeRepositoryPassword(of: target.id, to: password) }
        }
        .sheet(isPresented: $isEditingConnection) {
            ConnectionEditSheet(target: target) { edited in
                let changed = edited != target
                target = edited
                if changed { testConnection() }
            }
        }
    }

    private func isEnabled(_ action: StatusHeader.Action) -> Bool {
        switch action {
        case .start(let request): model.canStart(request)
        case .cancel: model.isBusy
        case .showRun, .showUnreadableFiles, .editPushURL, .resendReport: true
        }
    }

    private func perform(_ action: StatusHeader.Action) {
        switch action {
        case .start(let request): model.start(request)
        case .cancel: model.cancelActiveRun()
        case .showRun(let id): router.showRun(id)
        case .showUnreadableFiles, .editPushURL, .resendReport: break
        }
    }

    private var uploadLimit: Binding<Int?> {
        Binding {
            UploadLimit.option(for: target.uploadLimitKiBPerSecond)
        } set: { limit in
            target.uploadLimitKiBPerSecond = limit
        }
    }

    // MARK: Recent runs

    private func recentRunsSection(state: BackupState) -> some View {
        let runs = state.runs.filter { $0.targetID == target.id && $0.kind != .backup && $0.status != .running }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(5)
        return RecentRunsSection(
            runs: Array(runs), state: state, calendar: model.calendar, emptyText: "Noch keine Prüfung",
            showRun: { router.showRun($0) },
            showAll: {
                router.historyFilter = HistoryFilter(scope: .target(target.id))
                router.selection = .history
            })
    }

    // MARK: Connection

    private func connectionSection(lastConnection: Date?, state: BackupState) -> some View {
        let dates = RelativeDateText(calendar: model.calendar)
        return Section {
            LabeledContent("Server", value: target.host)
            LabeledContent("Benutzer", value: target.user)
            LabeledContent("Port", value: String(target.port))
            LabeledContent("Pfad", value: target.path.isEmpty ? "–" : target.path)
            LabeledContent("Repository-Adresse") {
                HStack(spacing: 8) {
                    Text(target.repository)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(target.repository)
                    CopyButton(value: target.repository, help: "Repository-Adresse kopieren")
                }
            }
            HStack(spacing: 8) {
                Text("Verbindung")
                Spacer(minLength: 12)
                ConnectionTestResultView(result: connectionTest) {
                    Text(
                        lastConnection.map { "Zuletzt erfolgreich: \(dates.standalone(for: $0, now: state.now))" }
                            ?? "Noch nie verbunden")
                }
                Button("Verbindung testen", action: testConnection)
                    .disabled(connectionTest == .testing || target.host.isEmpty || target.user.isEmpty)
            }
        } header: {
            HStack {
                Text("Verbindung")
                Spacer()
                Button("Bearbeiten …") { isEditingConnection = true }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        } footer: {
            Text("Mit der Repository-Adresse lassen sich die Sicherungen auch ohne Backup-Squirrel mit restic lesen.")
        }
    }

    private func testConnection() {
        connectionTest = .testing
        let id = target.id
        Task {
            let result = await model.testConnection(of: id)
            connectionTest = result == .succeeded ? .idle : result
        }
    }

    // MARK: Password

    private var passwordSection: some View {
        let isStored = model.hasRepositoryPassword(for: target.id)
        let id = target.id
        return Section {
            HStack(spacing: 8) {
                Text("Passwort")
                Spacer(minLength: 12)
                Text(isStored ? "Im Schlüsselbund gespeichert" : "Nicht gespeichert")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if isStored {
                    CopyButton(value: model.repositoryPassword(for: id) ?? "", help: "Passwort kopieren")
                }
                Button(isStored ? "Ändern …" : "Festlegen …") { isChangingPassword = true }
            }
        } header: {
            Text("Repository-Passwort")
        } footer: {
            Text(
                "Zusätzlich in 1Password aufbewahren: Ohne dieses Passwort lassen sich die Sicherungen nicht "
                    + "wiederherstellen.")
        }
    }

    // MARK: SSH key

    private var sshKeySection: some View {
        Section {
            LabeledContent("Status", value: target.sshKey.isInstalled ? "Schlüssel installiert" : "Nicht installiert")
            if target.sshKey.isInstalled {
                DisclosureGroup("Installationsbefehl anzeigen") {
                    InstallCommandRow(command: target.sshKey.installCommand(for: target))
                }
            } else {
                InstallCommandRow(command: target.sshKey.installCommand(for: target))
            }
        } header: {
            Text("SSH-Schlüssel")
        } footer: {
            if !target.sshKey.isInstalled {
                Text(
                    "Diesen Befehl im Terminal ausführen, um den Schlüssel auf dem Server zu hinterlegen. "
                        + "Danach die Verbindung testen.")
            }
        }
    }
}

struct ConnectionTestResultView<Idle: View>: View {
    let result: ConnectionTest
    @ViewBuilder let idle: () -> Idle

    var body: some View {
        switch result {
        case .idle:
            idle()
                .foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Wird getestet …")
                    .foregroundStyle(.secondary)
            }
        case .succeeded:
            Label {
                Text("Verbindung hergestellt")
                    .foregroundStyle(.secondary)
            } icon: {
                StatusSymbolView(symbol: .success)
            }
        case .failed(let message):
            Label {
                Text(message)
            } icon: {
                StatusSymbolView(symbol: .failure)
            }
        }
    }
}

struct CopyButton: View {
    /// Read only when copying, so a password stays in the Keychain until then.
    let value: () -> String
    let title: String
    let help: String
    @State private var isCopied = false

    init(value: @autoclosure @escaping () -> String, title: String = "Kopieren", help: String) {
        self.value = value
        self.title = title
        self.help = help
    }

    var body: some View {
        Button(isCopied ? "Kopiert" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value(), forType: .string)
            isCopied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                isCopied = false
            }
        }
        .help(help)
        .fixedSize()
    }
}

/// The install command on one line, so it never pushes the layout around.
struct InstallCommandRow: View {
    let command: String

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(command)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(value: command, title: "Befehl kopieren", help: "Befehl kopieren")
                .buttonStyle(.borderless)
        }
    }
}

struct ConnectionEditSheet: View {
    let save: (Target) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var target: Target

    init(target: Target, save: @escaping (Target) -> Void) {
        self.save = save
        _target = State(initialValue: target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Server", text: $target.host, prompt: Text(verbatim: "u000000.your-storagebox.de"))
                    TextField("Benutzer", text: $target.user, prompt: Text(verbatim: "u000000"))
                    TextField("Port", value: $target.port, format: .number.grouping(.never))
                    TextField("Pfad", text: $target.path, prompt: Text(verbatim: "/home/restic"))
                } header: {
                    Text("Verbindung bearbeiten")
                } footer: {
                    Text("Nach dem Übernehmen testet Backup-Squirrel die Verbindung erneut.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Übernehmen") {
                    save(target.trimmingConnection())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!target.hasValidConnection)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
    }
}

struct ChangePasswordSheet: View {
    /// Returns what went wrong; the sheet stays open then.
    let save: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isSaving = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    SecureField("Neues Passwort", text: $password)
                    SecureField("Wiederholen", text: $confirmation)
                    if isSaving {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Passwort wird geändert …")
                                .foregroundStyle(.secondary)
                        }
                    } else if let failure {
                        Label {
                            Text(failure)
                        } icon: {
                            StatusSymbolView(symbol: .failure)
                        }
                    }
                } header: {
                    Text("Repository-Passwort ändern")
                } footer: {
                    Text("Das neue Passwort zusätzlich in 1Password aufbewahren.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Ändern") {
                    isSaving = true
                    failure = nil
                    Task {
                        failure = await save(password)
                        isSaving = false
                        if failure == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || password != confirmation || isSaving)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
    }
}
