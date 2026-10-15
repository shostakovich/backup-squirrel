import Foundation
import Synchronization
import Testing

@testable import BackupSquirrel

struct ProcessRunnerTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func run(
        _ script: String, stdin: String = "", extra: String? = nil, runner: PosixProcessRunner = PosixProcessRunner()
    ) async throws -> (status: Int32, lines: [OutputLine]) {
        let lines = Mutex<[OutputLine]>([])
        let status = try await runner.run(
            ProcessInvocation(
                executable: shell, arguments: ["-c", script], standardInput: Data(stdin.utf8),
                extraInput: extra.map { Data($0.utf8) })
        ) { line in lines.withLock { $0.append(line) } }
        return (status, lines.withLock { $0 })
    }

    @Test func linesFromBothStreamsAndTheExitStatusArrive() async throws {
        let result = try await run("echo one; echo two; echo oops >&2; printf tail; exit 3")
        #expect(result.status == 3)
        #expect(
            result.lines.filter { if case .standardOutput = $0 { true } else { false } } == [
                .standardOutput("one"), .standardOutput("two"), .standardOutput("tail"),
            ])
        #expect(result.lines.contains(.standardError("oops")))
    }

    @Test func stdinAndFileDescriptor3CarryTheirData() async throws {
        let result = try await run(#"read a; read b <&3; echo "$a/$b""#, stdin: "old\n", extra: "new\n")
        #expect(result.status == 0)
        #expect(result.lines == [.standardOutput("old/new")])
    }

    @Test func withoutExtraInputFileDescriptor3IsClosed() async throws {
        let result = try await run("read b <&3 2>/dev/null && echo open || echo closed")
        #expect(result.lines.contains(.standardOutput("closed")))
    }

    @Test func theChildSeesOnlyTheGivenEnvironment() async throws {
        setenv("RESTIC_PASSWORD", "leaked", 1)
        defer { unsetenv("RESTIC_PASSWORD") }
        let lines = Mutex<[String]>([])
        let status = try await PosixProcessRunner().run(
            ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/env"), environment: ["HOME": "/nowhere"])
        ) { line in
            if case .standardOutput(let text) = line { lines.withLock { $0.append(text) } }
        }
        #expect(status == 0)
        #expect(lines.withLock { $0 } == ["HOME=/nowhere"])
    }

    @Test func cancellingInterruptsTheProcess() async throws {
        let started = Mutex(false)
        let task = Task {
            try await PosixProcessRunner().run(
                ProcessInvocation(
                    executable: shell, arguments: ["-c", "trap 'kill $!; exit 9' INT; echo ready; sleep 30 & wait"]
                )
            ) { line in
                if line == .standardOutput("ready") { started.withLock { $0 = true } }
            }
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func aProcessIgnoringTheInterruptIsKilled() async throws {
        let started = Mutex(false)
        let runner = PosixProcessRunner(killDelay: .milliseconds(200))
        let task = Task {
            try await runner.run(
                ProcessInvocation(executable: shell, arguments: ["-c", "trap '' INT; echo ready; sleep 30"])
            ) { line in
                if line == .standardOutput("ready") { started.withLock { $0 = true } }
            }
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func aMissingExecutableThrows() async {
        await #expect(throws: ProcessLaunchError.self) {
            try await PosixProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/nonexistent"))) {
                _ in
            }
        }
    }
}
