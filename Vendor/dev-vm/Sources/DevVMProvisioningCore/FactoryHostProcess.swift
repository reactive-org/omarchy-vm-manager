import CDevVMProcess
import Darwin
import Foundation

private final class FactoryProcessCancellation: @unchecked Sendable {
    let lock = NSLock()
    var value = false
    func cancel() { lock.withLock { value = true } }
    var cancelled: Bool { lock.withLock { value } }
}
private final class FactoryRetiredChild: @unchecked Sendable {
    var child: devvm_child
    init(_ child: devvm_child) { self.child = child }
    func dispose() {
        var status: Int32 = 0
        while true {
            let observed = devvm_observe(child.pid, &status)
            if observed < 0 { closeFiles(); return }
            _ = kill(-child.pid, SIGKILL)
            for fd in [child.output_fd, child.error_fd] where fd >= 0 { var bytes = [UInt8](repeating: 0, count: 8192); for _ in 0..<8 { if read(fd, &bytes, bytes.count) <= 0 { break } } }
            if observed == 1, devvm_group_live(child.pid) == 0, devvm_reap(child.pid) == 0 { closeFiles(); return }
            usleep(500_000)
        }
    }
    func closeFiles() { for fd in [child.input_fd, child.output_fd, child.error_fd] where fd >= 0 { close(fd) } }
}

/// Noninteractive host jobs reuse the same audited C spawn/session bridge as
/// provisioning, without constructing a fictitious guest or session identity.
public final class LocalFactoryBuildProcess: FactoryBuildProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev-vm.factory-host-process")
    private var busy = false
    private var poisoned = false
    public init() {}
    public func run(_ command: FactoryBuildCommand, output: @escaping @Sendable (Data) -> Void) async throws -> FactoryBuildCommandResult {
        let cancellation = FactoryProcessCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard lock.withLock({ if busy || poisoned { return false }; busy = true; return true }) else { continuation.resume(throwing: FactoryBuildFailure.busy); return }
                queue.async { [self] in
                    defer { lock.withLock { busy = false } }
                    do { continuation.resume(returning: try execute(command, cancellation: cancellation, output: output)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    private func execute(_ command: FactoryBuildCommand, cancellation: FactoryProcessCancellation, output: @escaping @Sendable (Data) -> Void) throws -> FactoryBuildCommandResult {
        let values = [command.executable.path, command.directory.path] + command.arguments + command.environment.flatMap { [$0.key, $0.value] }
        guard (1...14400).contains(command.timeoutSeconds), command.arguments.count < 256,
              values.reduce(0, { $0 + $1.utf8.count }) < 128 * 1024, values.allSatisfy({ !$0.contains("\0") }),
              command.executable.isFileURL, command.directory.isFileURL, !cancellation.cancelled else { throw FactoryBuildFailure.cancelled }
        let executable = try ProvisioningExecutablePin(command.executable).verify()
        let args = ([executable.path] + command.arguments).map { value in value.withCString { strdup($0) } } + [nil]
        let env = command.environment.keys.sorted().map { key in (key + "=" + command.environment[key]!).withCString { strdup($0) } } + [nil]
        defer { for p in args + env { free(p) } }
        guard args.dropLast().allSatisfy({ $0 != nil }), env.dropLast().allSatisfy({ $0 != nil }) else { throw FactoryBuildFailure.commandFailed }
        var child = devvm_child(pid: -1, input_fd: -1, output_fd: -1, error_fd: -1)
        let result = args.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            devvm_spawn(executable.path, a.baseAddress!, e.baseAddress!, command.directory.path, 0, 30, 120, &child)
        } }
        guard result == 0 else { throw FactoryBuildFailure.commandFailed }
        close(child.input_fd); child.input_fd = -1
        let deadline = ContinuousClock.now + .seconds(command.timeoutSeconds)
        var status: Int32 = 0, captured = Data(), total = 0
        var stopping: ContinuousClock.Instant?, failure: FactoryBuildFailure?
        func drain(_ fd: inout Int32) {
            guard fd >= 0 else { return }
            var bytes = [UInt8](repeating: 0, count: 8192)
            for _ in 0..<8 {
                let n = read(fd, &bytes, bytes.count)
                if n == 0 { close(fd); fd = -1; return }
                if n < 0 { if errno != EAGAIN && errno != EINTR { failure = .commandFailed }; return }
                let data = Data(bytes.prefix(n)); total += n
                if command.streaming { output(data) }
                else if captured.count + n <= 65_536 { captured.append(data) } else { failure = .commandFailed }
            }
        }
        while true {
            let observed = devvm_observe(child.pid, &status)
            if observed < 0 { failure = .cleanupRequired; break }
            drain(&child.output_fd); drain(&child.error_fd)
            if cancellation.cancelled { failure = .cancelled }
            if ContinuousClock.now >= deadline || total > 256 * 1024 * 1024 { failure = .commandFailed }
            if failure != nil, stopping == nil { stopping = .now; _ = kill(-child.pid, SIGTERM) }
            if let stopping, ContinuousClock.now - stopping > .seconds(1) { _ = kill(-child.pid, SIGKILL) }
            if observed == 1 {
                if devvm_group_live(child.pid) == 0, child.output_fd < 0, child.error_fd < 0, devvm_reap(child.pid) == 0 {
                    if let failure { throw failure }
                    return .init(status: status, output: captured)
                }
                if stopping == nil { stopping = .now; _ = kill(-child.pid, SIGTERM) }
            }
            if let stopping, ContinuousClock.now - stopping > .seconds(5) { failure = .cleanupRequired; break }
            usleep(10_000)
        }
        lock.withLock { poisoned = true }
        let retained = FactoryRetiredChild(child)
        DispatchQueue.global(qos: .utility).async { retained.dispose() }
        throw FactoryBuildFailure.cleanupRequired
    }
}
