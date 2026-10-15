import Foundation
import Observation
import Security

@MainActor
@Observable
final class AppModel {
    var targets: [Target]
    var plans: [Plan]
    private(set) var runs: [Run]
    private(set) var progress: OperationProgress?
    private(set) var now: Date
    private(set) var queuedRequests: [RunRequest] = []
    private(set) var awakeSince: Date
    private(set) var system: SystemState
    private(set) var reportingPlans: Set<Plan.ID> = []
    /// Kept here so views need not ask the Keychain on every update.
    private(set) var targetsWithPassword: Set<Target.ID>

    let calendar: Calendar
    @ObservationIgnored private let currentDate: () -> Date
    @ObservationIgnored private let executor: any RunExecutor
    @ObservationIgnored private let passwords: any PasswordStore
    @ObservationIgnored private let connection: any TargetConnection
    @ObservationIgnored private let keys: any SSHKeyGenerating
    @ObservationIgnored private let inspectSystem: () -> SystemState
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var stopActiveJob: (() -> Void)?
    @ObservationIgnored private var stopReason: StopReason?
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var isScheduling = false

    init(
        targets: [Target] = [],
        plans: [Plan] = [],
        runs: [Run] = [],
        passwords: any PasswordStore,
        connection: any TargetConnection,
        keys: any SSHKeyGenerating,
        calendar: Calendar = .current,
        currentDate: @escaping () -> Date = Date.init,
        awakeSince: Date? = nil,
        inspectSystem: @escaping () -> SystemState = { SystemState() },
        executor: any RunExecutor
    ) {
        self.targets = targets
        self.plans = plans
        self.runs = runs
        self.passwords = passwords
        self.connection = connection
        self.keys = keys
        targetsWithPassword = Set(targets.map(\.id).filter(passwords.hasPassword(for:)))
        self.calendar = calendar
        self.currentDate = currentDate
        self.executor = executor
        self.inspectSystem = inspectSystem
        let now = currentDate()
        self.now = now
        self.awakeSince = awakeSince ?? now
        self.system = inspectSystem()
    }

    var activeRun: Run? { runs.last { $0.status == .running } }

    var isBusy: Bool { activeRun != nil }

    func plan(_ id: Plan.ID?) -> Plan? { plans.first { $0.id == id } }

    func target(_ id: Target.ID?) -> Target? { targets.first { $0.id == id } }

    /// Manual-only plans can still be backed up on demand.
    func isRunnable(_ plan: Plan) -> Bool {
        target(plan.targetID) != nil && !plan.sourceFolders.isEmpty
            && system.missingVolume(for: plan.sourceFolders) == nil
    }

    func canBackUp(_ plan: Plan) -> Bool {
        !isBusy && isRunnable(plan)
    }

    func canStart(_ request: RunRequest) -> Bool {
        !isBusy && job(for: request) != nil
    }

    @discardableResult
    func start(_ request: RunRequest, startedAt: Date? = nil) -> Bool {
        guard !isBusy, !isShuttingDown, let job = job(for: request) else { return false }
        let run = Run(
            planID: request.planID,
            targetID: job.target.id,
            status: .running,
            startedAt: startedAt ?? currentDate(),
            details: Self.emptyDetails(for: job)
        )
        runs.append(run)
        progress = nil
        let execution = executor.execute(job)
        stopActiveJob = execution.stop
        activeTask = Task { [weak self] in
            for await event in execution.events {
                self?.apply(event, to: run.id)
            }
            self?.finishIfStillRunning(run.id)
        }
        return true
    }

    /// Starts right away or after the runs already waiting, as notification actions need.
    func request(_ request: RunRequest) {
        guard job(for: request) != nil, activeRun?.request != request else { return }
        if isBusy {
            if !queuedRequests.contains(request) { queuedRequests.append(request) }
        } else {
            start(request)
        }
    }

    func backUpAllPlans() {
        let requests = plans.filter(isRunnable).map { RunRequest.backup($0.id) }
        guard let first = requests.first, start(first) else { return }
        queuedRequests = Array(requests.dropFirst())
    }

    func cancelActiveRun() {
        stop(as: .cancelled)
    }

    func shutDown(waitingAtMost limit: Duration) async {
        isShuttingDown = true
        isScheduling = false
        clockTask?.cancel()
        stop(as: .interrupted)
        let deadline = ContinuousClock.now + limit
        while isBusy, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let run = activeRun {
            complete(run.id) { $0.end(as: .interrupted) }
        }
    }

    private func stop(as reason: StopReason) {
        queuedRequests.removeAll()
        guard isBusy else { return }
        if stopReason == nil { stopReason = reason }
        stopActiveJob?()
    }

    private func apply(_ event: RunEvent, to runID: Run.ID) {
        switch event {
        case .progress(let newProgress):
            progress = newProgress
        case .finished(let outcome):
            var details = outcome.details
            if case .prune(var statistics) = details, outcome.status == .success,
                let prune = runs.first(where: { $0.id == runID })
            {
                statistics.snapshotsRemoved = snapshotsForgotten(before: prune)
                details = .prune(statistics)
            }
            let reason = stopReason
            complete(runID) { run in
                run.status = outcome.status
                run.details = details
                run.failure = outcome.failure
                run.output = outcome.output
                run.monitorPush = outcome.monitorPush
                if outcome.status == .cancelled, let reason { run.end(as: reason) }
            }
        }
    }

