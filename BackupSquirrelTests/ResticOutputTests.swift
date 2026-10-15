import Foundation
import Testing

@testable import BackupSquirrel

struct ResticOutputTests {
    @Test func statusBecomesProgress() {
        let line =
            #"{"message_type":"status","seconds_remaining":12,"percent_done":0.505,"total_files":7,"files_done":3,"#
            + #""total_bytes":290000000,"bytes_done":146526947,"current_files":["/a"]}"#
        #expect(
            ResticMessage.parse(line)
                == .status(
                    OperationProgress(
                        fractionCompleted: 0.505, filesDone: 3, filesTotal: 7, bytesDone: 146_526_947,
                        bytesTotal: 290_000_000, secondsRemaining: 12)))
    }

    @Test func anEarlyStatusWithoutTotalsStillParses() {
        #expect(
            ResticMessage.parse(#"{"message_type":"status","percent_done":0}"#)
                == .status(
                    OperationProgress(
                        fractionCompleted: 0, filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0,
                        secondsRemaining: nil)))
    }

    @Test func backupSummaryKeepsTheShortSnapshotID() {
        let line =
            #"{"message_type":"summary","files_new":214,"files_changed":87,"files_unmodified":28600,"dirs_new":9,"#
            + #""data_added":312427000,"total_files_processed":28901,"total_bytes_processed":41215000000,"#
            + #""snapshot_id":"ed0ec2f36d604f2f5ff833d180779fab66cc2a877df28ec3fa83b3b69cdda993"}"#
        #expect(
            ResticMessage.parse(line)
                == .backupSummary(
                    BackupStatistics(
                        filesNew: 214, filesChanged: 87, filesUnmodified: 28_600, bytesAdded: 312_427_000,
                        bytesProcessed: 41_215_000_000, snapshotID: "ed0ec2f3")))
    }

    @Test func anUnreadableFileIsAnErrorWithItsPath() {
        let line =
            #"{"message_type":"error","error":{"message":"open /Users/example/x: permission denied"},"#
            + #""during":"archival","item":"/Users/example/x"}"#
        #expect(
            ResticMessage.parse(line)
                == .error(item: "/Users/example/x", message: "open /Users/example/x: permission denied"))
    }

    @Test func checkSummaryCountsErrors() {
        let line = #"{"message_type":"summary","num_errors":3,"broken_packs":null,"suggest_repair_index":false}"#
        #expect(ResticMessage.parse(line) == .checkSummary(errorCount: 3))
    }

    @Test func plainTextAndOtherMessagesAreNotProgress() {
        #expect(ResticMessage.parse("using parent snapshot 4f2a9c1e") == nil)
        #expect(ResticMessage.parse("{broken") == nil)
        #expect(ResticMessage.parse(#"{"message_type":"exit_error","code":3,"message":"Warning"}"#) == .other)
    }

    @Test func forgetCountsRemovedSnapshotsAcrossGroups() {
        let line =
            #"[{"tags":["a"],"host":"h","keep":[{"id":"1"}],"remove":[{"id":"2"},{"id":"3"}]},"#
            + #"{"tags":["a"],"host":"h","keep":[{"id":"4"}],"remove":null}]"#
        #expect(ForgetOutput.removedCount(in: ["", line]) == 2)
        #expect(ForgetOutput.removedCount(in: ["Fatal: no"]) == nil)
    }

    @Test func pruneReadsTheTotalItFrees() {
        let lines = [
            "to repack:             2 blobs / 195.517 KiB",
            "this removes:          1 blobs / 195.358 KiB",
            "total prune:          14 blobs / 199.254 KiB",
            "remaining:            13 blobs / 3.722 KiB",
        ]
        #expect(PruneOutput.bytesFreed(in: lines) == 204_036)
        #expect(PruneOutput.bytesFreed(in: ["total prune:           0 blobs / 0 B"]) == 0)
        #expect(PruneOutput.bytesFreed(in: ["total prune: 1 blobs / 1.500 GiB"]) == 1_610_612_736)
        #expect(PruneOutput.bytesFreed(in: ["done"]) == nil)
    }

    @Test(arguments: [
        (10, [String](), RunFailure.other("Repository nicht gefunden")),
        (11, [], .other("Repository gesperrt")),
        (12, ["Fatal: wrong password or no key found"], .other("Repository-Passwort passt nicht")),
        (1, ["ssh: Could not resolve hostname u1.example: nodename nor servname provided"], .targetUnreachable),
        (1, ["ssh: connect to host u1.example port 23: Operation timed out"], .targetUnreachable),
        (1, ["subprocess ssh: exit status 255"], .targetUnreachable),
        (
            1, ["u1@u1.example: Permission denied (publickey).", "exit status 255"],
            .other("SSH-Schlüssel wird nicht akzeptiert")
        ),
        (
            1, ["@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @", "Host key verification failed."],
            .other("Hostschlüssel des Servers hat sich geändert")
        ),
        (
            1, ["No ED25519 host key is known for [u1.example]:23 and you have requested strict checking."],
            .other("Hostschlüssel des Servers unbekannt, Verbindung testen")
        ),
        (1, ["Fatal: something else"], .other("restic-Fehler 1")),
    ])
    func failuresAreNamedForTheOwner(exitCode: Int, errors: [String], expected: RunFailure) {
        #expect(ResticFailure.classify(exitCode: Int32(exitCode), errorLines: errors) == expected)
    }

    @Test func sftpBatchOutputIsSplitPerCommand() {
        let lines = [
            #"sftp> -ls -1 "/home/restic/mac/config""#,
            "/home/restic/mac/config",
            #"sftp> -ls -1 "/home/restic/mac/snapshots""#,
            "/home/restic/mac/snapshots/0b11497d1f5902f7a52cfb7e2e94640a2d41c1048bad709745abe8a7c2c55cda",
            "/home/restic/mac/snapshots/32166c52587b4bedb6b4ecb307c87f81d898721cb3188e27ec3fe51fa3718fbd",
        ]
        #expect(SFTPBatchOutput.listings(in: lines).map(\.count) == [1, 2])
        #expect(SFTPBatchOutput.listings(in: [#"sftp> -ls -1 "config""#, "sftp> -ls -1 x"]) == [[], []])
    }
}
