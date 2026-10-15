import Foundation

/// A problem worth a notification, keyed so the same problem never notifies twice in a row.
struct AlertKey: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, CaseIterable {
        case backupFailed
        case overdue
        case checkFoundErrors
        case checkFailed
        case checkOverdue
        case pruneFailed
        case monitorPushFailed
    }

    var kind: Kind
    var subject: UUID

    var identifier: String { "\(kind.rawValue).\(subject.uuidString)" }

    init(kind: Kind, subject: UUID) {
        self.kind = kind
        self.subject = subject
    }

    init?(identifier: String) {
        let parts = identifier.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = Kind(rawValue: parts[0]), let subject = UUID(uuidString: parts[1])
        else { return nil }
        self.init(kind: kind, subject: subject)
    }
}

/// The button of a notification; it does the work without opening the app.
enum AlertCommand: Hashable, Sendable {
    case start(RunRequest)
    case resendReport(Plan.ID)

    enum Style: String, Hashable, Sendable, CaseIterable {
        case retry
        case backUpNow
        case checkNow
        case resendReport

        var title: String {
            switch self {
            case .retry: "Erneut versuchen"
            case .backUpNow: "Jetzt sichern"
            case .checkNow: "Jetzt prüfen"
            case .resendReport: "Erneut melden"
            }
        }

        var systemImage: String {
            switch self {
            case .retry: "arrow.clockwise"
            case .backUpNow: "arrow.up.circle"
            case .checkNow: "checkmark.shield"
            case .resendReport: "paperplane"
            }
        }
    }
}

struct BackupAlert: Hashable, Sendable {
    var key: AlertKey
    var title: String
    var body: String
    /// Nil when a button could not help, such as for a plan whose volume is not connected.
    var command: AlertCommand?
    var style: AlertCommand.Style?
    /// Where a click on the notification leads.
    var route: MenuAction
}

struct AlertPlanner {
    let calendar: Calendar

    /// A run in progress counts as waiting, so a catch-up that is still running is not overdue.
    func alerts(in state: BackupState) -> [BackupAlert] {
        var state = state
        let active = state.runs.filter { $0.status == .running }.compactMap(\.request)
        state.queued += active.filter { !state.queued.contains($0) }
        return problems(in: state)
    }

    /// Only problems that were not there before notify; without a record the first call just records the baseline.
    func newAlerts(in state: BackupState, previous: Set<AlertKey>?) -> (current: Set<AlertKey>, new: [BackupAlert]) {
        let alerts = alerts(in: state)
        var current = Set(alerts.map(\.key))
        guard let previous else { return (current, []) }
        // A known problem must not vanish during a run or the wake grace period, or it would notify again after.
        var settled = state
        settled.queued = []
        settled.awakeSince = .distantPast
        current.formUnion(previous.intersection(problems(in: settled).map(\.key)))
        return (current, alerts.filter { !previous.contains($0.key) })
    }

    private func problems(in state: BackupState) -> [BackupAlert] {
        var state = state
        state.runs.removeAll { $0.status == .running }
        let evaluator = StatusEvaluator(calendar: calendar)
        let text = StatusText(calendar: calendar)
        var alerts: [BackupAlert] = []
        for plan in state.plans {
            let status = evaluator.status(of: plan, in: state)
            let name = GermanFormat.quoted(plan.name)
            switch status.health {
            case .failed where status.consecutiveFailures >= 2:
                alerts.append(failed(plan, status, state))
            case .overdue:
                switch status.standstill {
                case .failing:
                    if status.consecutiveFailures >= 2 { alerts.append(failed(plan, status, state)) }
                case .volumeMissing, .cancelled, .noAttempt:
                    let canBackUp: Bool
                    if case .volumeMissing = status.standstill { canBackUp = false } else { canBackUp = true }
                    alerts.append(
                        BackupAlert(
                            key: AlertKey(kind: .overdue, subject: plan.id),
                            title: "\(name) \(text.notBackedUpFor(status, state))",
                            body: sentences([standstill(status.standstill, state), lastSnapshot(status, state)]),
                            command: canBackUp ? .start(.backup(plan.id)) : nil,
                            style: canBackUp ? .backUpNow : nil, route: .showPlan(plan.id)))
                }
            default:
                break
            }
            if let failure = status.failedReport {
                let body =
                    switch failure {
                    case .rejected(let statusCode):
                        "Uptime Kuma hat die Meldung für \(name) abgelehnt (HTTP \(statusCode))."
                    case .unreachable: "Uptime Kuma war für die Meldung von \(name) nicht erreichbar."
                    }
                alerts.append(
                    BackupAlert(
                        key: AlertKey(kind: .monitorPushFailed, subject: plan.id),
                        title: "Meldung an Uptime Kuma fehlgeschlagen", body: body,
                        command: .resendReport(plan.id), style: .resendReport, route: .showPlan(plan.id)))
            }
        }
        for target in state.targets {
            if let alert = alert(for: target, in: state, evaluator: evaluator) { alerts.append(alert) }
        }
        return alerts
    }

    private func failed(_ plan: Plan, _ status: PlanStatus, _ state: BackupState) -> BackupAlert {
        BackupAlert(
            key: AlertKey(kind: .backupFailed, subject: plan.id),
            title: "Sicherung von \(GermanFormat.quoted(plan.name)) fehlgeschlagen",
            body: sentences([status.failedAttempt.map { cause(of: $0, state) }, lastSnapshot(status, state)]),
            command: .start(.backup(plan.id)), style: .retry,
            route: status.failedAttempt.map { .showRun($0.id) } ?? .showPlan(plan.id))
    }

