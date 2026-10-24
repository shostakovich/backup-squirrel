import Foundation

enum SampleOutput {
    static func backup(
        sources: [URL], statistics: BackupStatistics, duration: TimeInterval, parentSnapshot: String
    ) -> String {
        let paths = sources.map(\.path).joined(separator: " ")
        let total = statistics.filesNew + statistics.filesChanged + statistics.filesUnmodified
        var lines = [
            "open repository",
            "lock repository",
            "using parent snapshot \(parentSnapshot)",
            "load index files",
            "start scan on [\(paths)]",
            "start backup on [\(paths)]",
            "scan finished in 3.912s: \(total) files, \(gibibytes(statistics.bytesProcessed))",
        ]
        lines += statistics.unreadableFiles.map { "error: open \($0): operation not permitted" }
        lines += [
            "",
            "Files:       \(pad(statistics.filesNew)) new, \(pad(statistics.filesChanged)) changed, "
                + "\(pad(statistics.filesUnmodified)) unmodified",
            "Added to the repository: \(mebibytes(statistics.bytesAdded)) "
                + "(\(mebibytes(statistics.bytesAdded * 93 / 100)) stored)",
            "",
            "processed \(total) files, \(gibibytes(statistics.bytesProcessed)) in \(clock(duration))",
            "snapshot \(statistics.snapshotID ?? "00000000") saved",
        ]
        if !statistics.unreadableFiles.isEmpty {
            lines.append("Warning: at least one source file could not be read")
        }
        return lines.joined(separator: "\n")
    }

    static func unreachable(_ target: Target) -> String {
        [
            "subprocess ssh: ssh: connect to host \(target.host) port \(target.port): Operation timed out",
            "Fatal: unable to open repository at \(target.repository): unable to start the sftp session, error: EOF",
        ].joined(separator: "\n")
    }

    static func check(_ statistics: CheckStatistics, packs: Int, duration: TimeInterval) -> String {
        var lines = [
            "using temporary cache in /private/var/folders/xy/T/restic-check-cache-2190475563",
            "create exclusive lock for repository",
            "load indexes",
            "check all packs",
            "check snapshots, trees and blobs",
            "[0:03] 100.00%  37 / 37 snapshots",
            "read group #\(statistics.subset) of \(packs) data packs "
                + "(out of total \(packs * statistics.subsetCount) packs in \(statistics.subsetCount) groups)",
        ]
        lines += (0..<statistics.errorCount).map { index in
            "pack \(String(format: "%08x", (index + 7) &* 2_654_435_761 & 0xffff_ffff))...: "
                + "Data integrity check failed: ciphertext verification failed"
        }
        lines.append("[\(clock(duration))] 100.00%  \(packs) / \(packs) packs")
        lines.append(statistics.errorCount == 0 ? "no errors were found" : "Fatal: repository contains errors")
        return lines.joined(separator: "\n")
    }

    static func prune(_ statistics: PruneStatistics) -> String {
        [
            "Applying Policy: keep 24 hourly, 14 daily, 8 weekly, 12 monthly snapshots",
            "remove \(statistics.snapshotsRemoved) snapshots:",
            "[0:00] 100.00%  \(statistics.snapshotsRemoved) / \(statistics.snapshotsRemoved) files deleted",
            "\(statistics.snapshotsRemoved) snapshots have been removed, running prune",
            "loading indexes...",
            "loading all snapshots...",
            "finding data that is still in use for 41 snapshots",
            "searching used packs...",
            "collecting packs for deletion and repacking",
            "will delete 112 packs and rewrite 9 packs, this frees \(gibibytes(statistics.bytesFreed))",
            "repacking packs",
            "rebuilding index",
            "deleting obsolete index files",
            "removing 121 old packs",
            "done",
        ].joined(separator: "\n")
    }

    private static func pad(_ value: Int) -> String {
        let text = String(value)
        return String(repeating: " ", count: max(0, 5 - text.count)) + text
    }

    private static func mebibytes(_ bytes: Int64) -> String {
        String(format: "%.3f MiB", Double(bytes) / 1_048_576)
    }

    private static func gibibytes(_ bytes: Int64) -> String {
        String(format: "%.3f GiB", Double(bytes) / 1_073_741_824)
    }

    private static func clock(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
