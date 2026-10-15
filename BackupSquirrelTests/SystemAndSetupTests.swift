import Foundation
import Testing

@testable import BackupSquirrel

struct FullDiskAccessProbeTests {
    private let home = Fixture.home

    @Test func permissionDeniedOnAProtectedFolderMeansNoAccess() {
        let granted = FullDiskAccessProbe.isGranted(home: home) { _ in
            throw CocoaError(.fileReadNoPermission)
        }
        #expect(!granted)
    }

    @Test func anUnderlyingOperationNotPermittedAlsoMeansNoAccess() {
        let error = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(!FullDiskAccessProbe.isGranted(home: home) { _ in throw error })
    }

    @Test func aReadableProtectedFolderMeansAccess() {
        var asked: [String] = []
        let granted = FullDiskAccessProbe.isGranted(home: home) { url in asked.append(url.path) }
        #expect(granted)
        #expect(asked == ["/Users/example/Library/Safari"])
    }

    @Test func missingFoldersAreSkipped() {
        var asked: [String] = []
        let granted = FullDiskAccessProbe.isGranted(home: home) { url in
            asked.append(url.lastPathComponent)
            if url.lastPathComponent != "Mail" { throw CocoaError(.fileReadNoSuchFile) }
            throw CocoaError(.fileReadNoPermission)
        }
        #expect(!granted)
        #expect(asked == ["Safari", "Mail"])
        #expect(FullDiskAccessProbe.isGranted(home: home) { _ in throw CocoaError(.fileReadNoSuchFile) })
    }
}

struct LoginItemPolicyTests {
    @Test func registersOnlyAnInstalledCopyThatIsNotRegisteredYet() {
        let installed = URL(fileURLWithPath: "/Applications/Backup-Squirrel.app")
        #expect(LoginItemPolicy.shouldRegister(appURL: installed, status: .notRegistered))
        #expect(!LoginItemPolicy.shouldRegister(appURL: installed, status: .enabled))
        #expect(!LoginItemPolicy.shouldRegister(appURL: installed, status: .requiresApproval))
    }

    @Test func neverRegistersADevelopmentBuild() {
        let derivedData = URL(
            fileURLWithPath:
                "/Users/example/Library/Developer/Xcode/DerivedData/Build/Products/Debug/Backup-Squirrel.app")
        #expect(!LoginItemPolicy.shouldRegister(appURL: derivedData, status: .notRegistered))
        let lookalike = URL(fileURLWithPath: "/tmp/Applications/Backup-Squirrel.app")
        #expect(!LoginItemPolicy.shouldRegister(appURL: lookalike, status: .notRegistered))
    }
}

struct UploadLimitTests {
    @Test func optionsAreDecimalMegabytesStoredAsKiB() {
        #expect(UploadLimit.options == [977, 2_441, 4_883, 9_766])
    }

    @Test func otherStoredValuesSnapToTheClosestOption() {
        #expect(UploadLimit.option(for: nil) == nil)
        #expect(UploadLimit.option(for: 2_500) == 2_441)
        #expect(UploadLimit.option(for: 100_000) == 9_766)
    }
}

struct RepositoryPasswordTests {
    @Test func generatesSixGroupsOfFiveUnambiguousCharacters() {
        var generator = SeededGenerator(state: 1)
        let password = RepositoryPassword.generate(using: &generator)
        let groups = password.split(separator: "-")
        #expect(groups.count == 6)
        #expect(groups.allSatisfy { $0.count == 5 })
        #expect(!password.contains { "0O1lI".contains($0) })
    }
}

@MainActor
struct TargetSetupTests {
    private func setup(onboarding: Bool = false) -> TargetSetup {
        TargetSetup(
            target: Fixture.target(), isOnboarding: onboarding, connection: MockConnection(), keys: MockKeys())
    }

    @Test func walksThroughTheStepsOnlyWhenEachIsComplete() async {
        let setup = setup()
        #expect(setup.progressText == "Schritt 1 von 5")
        setup.target.host = ""
        #expect(!setup.canContinue)
        setup.target.host = "u123456.your-storagebox.de"
        setup.goForward()
        #expect(setup.step == .key)
        #expect(!setup.canContinue)
        await setup.generateKey()
        setup.goForward()
        #expect(setup.step == .test)
        #expect(!setup.canContinue)
        setup.goForward()
        #expect(setup.step == .test)
    }