    /// What retention removed since the last successful prune is what this prune cleared away.
    private func snapshotsForgotten(before prune: Run) -> Int {
        let previous = runs.last {
            $0.targetID == prune.targetID && $0.kind == .prune && $0.status == .success && $0.id != prune.id
        }
        return runs.reduce(0) { sum, run in
            guard run.targetID == prune.targetID, run.startedAt > (previous?.startedAt ?? .distantPast),
                case .backup(let statistics) = run.details
            else { return sum }
            return sum + statistics.snapshotsForgotten
        }
    }

    private func finishIfStillRunning(_ runID: Run.ID) {
        guard runs.contains(where: { $0.id == runID && $0.status == .running }) else { return }
        let reason = stopReason ?? .cancelled
        complete(runID) { $0.end(as: reason) }
    }

    /// Completes in one main actor turn, so no other run can start before this one is fully recorded.
    private func complete(_ runID: Run.ID, _ change: (inout Run) -> Void) {
        let finishedAt = currentDate()
        update(runID) { run in
            change(&run)
            run.finishedAt = finishedAt
        }
        progress = nil
        activeTask = nil
        stopActiveJob = nil
        stopReason = nil
        now = finishedAt
        startNextQueuedRequest()
    }

    private func startNextQueuedRequest() {
        while !queuedRequests.isEmpty {
            if start(queuedRequests.removeFirst()) { return }
        }
    }

    private func update(_ runID: Run.ID, _ change: (inout Run) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        change(&runs[index])
    }

    private func job(for request: RunRequest) -> RunJob? {
        switch request {
        case .backup(let planID):
            guard let plan = plan(planID), isRunnable(plan), let target = target(plan.targetID) else { return nil }
            return .backup(plan, target)
        case .check(let targetID):
            guard let target = target(targetID) else { return nil }
            return .check(target, subset: nextCheckSubset(for: targetID))
        case .prune(let targetID):
            guard let target = target(targetID) else { return nil }
            return .prune(target)
        }
    }

    private func nextCheckSubset(for targetID: Target.ID) -> Int {
        let lastSubset = runs.lazy.reversed().compactMap { run -> Int? in
            guard run.targetID == targetID, run.completedCheck, case .check(let statistics) = run.details
            else { return nil }
            return statistics.subset
        }.first
        return (lastSubset ?? 0) % CheckStatistics.subsetCount + 1
    }

    private static func emptyDetails(for job: RunJob) -> RunDetails {
        switch job {
        case .backup: .backup(BackupStatistics())
        case .check(_, let subset): .check(CheckStatistics(subset: subset))
        case .prune: .prune(PruneStatistics())
        }
    }

    func refreshNow() {
        now = currentDate()
    }

    /// Missed runs are caught up after launch and wake, so nothing counts as overdue right then.
    func noteWake() {
        awakeSince = currentDate()
        refreshNow()
        refreshSystem()
        scheduleDueRuns()
    }

    /// Also called when a volume is mounted or unmounted, so a plan whose volume appears starts.
    func refreshSystem() {
        let current = inspectSystem()
        guard current != system else { return }
        system = current
        refreshNow()
        scheduleDueRuns()
    }

    func tick() {
        refreshNow()
        scheduleDueRuns()
    }

    /// Only the real app schedules; debug scenarios and snapshots keep their sample state.
    func startScheduling() {
        isScheduling = true
        tick()
    }

    private func scheduleDueRuns() {
        guard isScheduling else { return }
        for request in Scheduler(calendar: calendar).dueRequests(in: state) {
            self.request(request)
        }
    }

