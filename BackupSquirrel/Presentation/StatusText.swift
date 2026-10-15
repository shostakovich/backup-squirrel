import Foundation

struct StatusSymbol: Hashable, Sendable {
    enum Tint: Hashable, Sendable {
        case green
        case yellow
        case red
        case accent
        case secondary
    }

    enum Rendering: Hashable, Sendable {
        /// A light glyph on a tinted disc, dark on yellow, legible on a selection highlight as well.
        case palette
        case multicolor
        /// Takes the colour of the text around it, also on a selection highlight.
        case monochrome
    }

    var name: String
    var tint: Tint
    var rendering: Rendering
    /// Spoken by VoiceOver and shown as tooltip.
    var label: String

    static let success = StatusSymbol(
        name: "checkmark.circle.fill", tint: .green, rendering: .palette, label: "Erfolgreich")
    static let current = StatusSymbol(
        name: "checkmark.circle.fill", tint: .green, rendering: .palette, label: "Aktuell")
    static let warning = StatusSymbol(
        name: "exclamationmark.triangle.fill", tint: .yellow, rendering: .multicolor, label: "Warnung")
    static let failure = StatusSymbol(
        name: "xmark.circle.fill", tint: .red, rendering: .palette, label: "Fehlgeschlagen")
    static let overdue = StatusSymbol(name: "clock.circle.fill", tint: .red, rendering: .palette, label: "Überfällig")
    static let checkOverdue = StatusSymbol(
        name: "clock.circle.fill", tint: .yellow, rendering: .palette, label: "Prüfung überfällig")
    static let running = StatusSymbol(
        name: "arrow.triangle.2.circlepath.circle.fill", tint: .accent, rendering: .palette, label: "Läuft")
    static let manualOnly = StatusSymbol(
        name: "pause.circle.fill", tint: .secondary, rendering: .monochrome, label: "Nur manuell")
    static let pending = StatusSymbol(
        name: "circle.dashed", tint: .secondary, rendering: .monochrome, label: "Noch nicht gelaufen")
    static let incomplete = StatusSymbol(
        name: "circle.dashed", tint: .secondary, rendering: .monochrome, label: "Unvollständig eingerichtet")
    static let cancelled = StatusSymbol(
        name: "minus.circle.fill", tint: .secondary, rendering: .monochrome, label: "Abgebrochen")

    static let menuOK = StatusSymbol(
        name: "checkmark.circle", tint: .secondary, rendering: .monochrome, label: "Aktuell")
    static let menuRunning = StatusSymbol(
        name: "arrow.triangle.2.circlepath.circle", tint: .secondary, rendering: .monochrome, label: "Läuft")
    static let menuManualOnly = StatusSymbol(
        name: "pause.circle", tint: .secondary, rendering: .monochrome, label: "Nur manuell")
    static let menuNotSetUp = StatusSymbol(
        name: "circle.dashed", tint: .secondary, rendering: .monochrome, label: "Nicht eingerichtet")
}

struct StatusHeader: Hashable, Sendable {
    enum Action: Hashable, Sendable {
        case start(RunRequest)
        case cancel
        case showRun(Run.ID)
        case showUnreadableFiles(Run.ID)
        case editPushURL
        case resendReport
    }

    struct Button: Hashable, Sendable {
        var action: Action
        var title: String
        var isProminent = false
    }

    var symbol: StatusSymbol
    var title: String
    /// The cause and what to do about it, in the primary colour.
    var message: String?
    var details: [String] = []
    var isRunning = false
    var fraction: Double?
    var progressDetail: String?
    var buttons: [Button]
}

struct StatusText {
    let calendar: Calendar
    var evaluator: StatusEvaluator

    init(calendar: Calendar, home: URL? = nil) {
        self.calendar = calendar
        var evaluator = StatusEvaluator(calendar: calendar)
        if let home { evaluator.home = home }
        self.evaluator = evaluator
    }

    private var dates: RelativeDateText { RelativeDateText(calendar: calendar) }

    // MARK: Menu headline