    @Test func theRepositoryIsFoundBeforeThePasswordIsAskedFor() {
        let setup = setup()
        setup.step = .test
        setup.finishConnectionTest(.succeeded)
        #expect(setup.target.sshKey.isInstalled)
        #expect(!setup.canContinue)
        setup.repository = .found(snapshots: 37)
        #expect(setup.canContinue)
        setup.goForward()
        #expect(setup.step == .password)
        #expect(setup.instruction == "Das Passwort des vorhandenen Repositorys eingeben.")
    }

    @Test func aNewPasswordNeedsTheConfirmationThatItIsStoredInOnePassword() {
        let setup = setup()
        setup.step = .password
        setup.repository = .notFound
        var generator = SeededGenerator(state: 3)
        setup.generatePassword(using: &generator)
        #expect(!setup.password.isEmpty)
        #expect(!setup.canContinue)
        setup.isPasswordStored = true
        #expect(setup.canContinue)
        setup.password = "anders"
        #expect(!setup.isPasswordStored)
        #expect(!setup.canContinue)
    }

    @Test(arguments: [" geheim", "geheim ", "geh\neim"])
    func aPasswordResticWouldReadDifferentlyIsRefused(password: String) {
        let setup = setup()
        setup.step = .password
        setup.repository = .found(snapshots: 37)
        setup.password = password
        #expect(setup.passwordProblem != nil)
        #expect(!setup.canContinue)
        setup.password = "ge heim"
        #expect(setup.passwordProblem == nil)
        #expect(setup.canContinue)
    }

    @Test func theConnectionIsTrimmedWhenTheStepIsDone() {
        let setup = setup()
        setup.target.host = " u1.example "
        setup.target.path = "backups\n"
        setup.goForward()
        #expect(setup.step == .key)
        #expect(setup.target.host == "u1.example")
        #expect(setup.target.path == "backups")
    }

    @Test func theExistingRepositorysPasswordIsCheckedAndAWrongOneIsSaid() {
        let setup = setup()
        setup.step = .password
        setup.repository = .found(snapshots: 37)
        setup.password = "falsch"
        #expect(setup.canContinue)
        setup.passwordCheck = .checking
        #expect(!setup.canContinue)
        setup.passwordCheck = .wrong
        setup.password = "richtig"
        #expect(setup.passwordCheck == .idle)
    }

    @Test func neverOffersCancelBackAndForwardTogether() {
        let setup = setup(onboarding: true)
        #expect(setup.steps == TargetSetup.Step.allCases)
        #expect(setup.leadingButton == .cancel)
        for step in [TargetSetup.Step.key, .test, .password, .create] {
            setup.step = step
            #expect(setup.leadingButton == .back)
        }
        setup.step = .plan
        #expect(setup.leadingButton == .skip)
        setup.goBack()
        #expect(setup.step == .plan)
        setup.skip()
        #expect(setup.step == .permissions)
        #expect(setup.leadingButton == nil)
        #expect(setup.primaryTitle == "Fertig")
    }

    @Test func theLastTargetStepCreatesOrConnectsTheRepository() {
        let setup = setup()
        setup.step = .create
        setup.repository = .notFound
        #expect(setup.primaryTitle == "Repository anlegen")
        setup.repository = .found(snapshots: 37)
        #expect(setup.primaryTitle == "Verbinden")
        #expect(setup.steps.last == .create)
        setup.goBack()
        #expect(setup.step == .password)
    }

    @Test func theFirstPlanIsNamedAfterItsFolderAndScheduledAsChosen() {
        let setup = setup(onboarding: true)
        setup.step = .plan
        #expect(!setup.canContinue)
        setup.planFolders = [URL(fileURLWithPath: "/Volumes/Daten", isDirectory: true)]
        #expect(setup.canContinue)
        #expect(setup.suggestedPlanName == "Daten")
        setup.planName = "Fotos"
        #expect(setup.suggestedPlanName == "Fotos")
        setup.rhythm = .daily
        setup.dailyTime = TimeOfDay(hour: 2, minute: 30)
        #expect(setup.schedule == .daily(at: TimeOfDay(hour: 2, minute: 30)))
        #expect(setup.backsUpAutomatically)
        setup.rhythm = .manual
        #expect(!setup.backsUpAutomatically)
    }
}
