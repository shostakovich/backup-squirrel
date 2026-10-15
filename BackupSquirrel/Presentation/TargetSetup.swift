import Foundation
import Observation

enum ConnectionTest: Hashable, Sendable {
    case idle
    case testing
    case succeeded
    case failed(String)
}

enum RepositoryDetection: Hashable, Sendable {
    case searching
    case notFound
    case found(snapshots: Int)
}

/// Sets up a target and, on the first run, the first plan and the permissions unattended backups need.
@MainActor
@Observable
final class TargetSetup: Identifiable {
    enum Step: CaseIterable, Sendable {
        case connection
        case key
        case test
        case password
        case create
        case plan
        case permissions
    }

    enum KeyState: Hashable, Sendable {
        case generating
        case ready
        case failed(String)
    }

    enum PasswordCheck: Hashable, Sendable {
        case idle
        case checking
        case wrong
        case failed(String)
    }

    enum Creation: Hashable, Sendable {
        case idle
        case working
        case failed(String)
    }

    enum LeadingButton: Hashable, Sendable {
        case cancel
        case back
        case skip
    }

    enum Rhythm: Hashable, Sendable {
        case hours(Int)
        case daily
        case manual
    }

    static let wrongPasswordMessage = "Passwort passt nicht zu diesem Repository."

    let isOnboarding: Bool
    var step = Step.connection
    var target: Target
    var keyState = KeyState.generating
    var connectionTest = ConnectionTest.idle
    var repository = RepositoryDetection.searching
    var password = "" {
        didSet {
            guard password != oldValue else { return }
            passwordCheck = .idle
            isPasswordStored = false
        }
    }
    var isPasswordStored = false
    var passwordCheck = PasswordCheck.idle
    var planName = ""
    var planFolders: [URL] = []
    var rhythm = Rhythm.hours(1)
    var dailyTime = TimeOfDay(hour: 3, minute: 0)
    var createdPlanID: Plan.ID?
    var creation = Creation.idle
    private(set) var isTargetAdded = false

    @ObservationIgnored private let connection: any TargetConnection
    @ObservationIgnored private let keys: any SSHKeyGenerating
    @ObservationIgnored private var isCancelled = false
    /// Bumped whenever the connection changes, so a late answer for the old one is dropped.
    @ObservationIgnored private var connectionGeneration = 0

    init(
        target: Target, isOnboarding: Bool = false, connection: any TargetConnection, keys: any SSHKeyGenerating
    ) {
        self.target = target
        self.isOnboarding = isOnboarding
        self.connection = connection
        self.keys = keys
    }

    var steps: [Step] {
        isOnboarding ? Step.allCases : [.connection, .key, .test, .password, .create]
    }

    var progressText: String {
        "Schritt \((steps.firstIndex(of: step) ?? 0) + 1) von \(steps.count)"
    }

    var isExistingRepository: Bool {
        if case .found = repository { true } else { false }
    }

    var title: String {
        switch step {
        case .connection: "Verbindung"
        case .key: "SSH-Schlüssel"
        case .test: "Verbindung testen"
        case .password: "Repository-Passwort"
        case .create: isExistingRepository ? "Repository verbinden" : "Repository anlegen"
        case .plan: "Plan hinzufügen"
        case .permissions: "Mitteilungen und Zugriff"
        }
    }

    var instruction: String {
        switch step {
        case .connection: "Zugangsdaten der Storage Box eingeben."
        case .key: "Diesen Befehl einmal im Terminal ausführen."
        case .test: "Anmeldung testen und ein vorhandenes Repository suchen."
        case .password:
            isExistingRepository
                ? "Das Passwort des vorhandenen Repositorys eingeben."
                : "Ein Passwort für das neue Repository festlegen."
        case .create:
            isExistingRepository
                ? "Backup-Squirrel verbindet sich mit dem vorhandenen Repository."
                : "Backup-Squirrel legt das Repository auf der Storage Box an."
        case .plan: "Festlegen, welche Ordner wie oft gesichert werden."
        case .permissions: "Damit Probleme auffallen und alle Dateien gesichert werden."
        }
    }

    var leadingButton: LeadingButton? {
        switch step {
        case .connection: .cancel
        case .key, .test, .password, .create: .back
        case .plan: .skip
        case .permissions: nil
        }
    }

    var primaryTitle: String {
        switch step {
        case .connection, .key, .test, .password: "Weiter"
        case .create: isExistingRepository ? "Verbinden" : "Repository anlegen"
        case .plan: "Plan anlegen"
        case .permissions: "Fertig"
        }
    }

