import Foundation

struct StoredConfiguration: Hashable, Sendable, Codable {
    var version = 1
    /// Fixed at first launch, so renaming the Mac does not split the history.
    var hostName: String
    var targets: [Target]
    var plans: [Plan]
}

struct StoredHistory: Hashable, Sendable, Codable {
    var version = 1
    var runs: [Run]
}

/// A file that could not be read; it is never overwritten.
struct StoreProblem: Error, Hashable, Sendable {
    var file: URL
    /// Nil when it could not be moved aside either, so it stays where it is and nothing is saved over it.
    var movedTo: URL?
}

struct LoadedState: Sendable {
    var configuration: StoredConfiguration?
    var runs: [Run] = []
    var problems: [StoreProblem] = []
    var savesConfiguration = true
    var savesHistory = true
}

/// Targets and plans in one JSON file, the run history in another; no secrets in either.
struct BackupStore: Sendable {
    static let configurationName = "configuration.json"
    static let historyName = "history.json"
    static let historyMonths = 12

    var directory: URL

    var configurationURL: URL { directory.appending(path: Self.configurationName, directoryHint: .notDirectory) }
    var historyURL: URL { directory.appending(path: Self.historyName, directoryHint: .notDirectory) }

    func load(now: Date) -> LoadedState {
        var state = LoadedState()
        switch read(StoredConfiguration.self, from: configurationURL, now: now) {
        case .success(let configuration): state.configuration = configuration
        case .failure(let problem):
            state.problems.append(problem)
            state.savesConfiguration = problem.movedTo != nil
        }
        switch read(StoredHistory.self, from: historyURL, now: now) {
        case .success(let history): state.runs = (history?.runs ?? []).map(Self.endingInterrupted)
        case .failure(let problem):
            state.problems.append(problem)
            state.savesHistory = problem.movedTo != nil
        }
        return state
    }

    func save(_ configuration: StoredConfiguration) throws {
        try write(configuration, to: configurationURL)
    }

    func saveHistory(_ runs: [Run], now: Date, calendar: Calendar) throws {
        try write(StoredHistory(runs: Self.trimmed(runs, now: now, calendar: calendar)), to: historyURL)
    }

    static func trimmed(_ runs: [Run], now: Date, calendar: Calendar) -> [Run] {
        guard let cutoff = calendar.date(byAdding: .month, value: -historyMonths, to: now) else { return runs }
        return runs.filter { $0.startedAt >= cutoff }
    }

    /// A run still marked running was cut off when the app quit or crashed.
    static func endingInterrupted(_ run: Run) -> Run {
        guard run.status == .running else { return run }
        var run = run
        run.status = .failed
        run.failure = .interrupted
        run.finishedAt = run.startedAt
        return run
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL, now: Date) -> Result<Value?, StoreProblem> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(nil) }
        do {
            return .success(try StoredJSON.decoder().decode(type, from: Data(contentsOf: url)))
        } catch {
            return .failure(StoreProblem(file: url, movedTo: moveAside(url, now: now)))
        }
    }

    private func moveAside(_ url: URL, now: Date) -> URL? {
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let destination = url.deletingPathExtension()
            .appendingPathExtension("unreadable-\(stamp)").appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try StoredJSON.encoder().encode(value).write(to: url, options: .atomic)
    }

    static func report(_ problems: [StoreProblem]) -> String {
        problems.map { problem in
            if let movedTo = problem.movedTo {
                return "\(problem.file.lastPathComponent) wurde als \(movedTo.lastPathComponent) beiseitegelegt."
            }
            return "\(problem.file.lastPathComponent) bleibt unverändert und wird nicht überschrieben."
        }.joined(separator: "\n")
    }
}
