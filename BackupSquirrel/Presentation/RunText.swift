import Foundation

enum RunText {
    static func title(of kind: RunKind) -> String {
        switch kind {
        case .backup: "Sicherung"
        case .check: "Prüfung"
        case .prune: "Aufräumen"
        }
    }

    static func title(of run: Run) -> String {
        switch run.status {
        case .running: "Läuft"
        case .success: "Erfolgreich"
        case .warning: "Mit Warnungen"
        case .failed: run.couldNotRun ? "Fehlgeschlagen" : "Fehler gefunden"
        case .cancelled: "Abgebrochen"
        }
    }

    static func symbol(for status: RunStatus) -> StatusSymbol {
        switch status {
        case .running: .running
        case .success: .success
        case .warning: .warning
        case .failed: .failure
        case .cancelled: .cancelled
        }
    }

    /// Lists stay calm: a successful run needs no symbol.
    static func listSymbol(for status: RunStatus) -> StatusSymbol? {
        status == .success ? nil : symbol(for: status)
    }

    static func isProblem(_ run: Run) -> Bool {
        run.status == .failed || run.status == .warning
    }

    /// The plan for backups, the target for checks and prunes.
    static func subject(of run: Run, in state: BackupState) -> String {
        if let planID = run.planID {
            return state.plan(planID)?.name ?? "Gelöschter Plan"
        }
        return targetName(of: run, in: state)
    }

    /// "Sicherung · Home-Verzeichnis", for table cells.
    static func operation(of run: Run, in state: BackupState) -> String {
        "\(title(of: run.kind)) · \(subject(of: run, in: state))"
    }

    /// "Sicherung „Home-Verzeichnis“", for headings.
    static func heading(of run: Run, in state: BackupState) -> String {
        "\(title(of: run.kind)) \(GermanFormat.quoted(subject(of: run, in: state)))"
    }

    /// Short enough for a table cell: "77 neu · 43 geändert · 59,3 MB".
    static func summary(of run: Run, in state: BackupState) -> String {
        switch run.status {
        case .running: return "Läuft …"
        case .cancelled: return "Abgebrochen"
        case .failed:
            if run.errorCount > 0, case .check(let statistics) = run.details { return errorsFound(statistics) }
            return reason(of: run, in: state)
        case .success, .warning:
            break
        }
        switch run.details {
        case .backup(let statistics):
            let added = GermanFormat.bytes(statistics.bytesAdded)
            if run.status == .warning { return "\(unreadableFiles(statistics.unreadableFiles.count)) · \(added)" }
            return "\(GermanFormat.count(statistics.filesNew)) neu · \(GermanFormat.count(statistics.filesChanged)) "
                + "geändert · \(added)"
        case .check(let statistics):
            return "\(checkSubset(statistics)) · keine Fehler"
        case .prune(let statistics):
            return olderBackupsRemoved(statistics.snapshotsRemoved)
        }
    }

    /// The whole result in sentences, for tooltips.
    static func fullSummary(of run: Run, in state: BackupState) -> String {
        switch run.status {
        case .running: return "Läuft"
        case .cancelled: return "Abgebrochen, bevor es fertig war."
        case .failed:
            if run.errorCount > 0, case .check(let statistics) = run.details {
                return "\(errorsFound(statistics)) gefunden."
            }
            return failureSentence(of: run, in: state)
        case .success, .warning:
            break
        }
        switch run.details {
        case .backup(let statistics):
            var text =
                "\(GermanFormat.count(statistics.filesNew)) neue und \(GermanFormat.count(statistics.filesChanged)) "
                + "geänderte Dateien, \(GermanFormat.bytes(statistics.bytesAdded)) hinzugefügt."
            if run.status == .warning { text += " \(unreadableFiles(statistics.unreadableFiles.count))." }
            return text
        case .check(let statistics):
            return "\(checkSubset(statistics)) geprüft, keine Fehler gefunden."
        case .prune(let statistics):
            return "\(olderBackupsRemoved(statistics.snapshotsRemoved)), "
                + "\(GermanFormat.bytes(statistics.bytesFreed)) freigegeben."
        }
    }

    static func reason(of run: Run, in state: BackupState) -> String {
        guard let failure = run.failure else { return "Fehlgeschlagen" }
        return reason(failure, targetName: targetName(of: run, in: state))
    }

    static func reason(_ failure: RunFailure, targetName: String) -> String {
        switch failure {
        case .targetUnreachable: "\(targetName) nicht erreichbar"
        case .other(let message): message
        }
    }

    static func advice(_ failure: RunFailure) -> String? {
        switch failure {
        case .targetUnreachable: "Netzwerk prüfen"
        case .other: nil
        }
    }

    static func failureSentence(of run: Run, in state: BackupState) -> String {
        let reason = reason(of: run, in: state)
        guard let advice = run.failure.flatMap(advice) else { return "\(reason)." }
        return "\(reason). \(advice)."
    }

    static func pushReason(_ failure: PushFailure) -> String {
        switch failure {
        case .rejected(statusCode: 404): "Uptime Kuma kennt diese Push-URL nicht (HTTP 404)"
        case .rejected(let statusCode): "Uptime Kuma hat die Meldung abgelehnt (HTTP \(statusCode))"
        case .unreachable: "Uptime Kuma nicht erreichbar"
        }
    }

    static func pushAdvice(_ failure: PushFailure) -> String? {
        switch failure {
        case .rejected(statusCode: 404): "Push-URL prüfen"
        case .rejected: nil
        case .unreachable: "Netzwerk prüfen"
        }
    }

    static func checkSubset(_ statistics: CheckStatistics) -> String {
        "Teil \(statistics.subset) von \(CheckStatistics.subsetCount)"
    }

    static func errorsFound(_ statistics: CheckStatistics) -> String {
        "\(GermanFormat.count(statistics.errorCount)) Fehler in \(checkSubset(statistics))"
    }

    static func unreadableFiles(_ count: Int) -> String {
        switch count {
        case 0: "Mit Warnungen gesichert"
        case 1: "1 Datei nicht lesbar"
        default: "\(GermanFormat.count(count)) Dateien nicht lesbar"
        }
    }

    static func olderBackupsRemoved(_ count: Int) -> String {
        count == 1 ? "1 ältere Sicherung entfernt" : "\(GermanFormat.count(count)) ältere Sicherungen entfernt"
    }

    private static func targetName(of run: Run, in state: BackupState) -> String {
        state.target(run.targetID)?.name ?? "Gelöschtes Ziel"
    }
}
