import Foundation

struct SimulatedConnection: TargetConnection {
    func test(_ target: Target) async -> ConnectionTest {
        try? await Task.sleep(for: .seconds(1.2))
        return .succeeded
    }

    func detectRepository(at target: Target) async -> RepositoryDetection {
        try? await Task.sleep(for: .seconds(0.8))
        return .notFound
    }

    func verifyPassword(_ password: String, for target: Target) async -> PasswordVerification {
        try? await Task.sleep(for: .seconds(0.6))
        return password.isEmpty ? .wrong : .matches
    }

    func createRepository(for target: Target, password: String) async -> RepositoryChange {
        try? await Task.sleep(for: .seconds(0.8))
        return .succeeded
    }

    func changePassword(of target: Target, from oldPassword: String, to newPassword: String) async -> RepositoryChange {
        try? await Task.sleep(for: .seconds(0.6))
        return .succeeded
    }
}
