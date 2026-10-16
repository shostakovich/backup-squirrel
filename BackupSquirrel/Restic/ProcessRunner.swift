import Darwin
import Foundation
import Synchronization

struct ProcessInvocation: Hashable, Sendable {
    var executable: URL
    var arguments: [String] = []
    /// The complete environment; nothing is inherited from the app.
    var environment: [String: String] = [:]
    var standardInput = Data()
    /// Readable by the child as file descriptor 3.
    var extraInput: Data?
}

enum OutputLine: Hashable, Sendable {
    case standardOutput(String)
    case standardError(String)
}

struct ProcessLaunchError: Error, Hashable, Sendable {
    var code: Int32
}

protocol ProcessRunner: Sendable {
    /// Exit status, or 128 + signal; cancelling interrupts the process and throws once it has exited.
    func run(_ invocation: ProcessInvocation, onOutput: @escaping @Sendable (OutputLine) -> Void) async throws -> Int32
}

/// Spawns with `posix_spawn` because `Process` closes every descriptor above 2, and restic needs fd 3.
struct PosixProcessRunner: ProcessRunner {
    /// restic removes its lock on SIGINT; SIGKILL follows if it hangs.
    var killDelay: Duration = .seconds(10)

    func run(_ invocation: ProcessInvocation, onOutput: @escaping @Sendable (OutputLine) -> Void) async throws -> Int32
    {
        try Task.checkCancellation()
        let child = try SpawnedProcess(invocation)
        let killDelay = killDelay
        let status = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                child.wait(onOutput: onOutput) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            child.interrupt(thenKillAfter: killDelay)
        }
        try Task.checkCancellation()
        return status
    }
}

private final class SpawnedProcess: Sendable {
    private let pid: pid_t
    private let output: Int32
    private let errors: Int32
    private let hasExited = Mutex(false)

    init(_ invocation: ProcessInvocation) throws {
        var pipes: [(read: Int32, write: Int32)] = []
        do {
            for _ in 0..<(invocation.extraInput == nil ? 3 : 4) { pipes.append(try Pipe.make()) }
        } catch {
            for pipe in pipes {
                close(pipe.read)
                close(pipe.write)
            }
            throw error
        }
        let (input, output, errors) = (pipes[0], pipes[1], pipes[2])
        let extra = pipes.count > 3 ? pipes[3] : nil
        var childEnds = [input.read, output.write, errors.write]
        if let extra { childEnds.append(extra.read) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (target, source) in childEnds.enumerated() {
            posix_spawn_file_actions_adddup2(&actions, source, Int32(target))
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var allSignals = sigset_t()
        var noSignals = sigset_t()
        sigfillset(&allSignals)
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_set_qos_class_np(&attributes, QOS_CLASS_BACKGROUND)

        let argv = [invocation.executable.path] + invocation.arguments
        let environment = invocation.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withCStrings(argv) { argv in
            withCStrings(environment) { environment in
                posix_spawn(&pid, invocation.executable.path, &actions, &attributes, argv, environment)
            }
        }
        for descriptor in childEnds { close(descriptor) }
        guard result == 0 else {
            for descriptor in [input.write, output.read, errors.read, extra?.write].compactMap({ $0 }) {
                close(descriptor)
            }
            throw ProcessLaunchError(code: result)
        }
        self.pid = pid
        self.output = output.read
        self.errors = errors.read
        Self.feed(invocation.standardInput, to: input.write)
        if let extra, let data = invocation.extraInput { Self.feed(data, to: extra.write) }
    }

    func wait(onOutput: @escaping @Sendable (OutputLine) -> Void, completion: @escaping @Sendable (Int32) -> Void) {
        let readers = DispatchGroup()
        let output = output
        let errors = errors
        DispatchQueue.global(qos: .utility).async(group: readers) {
            Self.readLines(from: output) { onOutput(.standardOutput($0)) }
        }
        DispatchQueue.global(qos: .utility).async(group: readers) {
            Self.readLines(from: errors) { onOutput(.standardError($0)) }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            let status = reap()
            // A grandchild like ssh may hold the pipes open a little longer than restic lives.
            _ = readers.wait(timeout: .now() + 5)
            completion(status)
        }
    }

    func interrupt(thenKillAfter delay: Duration) {
        signal(SIGINT, to: pid)
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in
            signal(SIGKILL, to: -pid)
        }
    }

    /// Waits without reaping first, so a signal can never hit a recycled process ID.
    private func reap() -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        var status: Int32 = 0
        hasExited.withLock { exited in
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            exited = true
        }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// The negative ID reaches restic's process group; ssh sits in its own and ends when restic's pipe closes.
    private func signal(_ signal: Int32, to target: pid_t) {
        hasExited.withLock { exited in
            if !exited { kill(target, signal) }
        }
    }

    private static func feed(_ data: Data, to descriptor: Int32) {
        DispatchQueue.global(qos: .utility).async {
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { break }
                    offset += written
                }
            }
            close(descriptor)
        }
    }

    private static func readLines(from descriptor: Int32, onLine: (String) -> Void) {
        defer { close(descriptor) }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                onLine(line(pending[pending.startIndex..<newline]))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty { onLine(line(pending)) }
    }

    private static func line(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }
}

private enum Pipe {
    /// Above fd 3 and close-on-exec, so neither the child's dup2 targets nor other processes get them.
    static func make() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw ProcessLaunchError(code: errno) }
        let ends = try descriptors.map { descriptor in
            let moved = fcntl(descriptor, F_DUPFD_CLOEXEC, 4)
            close(descriptor)
            guard moved >= 0 else { throw ProcessLaunchError(code: errno) }
            return moved
        }
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
        return (ends[0], ends[1])
    }
}

private func withCStrings<Result>(
    _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    let pointers = strings.map { strdup($0) } + [nil]
    defer {
        for pointer in pointers { free(pointer) }
    }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