    func startClock(interval: Duration = .seconds(20)) {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.tick()
            }
        }
    }

    func addPlan() -> Plan.ID {
        addPlan(name: "Neuer Plan", targetID: targets.first?.id)
    }

    @discardableResult
    func addPlan(
        name: String, targetID: Target.ID?, sourceFolders: [URL] = [], schedule: Schedule = .everyHours(1),
        automatic: Bool = true
    ) -> Plan.ID {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let plan = Plan(
            name: uniqueName(trimmed.isEmpty ? "Neuer Plan" : trimmed, existing: plans.map(\.name)),
            targetID: targetID,
            backsUpAutomatically: automatic,
            sourceFolders: sourceFolders,
            schedule: schedule,
            createdAt: currentDate()
        )
        plans.append(plan)
        return plan.id
    }

    /// The key pair is generated as soon as a target is set up, so its install command can be shown right away.
    func makeTargetSetup() -> TargetSetup {
        let target = Target(
            name: uniqueName("Storage Box", existing: targets.map(\.name)),
            sshKey: SSHKey(publicKey: "", publicKeyPath: ""),
            createdAt: currentDate()
        )
        let setup = TargetSetup(target: target, isOnboarding: plans.isEmpty, connection: connection, keys: keys)
        Task { await setup.generateKey() }
        return setup
    }

    /// The password goes into the Keychain first; without it the target would be useless.
    func addTarget(_ target: Target, password: String) throws {
        try storePassword(password, for: target.id)
        targets.append(target)
    }

    func testConnection(of id: Target.ID) async -> ConnectionTest {
        guard let target = target(id) else { return .idle }
        let result = await connection.test(target)
        if result == .succeeded { markConnected(id) }
        return result
    }

    func markConnected(_ id: Target.ID) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        targets[index].sshKey.isInstalled = true
        targets[index].connectedAt = currentDate()
    }

    func resendReport(for planID: Plan.ID) async {
        guard let plan = plan(planID), plan.reportsToUptimeKuma, !reportingPlans.contains(planID),
            let index = runs.lastIndex(where: { $0.planID == planID && $0.producedSnapshot })
        else { return }
        let run = runs[index]
        reportingPlans.insert(planID)
        let failure = await executor.report(run, of: plan)
        reportingPlans.remove(planID)
        let sentAt = currentDate()
        update(run.id) { $0.monitorPush = MonitorPush(sentAt: sentAt, failure: failure) }
        now = sentAt
    }

    func exclude(_ url: URL, fromPlan id: Plan.ID) {
        guard let index = plans.firstIndex(where: { $0.id == id }),
            !plans[index].exclusions.contains(.path(url))
        else { return }
        plans[index].exclusions.append(.path(url))
    }

    func deletePlan(_ id: Plan.ID) {
        plans.removeAll { $0.id == id }
    }

    /// The Keychain item and key files go too; what cannot be removed is harmless without the target.
    func deleteTarget(_ id: Target.ID) {
        targets.removeAll { $0.id == id }
        for index in plans.indices where plans[index].targetID == id {
            plans[index].targetID = nil
        }
        try? passwords.removePassword(for: id)
        targetsWithPassword.remove(id)
        try? keys.removeKey(for: id)
    }

    func hasRepositoryPassword(for id: Target.ID) -> Bool {
        targetsWithPassword.contains(id)
    }

    func repositoryPassword(for id: Target.ID) -> String? {
        passwords.password(for: id)
    }

    func changeRepositoryPassword(of id: Target.ID, to newPassword: String) async -> String? {
        if let problem = RepositoryPassword.problem(with: newPassword) { return problem }
        guard let target = target(id) else { return nil }
        if let oldPassword = passwords.password(for: id) {
            let change = await connection.changePassword(of: target, from: oldPassword, to: newPassword)
            if case .failed(let message) = change { return message }
            do {
                try storePassword(newPassword, for: id)
            } catch {
                return "Das Repository hat jetzt das neue Passwort. \(error.localizedDescription)"
            }
            return nil
        }
        switch await connection.verifyPassword(newPassword, for: target) {
        case .matches: break
        case .wrong: return TargetSetup.wrongPasswordMessage
        case .failed(let message): return message
        }
        do {
            try storePassword(newPassword, for: id)
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    private func storePassword(_ password: String, for id: Target.ID) throws {
        do {
            try passwords.setPassword(password, for: id)
        } catch {
            throw PasswordStoreError(underlying: error)
        }
        targetsWithPassword.insert(id)
    }

    private func uniqueName(_ base: String, existing: [String]) -> String {
        guard existing.contains(base) else { return base }
        var number = 2
        while existing.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}

private enum StopReason {
    case cancelled
    case interrupted
}

extension Run {
    fileprivate mutating func end(as reason: StopReason) {
        switch reason {
        case .cancelled:
            status = .cancelled
        case .interrupted:
            status = .failed
            failure = .interrupted
        }
    }
}

extension RunRequest {
    var planID: Plan.ID? {
        if case .backup(let id) = self { id } else { nil }
    }
}

struct PasswordStoreError: LocalizedError {
    var underlying: any Error

    var errorDescription: String? {
        let detail =
            if let keychain = underlying as? KeychainError {
                (SecCopyErrorMessageString(keychain.status, nil) as String?) ?? "Fehler \(keychain.status)"
            } else {
                underlying.localizedDescription
            }
        return "Passwort konnte nicht im Schlüsselbund gespeichert werden (\(detail))."
    }
}

enum RepositoryPassword {
    private static let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// restic trims a password it reads from a file but not one from stdin, so such a password would lock us out.
    static func problem(with password: String) -> String? {
        let isClean =
            password == password.trimmingCharacters(in: .whitespacesAndNewlines)
            && !password.contains(where: \.isNewline)
        return isClean
            ? nil : "Das Passwort darf keine Leerzeichen am Anfang oder Ende und keine Zeilenumbrüche enthalten."
    }

    /// Six groups of five characters: about 170 bits, and easy to read aloud or type.
    static func generate(using generator: inout some RandomNumberGenerator) -> String {
        (0..<6).map { _ in
            String((0..<5).map { _ in alphabet.randomElement(using: &generator)! })
        }.joined(separator: "-")
    }
}
