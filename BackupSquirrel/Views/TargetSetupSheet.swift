import AppKit
import SwiftUI

/// Every step uses the same layout: title and one-line instruction, one card, a footer, the buttons.
struct TargetSetupSheet: View {
    static let size = CGSize(width: 560, height: 376)

    let model: AppModel
    let router: WindowRouter
    @Bindable var setup: TargetSetup
    @State private var isChoosingFolders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(setup.title)
                        .font(.title3.weight(.semibold))
                    Text(setup.instruction)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(setup.progressText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)

            Form {
                switch setup.step {
                case .connection: connectionStep
                case .key: keyStep
                case .test: testStep
                case .password: passwordStep
                case .create: createStep
                case .plan: planStep
                case .permissions: permissionsStep
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Spacer(minLength: 0)

            HStack {
                switch setup.leadingButton {
                case .cancel: Button("Abbrechen", role: .cancel, action: close)
                case .back: Button("Zurück") { setup.goBack() }
                case .skip: Button("Überspringen") { setup.skip() }
                case nil: EmptyView()
                }
                Spacer()
                Button(setup.primaryTitle, action: proceed)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!setup.canContinue)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            Button("Abbrechen", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .fileImporter(isPresented: $isChoosingFolders, allowedContentTypes: [.folder], allowsMultipleSelection: true) {
            result in
            guard case .success(let urls) = result else { return }
            setup.planFolders += urls.filter { !setup.planFolders.contains($0) }
        }
    }

    // MARK: Steps

    private var connectionStep: some View {
        Section {
            TextField("Name", text: $setup.target.name)
            TextField("Server", text: $setup.target.host, prompt: Text(verbatim: "u000000.your-storagebox.de"))
            TextField("Benutzer", text: $setup.target.user, prompt: Text(verbatim: "u000000"))
            TextField("Port", value: $setup.target.port, format: .number.grouping(.never))
            TextField("Pfad", text: $setup.target.path, prompt: Text(verbatim: "/home/restic"))
        } footer: {
            Text("Server und Benutzer stehen in der Hetzner Console bei der Storage Box.")
        }
        .onChange(of: setup.target) { setup.resetConnectionTest() }
    }

    private var keyStep: some View {
        Section {
            InstallCommandRow(command: setup.target.sshKey.installCommand(for: setup.target))
        } footer: {
            Text(
                "Dabei einmal das Passwort der Storage Box eingeben. Backup-Squirrel hat für dieses Ziel einen "
                    + "eigenen SSH-Schlüssel erzeugt und meldet sich danach damit an.")
        }
    }

    private var testStep: some View {
        Section {
            HStack(spacing: 8) {
                Text("Verbindung")
                Spacer(minLength: 12)
                ConnectionTestResultView(result: setup.connectionTest) { Text("Noch nicht getestet") }
                Button("Erneut testen", action: testConnection)
                    .disabled(setup.connectionTest == .testing)
            }
            LabeledContent("Repository") {
                switch setup.repository {
                case .searching:
                    HStack(spacing: 6) {
                        if setup.connectionTest == .succeeded {
                            ProgressView()
                                .controlSize(.small)
                            Text("Wird gesucht …")
                        } else {
                            Text("Nach dem Verbindungstest")
                        }
                    }
                case .notFound:
                    Text("Noch keins – wird angelegt")
                case .found(let snapshots):
                    Text("Vorhanden mit \(GermanFormat.count(snapshots)) Sicherungen")
                }
            }
        } footer: {
            Text("Ein vorhandenes Repository wird weiterverwendet, die Sicherungen darin bleiben erhalten.")
        }
        .task(id: setup.connectionTest) {
            if setup.connectionTest == .idle { testConnection() }
            if setup.connectionTest == .succeeded, setup.repository == .searching {
                setup.repository = await SimulatedConnection().detectRepository(at: setup.target)
            }
        }
    }

    @ViewBuilder
    private var passwordStep: some View {
        if setup.isExistingRepository {
            Section {
                SecureField("Passwort", text: $setup.password)
                switch setup.passwordCheck {
                case .idle:
                    EmptyView()
                case .checking:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Passwort wird geprüft …")
                            .foregroundStyle(.secondary)
                    }
                case .wrong:
                    Label {
                        Text("Passwort passt nicht zu diesem Repository.")
                    } icon: {
                        StatusSymbolView(symbol: .failure)
                    }
                }
            } footer: {
                Text("Das Passwort, mit dem das Repository angelegt wurde, zum Beispiel aus 1Password.")
            }
        } else {
            Section {
                LabeledContent("Passwort") {
                    HStack(spacing: 6) {
                        TextField("Passwort", text: $setup.password, prompt: Text("Eingeben oder erzeugen"))
                            .labelsHidden()
                            .font(.body.monospaced())
                        Button("Passwort erzeugen", systemImage: "arrow.clockwise", action: generatePassword)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Passwort erzeugen")
                        Button("Kopieren", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(setup.password, forType: .string)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(setup.password.isEmpty)
                        .help("Passwort kopieren")
                    }
                }
                Toggle("Passwort in 1Password gespeichert", isOn: $setup.isPasswordStored)
                    .toggleStyle(.checkbox)
                    .disabled(setup.password.isEmpty)
            } footer: {
                Text(
                    "Das Passwort verschlüsselt das Repository. Ohne es lassen sich die Sicherungen nicht "
                        + "wiederherstellen.")
            }
        }
    }

    private var createStep: some View {
        Section {
            LabeledContent("Adresse") {
                Text(setup.target.repository)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(setup.target.repository)
            }
            LabeledContent("Repository") {
                switch setup.repository {
                case .found(let snapshots): Text("Vorhanden mit \(GermanFormat.count(snapshots)) Sicherungen")
                case .notFound, .searching: Text("Wird neu angelegt")
                }
            }
            LabeledContent("Passwort", value: "Wird im Schlüsselbund gespeichert")
        } footer: {
            Text("Mit dieser Adresse lassen sich die Sicherungen auch ohne Backup-Squirrel mit restic lesen.")
        }
    }

    private var planStep: some View {
        Section {
            TextField("Name", text: $setup.planName, prompt: Text(setup.suggestedPlanName))
            LabeledContent("Ordner") {
                HStack(spacing: 8) {
                    Text(folderSummary)
                        .foregroundStyle(setup.planFolders.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Auswählen …") { isChoosingFolders = true }
                }
            }
            Picker("Sichern", selection: $setup.rhythm) {
                ForEach(Schedule.intervalHours, id: \.self) { hours in
                    Text(hours == 1 ? "Stündlich" : "Alle \(hours) Stunden").tag(TargetSetup.Rhythm.hours(hours))
                }
                Text("Täglich").tag(TargetSetup.Rhythm.daily)
                Divider()
                Text("Nur manuell").tag(TargetSetup.Rhythm.manual)
            }
            if setup.rhythm == .daily {
                DatePicker("Uhrzeit", selection: dailyTime, displayedComponents: .hourAndMinute)
            }
        } footer: {
            Text("Ausschlüsse und Uptime Kuma lassen sich danach im Plan einstellen.")
        }
    }

    private var permissionsStep: some View {
        let needsFullDiskAccess =
            setup.createdPlanID.flatMap(model.plan).map {
                StatusEvaluator(calendar: model.calendar).needsFullDiskAccess($0)
            } ?? false
        return Section {
            HStack(spacing: 8) {
                Text("Mitteilungen")
                Spacer(minLength: 12)
                if model.system.notifications == .allowed {
                    Text("Erlaubt")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Erlauben …") {
                        SystemServices.fix(.notificationsOff) { model.refreshSystem() }
                    }
                }
            }
            if needsFullDiskAccess {
                HStack(spacing: 8) {
                    Text("Festplattenvollzugriff")
                    Spacer(minLength: 12)
                    if model.system.hasFullDiskAccess {
                        Text("Erlaubt")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Erlauben …") { SystemServices.openFullDiskAccessSettings() }
                    }
                }
            }
        } footer: {
            Text(
                needsFullDiskAccess
                    ? "Mitteilungen melden Probleme auch bei geschlossenem Menü. Ohne Festplattenvollzugriff kann "
                        + "Backup-Squirrel einige Dateien in den gewählten Ordnern nicht lesen."
                    : "Mitteilungen melden Probleme auch bei geschlossenem Menü.")
        }
    }

    // MARK: Actions

    private var folderSummary: String {
        guard let first = setup.planFolders.first else { return "Noch keine Ordner ausgewählt" }
        let name = FileRow.displayName(of: first)
        return setup.planFolders.count == 1 ? name : "\(name) und \(setup.planFolders.count - 1) weitere"
    }

    private var dailyTime: Binding<Date> {
        let calendar = model.calendar
        return Binding {
            calendar.date(
                bySettingHour: setup.dailyTime.hour, minute: setup.dailyTime.minute, second: 0, of: model.now)
                ?? model.now
        } set: { date in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            setup.dailyTime = TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        }
    }

    private func proceed() {
        switch setup.step {
        case .connection, .key, .test:
            setup.goForward()
        case .password:
            guard setup.isExistingRepository else { return setup.goForward() }
            setup.passwordCheck = .checking
            let password = setup.password
            let target = setup.target
            Task {
                let matches = await SimulatedConnection().verifyPassword(password, for: target) == .matches
                guard setup.password == password else { return }
                setup.passwordCheck = matches ? .idle : .wrong
                if matches { setup.goForward() }
            }
        case .create:
            model.addTarget(setup.target, password: setup.password)
            model.markConnected(setup.target.id)
            if setup.isOnboarding {
                setup.goForward()
            } else {
                close()
                router.selection = .target(setup.target.id)
            }
        case .plan:
            setup.createdPlanID = model.addPlan(
                name: setup.suggestedPlanName, targetID: setup.target.id, sourceFolders: setup.planFolders,
                schedule: setup.schedule, automatic: setup.backsUpAutomatically)
            setup.goForward()
        case .permissions:
            close()
            router.selection = setup.createdPlanID.map(SidebarItem.plan) ?? .target(setup.target.id)
        }
    }

    private func close() {
        router.targetSetup = nil
    }

    private func generatePassword() {
        var generator = SystemRandomNumberGenerator()
        setup.generatePassword(using: &generator)
    }

    private func testConnection() {
        setup.connectionTest = .testing
        setup.repository = .searching
        let target = setup.target
        Task {
            setup.finishConnectionTest(await SimulatedConnection().test(target))
        }
    }
}
