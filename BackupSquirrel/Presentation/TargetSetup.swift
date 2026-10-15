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

    enum PasswordCheck: Hashable, Sendable {
        case idle
        case checking
        case wrong
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

    let isOnboarding: Bool
    var step = Step.connection
    var target: Target
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

    init(target: Target, isOnboarding: Bool = false) {
        self.target = target
        self.isOnboarding = isOnboarding
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
            !target.name.trimmingCharacters(in: .whitespaces).isEmpty
                && !target.host.trimmingCharacters(in: .whitespaces).isEmpty
                && !target.user.trimmingCharacters(in: .whitespaces).isEmpty && (1...65_535).contains(target.port)
        case .key, .create, .permissions:
            true
        case .test:
            connectionTest == .succeeded && repository != .searching
        case .password:
            !password.isEmpty && passwordCheck != .checking && (isExistingRepository || isPasswordStored)
        case .plan:
            !planFolders.isEmpty
        }
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
        connectionTest = .idle
        repository = .searching
    }
}