    func headline(for state: BackupState) -> (title: String, subtitle: String?) {
        if let run = state.activeRun {
            return (runningHeadline(run, in: state), progressSummary(for: state))
        }
        let problems = evaluator.problems(in: state)
        if let gap = evaluator.setupGap(in: state), gap != .nothingAutomatic || problems.isEmpty {
            let subtitle =
                switch gap {
                case .noTarget: "Noch kein Ziel eingerichtet"
                case .noPlan: "Noch kein Plan eingerichtet"
                case .nothingAutomatic: "Kein Plan sichert automatisch"
                }
            return ("Nicht eingerichtet", subtitle)
        }
        if problems.count == 1, let problem = problems.first {
            return headline(for: problem, in: state)
        }
        if problems.count > 1 {
            let names = problems.map { GermanFormat.quoted(name(of: $0.subject, in: state)) }
            return (problemCount(problems), names.joined(separator: ", "))
        }
        let system = evaluator.systemProblems(in: state)
        if system.count == 1, let problem = system.first {
            return (title(for: problem), "Alle Sicherungen aktuell")
        }
        if system.count > 1 {
            return ("\(system.count) Probleme auf diesem Mac", "Alle Sicherungen aktuell")
        }
        return ("Alle Sicherungen aktuell", singlePlanSnapshot(in: state))
    }

    /// The headline plus every problem of this Mac, for the menu bar icon's tooltip and VoiceOver.
    func tooltip(for state: BackupState) -> String {
        let system = evaluator.systemProblems(in: state)
        var base = headline(for: state).title
        if state.activeRun == nil, evaluator.problems(in: state).isEmpty, !system.isEmpty,
            evaluator.setupGap(in: state) == nil
        {
            base = "Alle Sicherungen aktuell"
        }
        guard !system.isEmpty else { return base }
        return "\(base) – \(system.map(shortText(for:)).joined(separator: ", "))"
    }

    func headlineSymbol(for state: BackupState) -> StatusSymbol {
        if state.activeRun != nil { return .menuRunning }
        let problems = evaluator.problems(in: state)
        if let gap = evaluator.setupGap(in: state), gap != .nothingAutomatic || problems.isEmpty {
            return .menuNotSetUp
        }
        if let problem = problems.first {
            switch problem.subject {
            case .plan(let id):
                if let plan = state.plan(id) { return menuSymbol(for: evaluator.status(of: plan, in: state).health) }
            case .target(let id):
                if let target = state.target(id) {
                    return menuSymbol(for: evaluator.status(of: target, in: state).health)
                }
            }
        }
        return evaluator.systemProblems(in: state).isEmpty ? .menuOK : .warning
    }

    private func headline(for problem: Problem, in state: BackupState) -> (title: String, subtitle: String?) {
        switch problem.subject {
        case .plan(let id):
            guard let plan = state.plan(id) else { return ("", nil) }
            let status = evaluator.status(of: plan, in: state)
            let name = GermanFormat.quoted(plan.name)
            let lastSnapshot = status.lastSnapshot.map { "Zuletzt gesichert: \(moment($0.endedAt, state))" }
            switch status.health {
            case .overdue:
                guard status.lastSnapshot != nil else { return ("\(name) noch nie gesichert", nil) }
                return ("\(name) \(notBackedUpFor(status, state))", lastSnapshot)
            case .failed:
                return ("Sicherung von \(name) fehlgeschlagen", lastSnapshot ?? "Noch nie gesichert")
            case .warning:
                switch status.warning {
                case .monitorPushFailed(let failure):
                    return ("Meldung von \(name) an Uptime Kuma fehlgeschlagen", RunText.pushReason(failure))
                case .unreadableFiles(let count):
                    return ("\(name): \(RunText.unreadableFiles(count))", lastSnapshot)
                case nil:
                    return (name, lastSnapshot)
                }
            case .incomplete:
                return ("\(name) sichert nicht automatisch", gapText(status.gap))
            case .running, .current, .notYetBackedUp, .manualOnly:
                return (name, lastSnapshot)
            }
        case .target(let id):
            guard let target = state.target(id) else { return ("", nil) }
            let status = evaluator.status(of: target, in: state)
            let name = GermanFormat.quoted(target.name)
            switch status.health {
            case .checkFoundErrors:
                return ("Fehler in den Sicherungen auf \(name)", status.lastCheck.map(errorsFound))
            case .checkFailed:
                return ("Prüfung von \(name) konnte nicht laufen", status.failedCheck.map { reason($0, state) })
            case .pruneFailed:
                return ("Aufräumen von \(name) fehlgeschlagen", status.failedPrune.map { reason($0, state) })
            case .checkOverdue:
                return ("Prüfung von \(name) überfällig", lastChecked(status, state))
            case .running, .current, .notYetChecked:
                return (name, nil)
            }
        }
    }

