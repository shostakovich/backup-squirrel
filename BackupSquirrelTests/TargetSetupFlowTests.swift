import Foundation
import Testing

@testable import BackupSquirrel

@MainActor
struct TargetSetupFlowTests {
    private let connection = MockConnection()
    private let keys = MockKeys()
    private let passwords = FlakyPasswordStore()

    private func model() -> AppModel {
        AppModel(
            passwords: passwords, connection: connection, keys: keys, calendar: Fixture.calendar,
            currentDate: { Fixture.now }, executor: MockRunExecutor())
    }

    private func setup(at step: TargetSetup.Step, repository: RepositoryDetection = .notFound) -> TargetSetup {
        let setup = TargetSetup(target: Fixture.target(), connection: connection, keys: keys)
        setup.keyState = .ready
        setup.connectionTest = .succeeded
        setup.repository = repository
        setup.password = "geheim"
        setup.step = step
        return setup
    }

    @Test func theKeyStepShowsTheInstallCommandOnceTheKeyExists() async {
        let setup = TargetSetup(target: Fixture.target(), connection: connection, keys: keys)
        #expect(setup.keyState == .generating)
        await setup.generateKey()
        #expect(setup.keyState == .ready)
        #expect(setup.target.sshKey.installCommand(for: setup.target).hasPrefix("cat ~/Library/Application\\ Support/"))
    }

    @Test func aKeyThatCannotBeGeneratedIsReportedAndBlocksTheStep() async {
        let setup = TargetSetup(
            target: Fixture.target(), connection: connection, keys: MockKeys(failure: SSHKeyError(message: "kaputt")))
        setup.step = .key
        await setup.generateKey()
        #expect(setup.keyState == .failed("SSH-Schlüssel konnte nicht erzeugt werden: kaputt"))
        #expect(!setup.canContinue)
    }

    @Test func cancellingRemovesTheKeyOfATargetThatWasNeverAdded() {
        let setup = setup(at: .password)
        setup.cancel()
        #expect(keys.removedKeys == [Fixture.targetID])
    }

    @Test func cancellingAfterTheTargetWasAddedKeepsItsKey() async {
        let setup = setup(at: .create)
        #expect(await setup.createRepository(in: model()))
        setup.cancel()
        #expect(keys.removedKeys.isEmpty)
    }

    @Test func theConnectionTestLooksForTheRepositoryAfterASuccessfulLogin() async {
        let setup = TargetSetup(target: Fixture.target(), connection: connection, keys: keys)
        connection.detection = .found(snapshots: 37)
        await setup.testConnection()
        #expect(setup.connectionTest == .succeeded)
        #expect(setup.target.sshKey.isInstalled)
        #expect(setup.repository == .found(snapshots: 37))
    }

    @Test func aFailedLoginDoesNotLookForTheRepository() async {
        let setup = TargetSetup(target: Fixture.target(), connection: connection, keys: keys)
        connection.testResult = .failed("SSH-Schlüssel ist noch nicht installiert")
        await setup.testConnection()
        #expect(setup.connectionTest == .failed("SSH-Schlüssel ist noch nicht installiert"))
        #expect(setup.repository == .searching)
        #expect(connection.calls == ["test u123456.your-storagebox.de"])
    }

    /// Scenario: Connecting an existing repository verifies its password.
    @Test func anExistingRepositoryWithTheWrongPasswordDoesNotContinue() async {
        let setup = setup(at: .password, repository: .found(snapshots: 37))
        setup.password = "falsch"
        connection.verification = .wrong
        await setup.submitPassword()
        #expect(setup.passwordCheck == .wrong)
        #expect(TargetSetup.wrongPasswordMessage == "Passwort passt nicht zu diesem Repository.")
        #expect(setup.step == .password)
        #expect(connection.calls == ["verify falsch"])
    }

    @Test func anExistingRepositoryThatCannotBeAskedShowsWhy() async {
        let setup = setup(at: .password, repository: .found(snapshots: 37))
        connection.verification = .failed("„Storage Box“ ist nicht erreichbar")
        await setup.submitPassword()
        #expect(setup.passwordCheck == .failed("„Storage Box“ ist nicht erreichbar"))
        #expect(setup.step == .password)
    }

    @Test func theRightPasswordMovesOn() async {
        let setup = setup(at: .password, repository: .found(snapshots: 37))
        await setup.submitPassword()
        #expect(setup.passwordCheck == .idle)
        #expect(setup.step == .create)
    }

    @Test func aNewRepositoryIsCreatedAndItsPasswordStored() async {
        let model = model()
        let setup = setup(at: .create)
        #expect(await setup.createRepository(in: model))
        #expect(connection.calls == ["create geheim"])
        #expect(passwords.password(for: Fixture.targetID) == "geheim")
        #expect(model.target(Fixture.targetID)?.connectedAt == Fixture.now)
        #expect(setup.creation == .idle)
        #expect(setup.isTargetAdded)
    }

    @Test func anExistingRepositoryOnlyStoresTheVerifiedPassword() async {
        let model = model()
        let setup = setup(at: .create, repository: .found(snapshots: 37))
        #expect(await setup.createRepository(in: model))
        #expect(connection.calls.isEmpty)
        #expect(passwords.password(for: Fixture.targetID) == "geheim")
    }

    @Test func aRepositoryThatCannotBeCreatedShowsWhyAndAddsNothing() async {
        let model = model()
        let setup = setup(at: .create)
        connection.creation = .failed("„Storage Box“ ist nicht erreichbar")
        #expect(!(await setup.createRepository(in: model)))
        #expect(setup.creation == .failed("„Storage Box“ ist nicht erreichbar"))
        #expect(model.targets.isEmpty)
        #expect(passwords.password(for: Fixture.targetID) == nil)
    }

    @Test func aKeychainFailureAfterCreatingDoesNotCreateTwice() async {
        let model = model()
        let setup = setup(at: .create)
        passwords.refusesWrites = true
        #expect(!(await setup.createRepository(in: model)))
        guard case .failed(let message) = setup.creation else { return #expect(Bool(false)) }
        #expect(message.hasPrefix("Passwort konnte nicht im Schlüsselbund gespeichert werden"))
        #expect(model.targets.isEmpty)
        #expect(setup.isExistingRepository)

        passwords.refusesWrites = false
        #expect(await setup.createRepository(in: model))
        #expect(connection.calls == ["create geheim"])
        #expect(model.targets.map(\.id) == [Fixture.targetID])
    }
}
