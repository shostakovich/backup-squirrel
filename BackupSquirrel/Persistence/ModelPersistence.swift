import Foundation
import Observation
import os

@MainActor
final class ModelPersistence {
    private let model: AppModel
    private let store: BackupStore
    private let hostName: String
    private let savesConfiguration: Bool
    private let savesHistory: Bool
    /// Serial, so an older state can never be written after a newer one.
    private let queue = DispatchQueue(label: "de.rocu.BackupSquirrel.store", qos: .utility)
    private nonisolated static let logger = Logger(subsystem: "de.rocu.BackupSquirrel", category: "store")

    init(
        model: AppModel, store: BackupStore, hostName: String, savesConfiguration: Bool = true,
        savesHistory: Bool = true
    ) {
        self.model = model
        self.store = store
        self.hostName = hostName
        self.savesConfiguration = savesConfiguration
        self.savesHistory = savesHistory
        observeConfiguration()
        observeHistory()
    }

    /// Writes the current state and waits, since a change may not have reached its observer yet.
    func flush() {
        write(configuration)
        write(model.runs)
        queue.sync {}
    }

    private var configuration: StoredConfiguration {
        StoredConfiguration(hostName: hostName, targets: model.targets, plans: model.plans)
    }

    private func observeConfiguration() {
        let configuration = withObservationTracking {
            self.configuration
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeConfiguration() }
        }
        write(configuration)
    }

    private func observeHistory() {
        let runs = withObservationTracking {
            model.runs
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeHistory() }
        }
        write(runs)
    }

    private func write(_ configuration: StoredConfiguration) {
        guard savesConfiguration else { return }
        let store = store
        queue.async {
            do {
                try store.save(configuration)
            } catch {
                Self.logger.error("Saving targets and plans failed: \(error.localizedDescription)")
            }
        }
    }

    private func write(_ runs: [Run]) {
        guard savesHistory else { return }
        let store = store
        let now = model.now
        let calendar = model.calendar
        queue.async {
            do {
                try store.saveHistory(runs, now: now, calendar: calendar)
            } catch {
                Self.logger.error("Saving the history failed: \(error.localizedDescription)")
            }
        }
    }
}