    private func singlePlanSnapshot(in state: BackupState) -> String? {
        let automatic = state.plans.filter(\.backsUpAutomatically)
        guard automatic.count == 1, let plan = automatic.first,
            let snapshot = evaluator.status(of: plan, in: state).lastSnapshot
        else { return nil }
        return "Zuletzt gesichert: \(moment(snapshot.endedAt, state))"
    }

    private func problemCount(_ problems: [Problem]) -> String {
        let plans = problems.filter { if case .plan = $0.subject { true } else { false } }.count
        let targets = problems.count - plans
        let planText = plans == 1 ? "1 Plan" : "\(plans) Pläne"
        let targetText = targets == 1 ? "1 Ziel" : "\(targets) Ziele"
        if targets == 0 { return "\(planText) mit Problemen" }
        if plans == 0 { return "\(targetText) mit Problemen" }
        return "\(planText) und \(targetText) mit Problemen"
    }

    private func name(of subject: Problem.Subject, in state: BackupState) -> String {
        switch subject {
        case .plan(let id): state.plan(id)?.name ?? ""
        case .target(let id): state.target(id)?.name ?? ""
        }
    }

    private func runningHeadline(_ run: Run, in state: BackupState) -> String {
        let subject = GermanFormat.quoted(RunText.subject(of: run, in: state))
        let verb =
            switch run.kind {
            case .backup: "Sichert \(subject)"
            case .check: "Prüft \(subject)"
            case .prune: "Räumt \(subject) auf"
            }
        guard let progress = state.progress else { return "\(verb) …" }
        return "\(verb) – \(GermanFormat.percent(progress.fractionCompleted))"
    }

    /// Files and remaining time for the menu, where space is short.
    func progressSummary(for state: BackupState) -> String? {
        guard let run = state.activeRun else { return nil }
        guard let progress = state.progress else { return "Wird vorbereitet" }
        var parts: [String] = []
        if case .check(let statistics) = run.details { parts.append(RunText.checkSubset(statistics)) }
        if progress.filesTotal > 0 {
            parts.append(
                "\(GermanFormat.count(progress.filesDone)) von \(GermanFormat.count(progress.filesTotal)) Dateien")
        }
        if let remaining = progress.secondsRemaining { parts.append(GermanFormat.remaining(remaining)) }
        return parts.joined(separator: " · ")
    }