    private func alert(for target: Target, in state: BackupState, evaluator: StatusEvaluator) -> BackupAlert? {
        let status = evaluator.status(of: target, in: state)
        let name = GermanFormat.quoted(target.name)
        let dates = RelativeDateText(calendar: calendar)
        let lastChecked = status.lastCheck.map {
            GermanFormat.sentence("Die letzte Prüfung war am \(dates.day(for: $0.startedAt, now: state.now))")
        }
        let check = AlertCommand.start(.check(target.id))
        switch status.health {
        case .checkFoundErrors:
            guard let run = status.lastCheck, case .check(let statistics) = run.details else { return nil }
            return BackupAlert(
                key: AlertKey(kind: .checkFoundErrors, subject: target.id),
                title: "Fehler in den Sicherungen auf \(name)",
                body: "Die Prüfung hat \(RunText.errorsFound(statistics)) gefunden.",
                command: check, style: .checkNow, route: .showRun(run.id))
        case .checkFailed where status.checkFailures >= 2:
            guard let run = status.failedCheck else { return nil }
            return BackupAlert(
                key: AlertKey(kind: .checkFailed, subject: target.id),
                title: "Prüfung von \(name) konnte nicht laufen",
                body: sentences([cause(of: run, state), lastChecked ?? "Es gab noch keine Prüfung."]),
                command: check, style: .checkNow, route: .showRun(run.id))
        case .pruneFailed where status.pruneFailures >= 2:
            guard let run = status.failedPrune else { return nil }
            return BackupAlert(
                key: AlertKey(kind: .pruneFailed, subject: target.id),
                title: "Aufräumen von \(name) fehlgeschlagen", body: cause(of: run, state),
                command: .start(.prune(target.id)), style: .retry, route: .showRun(run.id))
        case .checkOverdue:
            var body = lastChecked ?? "Es gab noch keine Prüfung."
            if case .cancelled(let date) = status.checkStandstill {
                body += " Der letzte Versuch am \(dates.day(for: date, now: state.now)) wurde abgebrochen."
            }
            return BackupAlert(
                key: AlertKey(kind: .checkOverdue, subject: target.id),
                title: "Prüfung von \(name) überfällig", body: body,
                command: check, style: .checkNow, route: .showTarget(target.id))
        default:
            return nil
        }
    }

    private func sentences(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: " ")
    }

    private func cause(of run: Run, _ state: BackupState) -> String {
        switch run.failure {
        case .targetUnreachable:
            "\(GermanFormat.quoted(state.target(run.targetID)?.name ?? "Ziel")) ist nicht erreichbar."
        case .other(let message):
            "\(message)."
        case nil:
            "\(RunText.reason(of: run, in: state))."
        }
    }

    private func standstill(_ standstill: Standstill, _ state: BackupState) -> String? {
        let dates = RelativeDateText(calendar: calendar)
        switch standstill {
        case .failing(let run): return cause(of: run, state)
        case .volumeMissing(let volume): return "Das Volume \(GermanFormat.quoted(volume)) ist nicht angeschlossen."
        case .cancelled(let date):
            return "Der letzte Versuch am \(dates.day(for: date, now: state.now)) wurde abgebrochen."
        case .noAttempt(let since):
            return since.map { "Seit \(dates.day(for: $0, now: state.now)) gab es keinen Versuch." }
        }
    }

    private func lastSnapshot(_ status: PlanStatus, _ state: BackupState) -> String {
        guard let snapshot = status.lastSnapshot else { return "Es gibt noch keine Sicherung." }
        let moment = RelativeDateText(calendar: calendar).string(for: snapshot.endedAt, now: state.now)
        return "Die letzte Sicherung ist von \(moment)."
    }
}

/// Survives in a notification's user info, so a click after a relaunch still finds its run or plan.
enum AlertRoute {
    static func encode(_ action: MenuAction) -> String {
        switch action {
        case .showRun(let id): "run:\(id.uuidString)"
        case .showPlan(let id): "plan:\(id.uuidString)"
        case .showTarget(let id): "target:\(id.uuidString)"
        default: "history"
        }
    }

    static func decode(_ route: String) -> MenuAction? {
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else {
            return route == "history" ? .showHistory : nil
        }
        switch parts[0] {
        case "run": return .showRun(id)
        case "plan": return .showPlan(id)
        case "target": return .showTarget(id)
        default: return nil
        }
    }

    static func encode(_ command: AlertCommand) -> String {
        switch command {
        case .start(.backup(let id)): "backup:\(id.uuidString)"
        case .start(.check(let id)): "check:\(id.uuidString)"
        case .start(.prune(let id)): "prune:\(id.uuidString)"
        case .resendReport(let id): "report:\(id.uuidString)"
        }
    }

    static func decodeCommand(_ text: String) -> AlertCommand? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "backup": return .start(.backup(id))
        case "check": return .start(.check(id))
        case "prune": return .start(.prune(id))
        case "report": return .resendReport(id)
        default: return nil
        }
    }
}

/// Remembers which problems already notified, so a relaunch neither repeats nor forgets them.
struct NotifiedAlerts {
    private static let key = "notifiedAlerts"

    let defaults: UserDefaults

    func load() -> Set<AlertKey>? {
        guard let identifiers = defaults.stringArray(forKey: Self.key) else { return nil }
        return Set(identifiers.compactMap(AlertKey.init(identifier:)))
    }

    func save(_ keys: Set<AlertKey>) {
        defaults.set(keys.map(\.identifier).sorted(), forKey: Self.key)
    }
}
