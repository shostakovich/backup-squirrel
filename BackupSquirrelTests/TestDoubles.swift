import Foundation
import Security
import Synchronization

@testable import BackupSquirrel

final class MockConnection: TargetConnection {
    private struct State {
        var testResult = ConnectionTest.succeeded
        var detection = RepositoryDetection.notFound
        var verification = PasswordVerification.matches
        var creation = RepositoryChange.succeeded
        var change = RepositoryChange.succeeded
        var calls: [String] = []
    }

    private let state = Mutex(State())

    var testResult: ConnectionTest {
        get { state.withLock { $0.testResult } }
        set { state.withLock { $0.testResult = newValue } }
    }
    var detection: RepositoryDetection {
        get { state.withLock { $0.detection } }
        set { state.withLock { $0.detection = newValue } }
    }
    var verification: PasswordVerification {
        get { state.withLock { $0.verification } }
        set { state.withLock { $0.verification = newValue } }
    }
    var creation: RepositoryChange {
        get { state.withLock { $0.creation } }
        set { state.withLock { $0.creation = newValue } }
    }
    var change: RepositoryChange {
        get { state.withLock { $0.change } }
        set { state.withLock { $0.change = newValue } }
    }
    var calls: [String] { state.withLock { $0.calls } }

    func test(_ target: Target) async -> ConnectionTest {
        state.withLock {
            $0.calls.append("test \(target.host)")
            return $0.testResult
        }
    }

    func detectRepository(at target: Target) async -> RepositoryDetection {
        state.withLock {
            $0.calls.append("detect")
            return $0.detection
        }
    }

    func verifyPassword(_ password: String, for target: Target) async -> PasswordVerification {
        state.withLock {
            $0.calls.append("verify \(password)")
            return $0.verification
        }
    }

    func createRepository(for target: Target, password: String) async -> RepositoryChange {
        state.withLock {
            $0.calls.append("create \(password)")
            return $0.creation
        }
    }

    func changePassword(of target: Target, from oldPassword: String, to newPassword: String) async -> RepositoryChange {
        state.withLock {
            $0.calls.append("change \(oldPassword) -> \(newPassword)")
            return $0.change
        }
    }
}

final class MockKeys: SSHKeyGenerating {
    private let generated = Mutex<[Target.ID]>([])
    private let removed = Mutex<[Target.ID]>([])
    private let failure: SSHKeyError?

    init(failure: SSHKeyError? = nil) {
        self.failure = failure
    }

    var generatedKeys: [Target.ID] { generated.withLock { $0 } }
    var removedKeys: [Target.ID] { removed.withLock { $0 } }

    func generateKey(for targetID: Target.ID) async throws -> SSHKey {
        if let failure { throw failure }
        generated.withLock { $0.append(targetID) }
        return SSHKey(publicKey: "ssh-ed25519 AAAA test", publicKeyPath: SSHKey.defaultPath(for: targetID))
    }

    func removeKey(for targetID: Target.ID) throws {
        removed.withLock { $0.append(targetID) }
    }
}

/// Keeps passwords in memory but can refuse to store them, as a locked Keychain does.
final class FlakyPasswordStore: PasswordStore {
    private let passwords: Mutex<[Target.ID: String]>
    private let refuses = Mutex(false)
    private let readCount = Mutex(0)

    init(_ passwords: [Target.ID: String] = [:]) {
        self.passwords = Mutex(passwords)
    }

    var reads: Int { readCount.withLock { $0 } }

    var refusesWrites: Bool {
        get { refuses.withLock { $0 } }
        set { refuses.withLock { $0 = newValue } }
    }

    func hasPassword(for targetID: Target.ID) -> Bool {
        passwords.withLock { $0[targetID] != nil }
    }

    func password(for targetID: Target.ID) -> String? {
        readCount.withLock { $0 += 1 }
        return passwords.withLock { $0[targetID] }
    }

    func setPassword(_ password: String, for targetID: Target.ID) throws {
        if refusesWrites { throw KeychainError(status: errSecInteractionNotAllowed) }
        passwords.withLock { $0[targetID] = password }
    }

    func removePassword(for targetID: Target.ID) throws {
        passwords.withLock { $0[targetID] = nil }
    }
}

final class TestClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}