    /// Files, bytes and remaining time for the line under a progress bar.
    func progressDetail(for state: BackupState) -> String {
        guard let run = state.activeRun, let progress = state.progress else { return "Wird vorbereitet …" }
        var parts: [String] = []
        if case .check(let statistics) = run.details { parts.append(RunText.checkSubset(statistics)) }
        if progress.filesTotal > 0 {
            parts.append(
                "\(GermanFormat.count(progress.filesDone)) von \(GermanFormat.count(progress.filesTotal)) Dateien")
        }
        if progress.bytesTotal > 0 {
            parts.append("\(GermanFormat.bytes(progress.bytesDone)) von \(GermanFormat.bytes(progress.bytesTotal))")
        }
        if let remaining = progress.secondsRemaining { parts.append(GermanFormat.remaining(remaining)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Problems of this Mac

    /// Names the problem, for the window.
    func title(for problem: SystemProblem) -> String {
        switch problem {
        case .noFullDiskAccess: "Kein Festplattenvollzugriff"
        case .notOpeningAtLogin: "Startet nicht automatisch bei der Anmeldung"
        case .notificationsOff: "Mitteilungen nicht erlaubt"
        }
    }

    /// Under its menu item.
    func consequence(of problem: SystemProblem) -> String {
        switch problem {
        case .noFullDiskAccess: "Ohne ihn werden einige Dateien nicht gesichert"
        case .notOpeningAtLogin: "Backup-Squirrel startet derzeit nicht automatisch"
        case .notificationsOff: "Probleme werden sonst nur im Menü angezeigt"
        }
    }

    /// What the problem means, under its title in the window.
    func detail(for problem: SystemProblem) -> String {
        switch problem {
        case .noFullDiskAccess: "Ohne ihn werden einige Dateien dieses Plans nicht gesichert."
        case .notOpeningAtLogin: "Nach einem Neustart wird erst gesichert, wenn Backup-Squirrel geöffnet wird."
        case .notificationsOff: "Probleme werden sonst nur im Menü angezeigt."
        }
    }

    /// What fixes the problem, as menu item and button title.
    func actionTitle(for problem: SystemProblem) -> String {
        switch problem {
        case .noFullDiskAccess: "Festplattenvollzugriff erlauben …"
        case .notOpeningAtLogin: "Beim Anmelden öffnen …"
        case .notificationsOff: "Mitteilungen erlauben …"
        }
    }

    private func shortText(for problem: SystemProblem) -> String {
        switch problem {
        case .noFullDiskAccess: "kein Festplattenvollzugriff"
        case .notOpeningAtLogin: "startet nicht automatisch bei der Anmeldung"
        case .notificationsOff: "Mitteilungen nicht erlaubt"
        }
    }

    // MARK: Symbols

    func symbol(for health: PlanHealth) -> StatusSymbol {
        switch health {
        case .running: .running
        case .current: .current
        case .notYetBackedUp: .pending
        case .warning: .warning
        case .failed: .failure
        case .overdue: .overdue
        case .manualOnly: .manualOnly
        case .incomplete(let automatic): automatic ? .warning : .incomplete
        }
    }

    /// Every row carries a symbol; only exceptions are coloured.
    func menuSymbol(for health: PlanHealth) -> StatusSymbol {
        switch health {
        case .running: .menuRunning
        case .current: .menuOK
        case .manualOnly: .menuManualOnly
        case .notYetBackedUp: .pending
        case .warning, .failed, .overdue, .incomplete: symbol(for: health)
        }
    }

    /// The sidebar also marks plans that do not back up on their own.
    func sidebarSymbol(for health: PlanHealth) -> StatusSymbol? {
        switch health {
        case .warning, .failed, .overdue, .manualOnly, .incomplete, .running: symbol(for: health)
        case .current, .notYetBackedUp: nil
        }
    }

    func symbol(for health: TargetHealth) -> StatusSymbol {
        switch health {
        case .running: .running
        case .current: .current
        case .notYetChecked: .pending
        case .checkOverdue: .checkOverdue
        case .checkFoundErrors, .checkFailed, .pruneFailed: .failure
        }
    }

    func menuSymbol(for health: TargetHealth) -> StatusSymbol {
        switch health {
        case .running: .menuRunning
        case .current: .menuOK
        case .notYetChecked: .pending
        case .checkOverdue, .checkFoundErrors, .checkFailed, .pruneFailed: symbol(for: health)
        }
    }

    func sidebarSymbol(for health: TargetHealth) -> StatusSymbol? {
        health.severity == nil && health != .running ? nil : symbol(for: health)
    }

    // MARK: Menu rows

    func summary(of plan: Plan, in state: BackupState) -> String {
        let status = evaluator.status(of: plan, in: state)
        let backedUp = status.lastSnapshot.map { "gesichert \(moment($0.endedAt, state))" } ?? "noch nie gesichert"
        switch status.health {
        case .running:
            return state.progress.map { "Wird gesichert – \(GermanFormat.percent($0.fractionCompleted))" }
                ?? "Wird gesichert …"
        case .incomplete:
            guard let snapshot = status.lastSnapshot else { return gapText(status.gap) }
            return "\(gapText(status.gap)) · zuletzt gesichert \(moment(snapshot.endedAt, state))"
        case .overdue:
            let since = RelativeDateText.capitalized(notBackedUpFor(status, state))
            return [since, standstillPhrase(status.standstill, state)].compactMap { $0 }.joined(separator: " · ")
        case .failed:
            let reason = status.failedAttempt.map { reason($0, state) } ?? "Sicherung fehlgeschlagen"
            return "\(reason) · zuletzt \(backedUp)"
        case .warning:
            switch status.warning {
            case .unreadableFiles(let count): return "\(RunText.unreadableFiles(count)) · \(backedUp)"
            case .monitorPushFailed: return "Meldung an Uptime Kuma fehlgeschlagen · \(backedUp)"
            case nil: return RelativeDateText.capitalized(backedUp)
            }
        case .manualOnly:
            return "Nur manuell · \(backedUp)"
        case .notYetBackedUp:
            return status.nextRun == .catchUp ? "Noch nicht gesichert · wird nachgeholt" : "Noch nicht gesichert"
        case .current:
            let text = RelativeDateText.capitalized(backedUp)
            if case .whenVolumeConnected(let volume) = status.nextRun {
                return "\(text) · \(GermanFormat.quoted(volume)) nicht angeschlossen"
            }
            return status.nextRun == .catchUp ? "\(text) · wird nachgeholt" : text
        }
    }

    func summary(of target: Target, in state: BackupState) -> String {
        let status = evaluator.status(of: target, in: state)
        switch status.health {
        case .running:
            let verb = state.activeRun?.kind == .prune ? "Wird aufgeräumt" : "Wird geprüft"
            return state.progress.map { "\(verb) – \(GermanFormat.percent($0.fractionCompleted))" } ?? "\(verb) …"
        case .current:
            return "Geprüft \(day(status.lastCheck?.startedAt, state)) · keine Fehler"
        case .notYetChecked:
            return "Noch nicht geprüft"
        case .checkOverdue:
            return "Prüfung überfällig · zuletzt geprüft \(day(status.lastCheck?.startedAt, state))"
        case .checkFoundErrors:
            let errors = status.lastCheck.map(errorsFound) ?? "Fehler gefunden"
            return "\(errors) · geprüft \(day(status.lastCheck?.startedAt, state))"
        case .checkFailed:
            let reason = status.failedCheck.map { reason($0, state) } ?? "Prüfung fehlgeschlagen"
            guard let lastCheck = status.lastCheck else { return "\(reason) · noch nie geprüft" }
            return "\(reason) · zuletzt geprüft \(day(lastCheck.startedAt, state))"
        case .pruneFailed:
            let reason = status.failedPrune.map { reason($0, state) }
            return ["Aufräumen fehlgeschlagen", reason].compactMap { $0 }.joined(separator: " · ")
        }
    }

    // MARK: Window

    /// What the header does not show: rhythm and target.
    func windowSubtitle(for plan: Plan, in state: BackupState) -> String {
        guard plan.backsUpAutomatically else { return "Nur manuell" }
        let rhythm =
            switch plan.schedule {
            case .everyHours(1): "Stündlich"
            case .everyHours(let hours): "Alle \(hours) Stunden"
            case .daily(let time): "Täglich um \(String(format: "%02d:%02d", time.hour, time.minute))"
            }
        guard let target = state.target(plan.targetID) else { return "\(rhythm), kein Ziel ausgewählt" }
        return "\(rhythm) auf \(GermanFormat.quoted(target.name))"
    }

    func windowSubtitle(for target: Target, in state: BackupState) -> String {
        "Wöchentliche Prüfung"
    }

    func header(for plan: Plan, in state: BackupState) -> StatusHeader {
        let status = evaluator.status(of: plan, in: state)
        let symbol = symbol(for: status.health)
        let lastSnapshot = "Zuletzt gesichert: \(status.lastSnapshot.map { moment($0.endedAt, state) } ?? "noch nie")"
        let next = status.nextRun.map { nextRunLine($0, state) }
        let backUpNow = StatusHeader.Button(action: .start(.backup(plan.id)), title: "Jetzt sichern")
        let retry = StatusHeader.Button(
            action: .start(.backup(plan.id)), title: "Erneut versuchen", isProminent: true)
        let showFailure = status.failedAttempt.map {
            StatusHeader.Button(action: .showRun($0.id), title: "Im Verlauf zeigen")
        }

        switch status.health {
        case .running:
            let title =
                state.progress.map { "Wird gesichert – \(GermanFormat.percent($0.fractionCompleted))" }
                ?? "Wird gesichert …"
            return StatusHeader(
                symbol: symbol, title: title, details: [lastSnapshot], isRunning: true,
                fraction: state.progress?.fractionCompleted, progressDetail: progressDetail(for: state),
                buttons: [StatusHeader.Button(action: .cancel, title: "Abbrechen")])
        case .current:
            return StatusHeader(
                symbol: symbol, title: "Aktuell", details: [lastSnapshot] + [next].compactMap { $0 },
                buttons: [backUpNow])
        case .notYetBackedUp:
            return StatusHeader(
                symbol: symbol, title: "Erste Sicherung steht aus", details: [lastSnapshot] + [next].compactMap { $0 },
                buttons: [backUpNow])
        case .failed:
            let message = status.failedAttempt.map { failureLine($0, retry: status.nextRun, state) }
            return StatusHeader(
                symbol: symbol, title: "Sicherung fehlgeschlagen", message: message, details: [lastSnapshot],
                buttons: [showFailure, retry].compactMap { $0 })
        case .overdue:
            let title =
                status.lastSnapshot == nil
                ? "Noch nie gesichert" : RelativeDateText.capitalized(notBackedUpFor(status, state))
            if case .failing(let failed) = status.standstill {
                return StatusHeader(
                    symbol: symbol, title: title, message: failureLine(failed, retry: status.nextRun, state),
                    details: [lastSnapshot], buttons: [showFailure, retry].compactMap { $0 })
            }
            var backUp = backUpNow
            if case .volumeMissing = status.standstill {} else { backUp.isProminent = true }
            return StatusHeader(
                symbol: symbol, title: title, message: standstillSentence(status.standstill, state),
                details: [next, lastSnapshot].compactMap { $0 }, buttons: [backUp])
        case .warning:
            switch status.warning {
            case .monitorPushFailed(let failure):
                let message = [RunText.pushReason(failure), RunText.pushAdvice(failure)].compactMap { $0 }
                    .joined(separator: ". ")
                return StatusHeader(
                    symbol: symbol, title: "Meldung an Uptime Kuma fehlgeschlagen", message: message + ".",
                    details: [lastSnapshot] + [next].compactMap { $0 },
                    buttons: [
                        StatusHeader.Button(action: .editPushURL, title: "Push-URL bearbeiten"),
                        StatusHeader.Button(action: .resendReport, title: "Erneut melden"),
                    ])
            case .unreadableFiles(let count):
                let blocked = !state.system.hasFullDiskAccess && evaluator.needsFullDiskAccess(plan)
                let message =
                    blocked
                    ? "Ohne Festplattenvollzugriff kann Backup-Squirrel sie nicht lesen."
                    : "Alles andere ist gesichert. Die Dateien ansehen und bei Bedarf vom Plan ausschließen."
                let show = status.lastSnapshot.map {
                    StatusHeader.Button(action: .showUnreadableFiles($0.id), title: "Dateien anzeigen")
                }
                return StatusHeader(
                    symbol: symbol, title: RunText.unreadableFiles(count), message: message,
                    details: [lastSnapshot] + [next].compactMap { $0 }, buttons: [show, backUpNow].compactMap { $0 })
            case nil:
                return StatusHeader(
                    symbol: symbol, title: "Mit Warnungen gesichert", details: [lastSnapshot], buttons: [backUpNow])
            }
        case .manualOnly:
            return StatusHeader(symbol: symbol, title: "Nur manuell", details: [lastSnapshot], buttons: [backUpNow])
        case .incomplete:
            let message =
                status.gap == .noTarget
                ? "Unter „Ziel und Zeitplan“ ein Ziel auswählen." : "Unter „Quellordner“ Ordner hinzufügen."
            return StatusHeader(
                symbol: symbol, title: gapText(status.gap), message: message, details: [lastSnapshot],
                buttons: [backUpNow])
        }
    }

    func header(for target: Target, in state: BackupState) -> StatusHeader {
        let status = evaluator.status(of: target, in: state)
        let symbol = symbol(for: status.health)
        let checkNow = StatusHeader.Button(action: .start(.check(target.id)), title: "Jetzt prüfen")
        let nextCheck = nextMaintenanceLine("Nächste Prüfung", status.nextCheck, state)
        let lastChecked = lastChecked(status, state)

        switch status.health {
        case .running:
            return StatusHeader(
                symbol: symbol, title: summary(of: target, in: state), isRunning: true,
                fraction: state.progress?.fractionCompleted, progressDetail: progressDetail(for: state),
                buttons: [StatusHeader.Button(action: .cancel, title: "Abbrechen")])
        case .current:
            let checked = status.lastCheck.flatMap { check -> String? in
                guard case .check(let statistics) = check.details else { return nil }
                return "\(RunText.checkSubset(statistics)) geprüft am \(day(check.startedAt, state))"
            }
            return StatusHeader(
                symbol: symbol, title: "Keine Fehler gefunden", details: [checked, nextCheck].compactMap { $0 },
                buttons: [checkNow])
        case .notYetChecked:
            return StatusHeader(
                symbol: symbol, title: "Noch nicht geprüft", details: [nextCheck], buttons: [checkNow])
        case .checkOverdue:
            return StatusHeader(
                symbol: symbol, title: "Prüfung überfällig", message: checkStandstillSentence(status, state),
                details: [nextCheck, lastChecked], buttons: [checkNow])
        case .checkFoundErrors:
            let errors = status.lastCheck.map(errorsFound) ?? "Fehler gefunden"
            let buttons = [
                status.lastCheck.map { StatusHeader.Button(action: .showRun($0.id), title: "Im Verlauf zeigen") },
                StatusHeader.Button(action: .start(.check(target.id)), title: "Erneut prüfen", isProminent: true),
            ]
            return StatusHeader(
                symbol: symbol, title: "Fehler in den Sicherungen gefunden",
                message: "\(errors). Erneut prüfen; bleiben die Fehler, die restic-Ausgabe im Verlauf ansehen.",
                details: [lastChecked], buttons: buttons.compactMap { $0 })
        case .checkFailed:
            let buttons = [
                status.failedCheck.map { StatusHeader.Button(action: .showRun($0.id), title: "Im Verlauf zeigen") },
                StatusHeader.Button(action: .start(.check(target.id)), title: "Erneut versuchen", isProminent: true),
            ]
            return StatusHeader(
                symbol: symbol, title: "Prüfung konnte nicht laufen",
                message: status.failedCheck.map { failureLine($0, retry: status.nextCheck, state) },
                details: [lastChecked], buttons: buttons.compactMap { $0 })
        case .pruneFailed:
            let lastPruned = "Zuletzt aufgeräumt: \(status.lastPrune.map { day($0.startedAt, state) } ?? "noch nie")"
            let buttons = [
                status.failedPrune.map { StatusHeader.Button(action: .showRun($0.id), title: "Im Verlauf zeigen") },
                StatusHeader.Button(action: .start(.prune(target.id)), title: "Erneut versuchen", isProminent: true),
            ]
            return StatusHeader(
                symbol: symbol, title: "Aufräumen fehlgeschlagen",
                message: status.failedPrune.map { failureLine($0, retry: status.nextPrune, state) },
                details: [lastPruned], buttons: buttons.compactMap { $0 })
        }
    }

    // MARK: Pieces

    func nextRunLine(_ nextRun: NextRun, _ state: BackupState) -> String {
        switch nextRun {
        case .at(let date): "Nächste Sicherung: \(moment(date, state))"
        case .retry(let date): "Neuer Versuch: \(moment(date, state))"
        case .catchUp: "Wird \(catchUpCondition(state))"
        case .whenVolumeConnected(let volume):
            "Wird nachgeholt, sobald \(GermanFormat.quoted(volume)) angeschlossen ist"
        }
    }

    /// "Storage Box nicht erreichbar. Netzwerk prüfen – neuer Versuch heute, 13:33."
    func failureLine(_ run: Run, retry: NextRun?, _ state: BackupState) -> String {
        var text = reason(run, state)
        if let advice = run.failure.flatMap(RunText.advice) { text += ". \(advice)" }
        guard let retry else { return text + "." }
        switch retry {
        case .at(let date), .retry(let date): return "\(text) – neuer Versuch \(moment(date, state))."
        case .catchUp: return "\(text) – neuer Versuch \(retryCondition(state))."
        case .whenVolumeConnected(let volume):
            return "\(text) – neuer Versuch, sobald \(GermanFormat.quoted(volume)) angeschlossen ist."
        }
    }

    /// "seit 3 Tagen nicht gesichert": days from two days on, hours below.
    func notBackedUpFor(_ status: PlanStatus, _ state: BackupState) -> String {
        guard let snapshot = status.lastSnapshot else { return "noch nie gesichert" }
        let elapsed = state.now.timeIntervalSince(snapshot.endedAt)
        if elapsed >= 2 * 24 * 3600 { return "seit \(Int(elapsed / (24 * 3600))) Tagen nicht gesichert" }
        let hours = Int(elapsed / 3600)
        return hours == 1 ? "seit 1 Stunde nicht gesichert" : "seit \(hours) Stunden nicht gesichert"
    }

    /// For a menu row after "Seit 3 Tagen nicht gesichert".
    func standstillPhrase(_ standstill: Standstill, _ state: BackupState) -> String? {
        switch standstill {
        case .failing(let run): reason(run, state)
        case .volumeMissing(let volume): "\(GermanFormat.quoted(volume)) nicht angeschlossen"
        case .cancelled(let date): "letzter Versuch am \(day(date, state)) abgebrochen"
        case .noAttempt(let since): since.map { "kein Versuch seit \(day($0, state))" }
        }
    }

    private func standstillSentence(_ standstill: Standstill, _ state: BackupState) -> String? {
        switch standstill {
        case .failing(let run): "\(reason(run, state))."
        case .volumeMissing(let volume): "Das Volume \(GermanFormat.quoted(volume)) ist nicht angeschlossen."
        case .cancelled(let date): "Der letzte Versuch am \(day(date, state)) wurde abgebrochen."
        case .noAttempt(let since): since.map { GermanFormat.sentence("Kein Versuch seit \(day($0, state))") }
        }
    }

    private func checkStandstillSentence(_ status: TargetStatus, _ state: BackupState) -> String? {
        switch status.checkStandstill {
        case .cancelled(let date): "Letzter Versuch: \(day(date, state)) – abgebrochen."
        case .noAttempt(let since): since.map { "Seit \(day($0, state)) kein Prüfversuch." }
        case .failing, .volumeMissing: nil
        }
    }

    private func catchUpCondition(_ state: BackupState) -> String {
        guard let run = state.activeRun else { return "jetzt nachgeholt" }
        return "nachgeholt, sobald \(GermanFormat.quoted(RunText.subject(of: run, in: state))) fertig ist"
    }

    private func retryCondition(_ state: BackupState) -> String {
        guard let run = state.activeRun else { return "in Kürze" }
        return "nach \(GermanFormat.quoted(RunText.subject(of: run, in: state)))"
    }

    private func nextMaintenanceLine(_ label: String, _ next: NextRun, _ state: BackupState) -> String {
        switch next {
        case .at(let date): "\(label): \(day(date, state))"
        case .retry(let date): "Neuer Versuch: \(moment(date, state))"
        case .catchUp: "Wird \(catchUpCondition(state))"
        case .whenVolumeConnected: label
        }
    }

    private func errorsFound(_ check: Run) -> String {
        guard case .check(let statistics) = check.details else { return "Fehler gefunden" }
        return RunText.errorsFound(statistics)
    }

    private func reason(_ run: Run, _ state: BackupState) -> String {
        RunText.reason(of: run, in: state)
    }

    private func lastChecked(_ status: TargetStatus, _ state: BackupState) -> String {
        "Zuletzt geprüft: \(status.lastCheck.map { day($0.startedAt, state) } ?? "noch nie")"
    }

    private func gapText(_ gap: PlanGap?) -> String {
        gap == .noSourceFolders ? "Keine Quellordner ausgewählt" : "Kein Ziel ausgewählt"
    }

    private func moment(_ date: Date, _ state: BackupState) -> String {
        dates.string(for: date, now: state.now)
    }

    private func day(_ date: Date?, _ state: BackupState) -> String {
        guard let date else { return "" }
        return dates.day(for: date, now: state.now)
    }
}
