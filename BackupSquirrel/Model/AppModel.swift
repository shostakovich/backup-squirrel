import Foundation
import Observation

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
    private var repositoryPasswords: [Target.ID: String]

    let calendar: Calendar
    @ObservationIgnored private let currentDate: () -> Date
    @ObservationIgnored private let executor: any RunExecutor
    @ObservationIgnored private let inspectSystem: () -> SystemState
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?

    init(
        targets: [Target] = [],
        plans: [Plan] = [],
        runs: [Run] = [],
        repositoryPasswords: [Target.ID: String] = [:],
        calendar: Calendar = .current,
        currentDate: @escaping () -> Date = Date.init,
        awakeSince: Date? = nil,
        inspectSystem: @escaping () -> SystemState = { SystemState() },
        executor: any RunExecutor
    ) {
        self.targets = targets
        self.plans = plans
        self.runs = runs
        self.repositoryPasswords = repositoryPasswords
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
        guard !isBusy, let job = job(for: request) else { return false }
        let run = Run(
            planID: request.planID,
            targetID: job.target.id,
            status: .running,
            startedAt: startedAt ?? currentDate(),
            details: Self.emptyDetails(for: job)
        )
        runs.append(run)
        progress = nil
        let events = executor.execute(job)
        activeTask = Task { [weak self] in
            for await event in events {
                self?.apply(event, to: run.id)
            }
            self?.finishIfStillRunning(run.id)
        }
        return true
    }

    /// Starts right away or after the runs already waiting, as notification actions need.
    func request(_ request: RunRequest) {
        guard job(for: request) != nil else { return }
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
        queuedRequests.removeAll()
        activeTask?.cancel()
    }

    private func apply(_ event: RunEvent, to runID: Run.ID) {
        switch event {
        case .progress(let newProgress):
            progress = newProgress
        case .finished(let outcome):
            complete(runID) { run in
                run.status = outcome.status
                run.details = outcome.details
                run.failure = outcome.failure
                run.output = outcome.output
                run.monitorPush = outcome.monitorPush
            }
        }
    }

    private func finishIfStillRunning(_ runID: Run.ID) {
        guard runs.contains(where: { $0.id == runID && $0.status == .running }) else { return }
        complete(runID) { $0.status = .cancelled }
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
    }

    func refreshSystem() {
        let current = inspectSystem()
        if current != system { system = current }
    }

    func startClock(interval: Duration = .seconds(20)) {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.refreshNow()
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
    func makeTargetDraft() -> Target {
        let id = UUID()
        return Target(
            id: id,
            name: uniqueName("Storage Box", existing: targets.map(\.name)),
            sshKey: SSHKey.simulated(for: id),
            createdAt: currentDate()
        )
    }

    func addTarget(_ target: Target, password: String) {
        targets.append(target)
        repositoryPasswords[target.id] = password
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
        let runID = runs[index].id
        reportingPlans.insert(planID)
        let failure = await executor.report(to: plan.uptimeKumaPushURL)
        reportingPlans.remove(planID)
        let sentAt = currentDate()
        update(runID) { $0.monitorPush = MonitorPush(sentAt: sentAt, failure: failure) }
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

    func deleteTarget(_ id: Target.ID) {
        targets.removeAll { $0.id == id }
        for index in plans.indices where plans[index].targetID == id {
            plans[index].targetID = nil
        }
        repositoryPasswords[id] = nil
    }

    func repositoryPassword(for id: Target.ID) -> String? {
        repositoryPasswords[id]
    }

    func setRepositoryPassword(_ password: String, for id: Target.ID) {
        repositoryPasswords[id] = password
    }

    private func uniqueName(_ base: String, existing: [String]) -> String {
        guard existing.contains(base) else { return base }
        var number = 2
        while existing.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}

extension RunRequest {
    var planID: Plan.ID? {
        if case .backup(let id) = self { id } else { nil }
    }
}

extension SSHKey {
    static func defaultPath(for targetID: Target.ID) -> String {
        "Library/Application Support/Backup-Squirrel/Keys/\(targetID.uuidString.lowercased()).pub"
    }

    /// Stands in for `ssh-keygen` until the real key handling exists.
    static func simulated(for targetID: Target.ID) -> SSHKey {
        let bytes = withUnsafeBytes(of: targetID.uuid) { Data($0) }
        let material = (bytes + bytes.reversed()).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return SSHKey(
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI\(material) backup-squirrel",
            publicKeyPath: defaultPath(for: targetID)
        )
    }
}

enum RepositoryPassword {
    private static let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// Six groups of five characters: about 170 bits, and easy to read aloud or type.
    static func generate(using generator: inout some RandomNumberGenerator) -> String {
        (0..<6).map { _ in
            String((0..<5).map { _ in alphabet.randomElement(using: &generator)! })
        }.joined(separator: "-")
    }
}
