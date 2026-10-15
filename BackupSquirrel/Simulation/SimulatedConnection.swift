import Foundation

/// Stands in for `ssh`, `restic cat config` and `restic snapshots` until the real connection handling exists.
enum SimulatedConnection {
    static func test(_ target: Target) async -> ConnectionTest {
        try? await Task.sleep(for: .seconds(1.2))
        return .succeeded
    }

    static func detectRepository(at target: Target) async -> RepositoryDetection {
        try? await Task.sleep(for: .seconds(0.8))
        return .notFound
    }

    static func verifyPassword(_ password: String, for target: Target) async -> Bool {
        try? await Task.sleep(for: .seconds(0.6))
        return !password.isEmpty
    }
}