    var canContinue: Bool {
        switch step {
        case .connection:
            !target.name.trimmingCharacters(in: .whitespaces).isEmpty && target.hasValidConnection
        case .key:
            keyState == .ready
        case .create:
            creation != .working
        case .permissions:
            true
        case .test:
            connectionTest == .succeeded && repository != .searching
        case .password:
            !password.isEmpty && passwordProblem == nil && passwordCheck != .checking
                && (isExistingRepository || isPasswordStored)
        case .plan:
            !planFolders.isEmpty
        }
    }

    var passwordProblem: String? {
        password.isEmpty ? nil : RepositoryPassword.problem(with: password)
    }

    var schedule: Schedule {
        switch rhythm {
        case .hours(let hours): .everyHours(hours)
        case .daily: .daily(at: dailyTime)
        case .manual: .everyHours(1)
        }
    }

    var backsUpAutomatically: Bool { rhythm != .manual }

    /// The plan is named after its first folder unless someone typed a name.
    var suggestedPlanName: String {
        let typed = planName.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        guard let folder = planFolders.first else { return "Neuer Plan" }
        return folder.path == NSHomeDirectory() ? "Home-Verzeichnis" : folder.lastPathComponent
    }

    func goForward() {
        guard canContinue, let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        if step == .connection { target = target.trimmingConnection() }
        step = steps[index + 1]
    }

    func goBack() {
        guard leadingButton == .back, let index = steps.firstIndex(of: step), index > 0 else { return }
        step = steps[index - 1]
    }

    func skip() {
        guard step == .plan else { return }
        step = .permissions
    }

    func generatePassword(using generator: inout some RandomNumberGenerator) {
        password = RepositoryPassword.generate(using: &generator)
    }

    func finishConnectionTest(_ result: ConnectionTest) {
        connectionTest = result
        if result == .succeeded {
            target.sshKey.isInstalled = true
        }
    }

    /// A changed connection invalidates what the test found.
    func resetConnectionTest() {
        connectionGeneration += 1
        connectionTest = .idle
        repository = .searching
    }

    func generateKey() async {
        keyState = .generating
        do {
            let key = try await keys.generateKey(for: target.id)
            if isCancelled {
                try? keys.removeKey(for: target.id)
                return
            }
            target.sshKey = key
            keyState = .ready
        } catch {
            let detail = (error as? SSHKeyError)?.message ?? error.localizedDescription
            keyState = .failed("SSH-Schlüssel konnte nicht erzeugt werden: \(detail)")
        }
    }

    func testConnection() async {
        connectionGeneration += 1
        let generation = connectionGeneration
        let target = target
        connectionTest = .testing
        repository = .searching
        let result = await connection.test(target)
        guard generation == connectionGeneration else { return }
        finishConnectionTest(result)
        guard result == .succeeded else { return }
        let detection = await connection.detectRepository(at: target)
        guard generation == connectionGeneration else { return }
        repository = detection
    }

    /// A new repository's password only needs to be kept safe; an existing one's must open it.
    func submitPassword() async {
        guard step == .password, canContinue else { return }
        guard isExistingRepository else { return goForward() }
        let password = password
        passwordCheck = .checking
        let result = await connection.verifyPassword(password, for: target)
        guard self.password == password, step == .password else { return }
        switch result {
        case .matches:
            passwordCheck = .idle
            goForward()
        case .wrong:
            passwordCheck = .wrong
        case .failed(let message):
            passwordCheck = .failed(message)
        }
    }

    func createRepository(in model: AppModel) async -> Bool {
        guard step == .create, creation != .working, !isTargetAdded, passwordProblem == nil else { return false }
        creation = .working
        if !isExistingRepository {
            if case .failed(let message) = await connection.createRepository(for: target, password: password) {
                creation = .failed(message)
                return false
            }
            // From now on it exists, so going back asks for the password that opens it.
            repository = .found(snapshots: 0)
        }
        do {
            try model.addTarget(target, password: password)
        } catch {
            creation = .failed(error.localizedDescription)
            return false
        }
        model.markConnected(target.id)
        isTargetAdded = true
        creation = .idle
        return true
    }

    /// The key of a target that was never added is of no use.
    func cancel() {
        isCancelled = true
        guard !isTargetAdded else { return }
        try? keys.removeKey(for: target.id)
    }
}
