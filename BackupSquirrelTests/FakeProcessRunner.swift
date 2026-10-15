import Foundation
import Synchronization

@testable import BackupSquirrel

final class FakeProcessRunner: ProcessRunner {
    struct Response: Sendable {
        var lines: [OutputLine] = []
        var exitCode: Int32 = 0
        /// Runs until the calling task is cancelled.
        var hangs = false

        static func exit(_ code: Int32, stdout: [String] = [], stderr: [String] = []) -> Response {
            Response(
                lines: stdout.map(OutputLine.standardOutput) + stderr.map(OutputLine.standardError), exitCode: code)
        }
    }

    private let responses: Mutex<[String: [Response]]>
    private let recorded = Mutex<[ProcessInvocation]>([])

    /// Answers by subcommand (the first argument), in order; anything else exits 0 without output.
    init(_ responses: [String: [Response]] = [:]) {
        self.responses = Mutex(responses)
    }

    var invocations: [ProcessInvocation] { recorded.withLock { $0 } }

    var commands: [String] { invocations.map { $0.arguments.first ?? "" } }

    func invocation(_ command: String) -> ProcessInvocation? {
        invocations.first { $0.arguments.first == command }
    }

    func run(_ invocation: ProcessInvocation, onOutput: @escaping @Sendable (OutputLine) -> Void) async throws -> Int32
    {
        try Task.checkCancellation()
        recorded.withLock { $0.append(invocation) }
        let command = invocation.arguments.first ?? ""
        let response = responses.withLock { responses -> Response in
            guard var queue = responses[command], !queue.isEmpty else { return Response() }
            let next = queue.removeFirst()
            responses[command] = queue.isEmpty ? [next] : queue
            return next
        }
        for line in response.lines { onOutput(line) }
        if response.hangs {
            try await Task.sleep(for: .seconds(3600))
        }
        return response.exitCode
    }
}
