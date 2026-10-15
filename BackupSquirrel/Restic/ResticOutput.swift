import Foundation

enum ResticMessage: Hashable, Sendable {
    case status(OperationProgress)
    case backupSummary(BackupStatistics)
    case checkSummary(errorCount: Int)
    /// A file restic could not read, or another problem it reports and goes on.
    case error(item: String?, message: String)
    case other

    private struct Fields: Decodable {
        struct ErrorMessage: Decodable {
            var message: String?
        }

        var messageType: String?
        var percentDone: Double?
        var totalFiles: Int?
        var filesDone: Int?
        var totalBytes: Int64?
        var bytesDone: Int64?
        var secondsRemaining: Double?
        var filesNew: Int?
        var filesChanged: Int?
        var filesUnmodified: Int?
        var dataAdded: Int64?
        var totalBytesProcessed: Int64?
        var snapshotId: String?
        var numErrors: Int?
        var item: String?
        var error: ErrorMessage?
        var message: String?
    }

    private static let decoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Lines that are not JSON, such as restic's plain-text notices, parse as nil.
    static func parse(_ line: String) -> ResticMessage? {
        guard line.hasPrefix("{"), let fields = try? decoder.decode(Fields.self, from: Data(line.utf8)) else {
            return nil
        }
        switch fields.messageType {
        case "status":
            return .status(
                OperationProgress(
                    fractionCompleted: fields.percentDone ?? 0,
                    filesDone: fields.filesDone ?? 0,
                    filesTotal: fields.totalFiles ?? 0,
                    bytesDone: fields.bytesDone ?? 0,
                    bytesTotal: fields.totalBytes ?? 0,
                    secondsRemaining: fields.secondsRemaining
                ))
        case "summary" where fields.numErrors != nil:
            return .checkSummary(errorCount: fields.numErrors ?? 0)
        case "summary":
            return .backupSummary(
                BackupStatistics(
                    filesNew: fields.filesNew ?? 0,
                    filesChanged: fields.filesChanged ?? 0,
                    filesUnmodified: fields.filesUnmodified ?? 0,
                    bytesAdded: fields.dataAdded ?? 0,
                    bytesProcessed: fields.totalBytesProcessed ?? 0,
                    snapshotID: fields.snapshotId.map { String($0.prefix(8)) }
                ))
        case "error":
            return .error(item: fields.item, message: fields.error?.message ?? fields.message ?? "")
        default:
            return .other
        }
    }
}

enum ForgetOutput {
    private struct Group: Decodable {
        struct Snapshot: Decodable {}

        var remove: [Snapshot]?
    }

    static func removedCount(in lines: [String]) -> Int? {
        for line in lines where line.hasPrefix("[") {
            if let groups = try? JSONDecoder().decode([Group].self, from: Data(line.utf8)) {
                return groups.reduce(0) { $0 + ($1.remove?.count ?? 0) }
            }
        }
        return nil
    }
}

enum PruneOutput {
    private static let units: [String: Int64] = [
        "B": 1, "KiB": 1 << 10, "MiB": 1 << 20, "GiB": 1 << 30, "TiB": 1 << 40, "PiB": 1 << 50,
    ]

    /// `prune` has no JSON output; its line `total prune: 14 blobs / 199.254 KiB` names what it frees.
    static func bytesFreed(in lines: [String]) -> Int64? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("total prune:"), let slash = trimmed.lastIndex(of: "/") else { continue }
            let parts = trimmed[trimmed.index(after: slash)...].split(separator: " ")
            guard parts.count == 2, let value = Double(parts[0]), let unit = units[String(parts[1])] else {
                continue
            }
            return Int64((value * Double(unit)).rounded())
        }
        return nil
    }
}

enum ResticFailure {
    static func classify(exitCode: Int32, errorLines: [String]) -> RunFailure {
        let text = errorLines.joined(separator: "\n")
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return .other("Hostschlüssel des Servers hat sich geändert")
        }
        if text.contains("host key is known") || text.contains("Host key verification failed") {
            return .other("Hostschlüssel des Servers unbekannt, Verbindung testen")
        }
        if text.contains("Permission denied") {
            return .other("SSH-Schlüssel wird nicht akzeptiert")
        }
        if unreachableMarkers.contains(where: text.contains) {
            return .targetUnreachable
        }
        switch exitCode {
        case 10: return .other("Repository nicht gefunden")
        case 11: return .other("Repository gesperrt")
        case 12: return .other("Repository-Passwort passt nicht")
        default: return .other("restic-Fehler \(exitCode)")
        }
    }

    static let unreachableMarkers = [
        "Could not resolve hostname",
        "nodename nor servname",
        "Connection refused",
        "Connection timed out",
        "Operation timed out",
        "Network is unreachable",
        "No route to host",
        "Connection reset",
        "Connection closed",
        "connect to host",
        "Broken pipe",
        "exit status 255",
    ]
}
