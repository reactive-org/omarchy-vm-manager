import CDevVMProcess
import Darwin
import Foundation

private final class LocalSessionAdmission: @unchecked Sendable {
    static let shared = LocalSessionAdmission()
    private let lock = NSLock()
    private var owners: [String: UUID] = [:]
    func claim(_ key: String, id: UUID) -> Bool {
        lock.withLock {
            guard owners[key] == nil, owners.count < 64 else { return false }
            owners[key] = id; return true
        }
    }
    func release(_ key: String, id: UUID) {
        lock.withLock { if owners[key] == id { owners.removeValue(forKey: key) } }
    }
}
private final class LocalProcessOwnership: @unchecked Sendable {
    let id: UUID
    let sessionKey: String
    let lock = NSLock()
    private var cancelled = false
    var uncertain: devvm_child? // worker queue only
    init(_ invocation: ProvisioningProcessInvocation) {
        id = invocation.id
        sessionKey = invocation.context.target.vmID.uuidString + ":" + invocation.context.target.sessionID.uuidString
    }
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Explicit opt-in local backend. No tool discovery, inherited environment,
/// shell wrapper or VM actions. One invocation owns its new session/group until
/// matching exit and group cleanup. Detached arbitrary code is not sandboxed.
public final class LocalProvisioningProcessRunner: ProvisioningProcessRunner, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev-vm.local-process")
    private let lock = NSLock()
    private var current: LocalProcessOwnership?
    private var seen = Set<UUID>()
    private let terminal: ProvisioningTerminal?
    private let ptyLauncher: ProvisioningExecutablePin?

    public init(terminal: ProvisioningTerminal? = nil, ptyLauncher: ProvisioningExecutablePin? = nil) {
        self.terminal = terminal; self.ptyLauncher = ptyLauncher
    }
    deinit {
        // An uncertain result never abandons a live child or reuses its group.
        // This closure owns the waitable leader/descriptors even if a caller
        // drops the runner. It grants nothing and never launches a new process.
        if let ownership = current, let child = ownership.uncertain {
            DispatchQueue.global(qos: .utility).async {
                var retained = child, status: Int32 = 0
                while true {
                    let observed = devvm_observe(retained.pid, &status)
                    if observed < 0 { closeDescriptors(&retained); return }
                    _ = kill(-retained.pid, SIGKILL)
                    discardPendingOutput(&retained)
                    if observed == 1, devvm_group_live(retained.pid) == 0,
                       retained.output_fd < 0, retained.error_fd < 0, devvm_reap(retained.pid) == 0 {
                        closeDescriptors(&retained)
                        LocalSessionAdmission.shared.release(ownership.sessionKey, id: ownership.id)
                        return
                    }
                    usleep(500_000)
                }
            }
        }
    }
    public func interrupt(invocationID: UUID) async { cancel(invocationID) }
    private func cancel(_ id: UUID) { lock.withLock { if current?.id == id { current?.cancel() } } }

    public func run(_ invocation: ProvisioningProcessInvocation) async -> ProvisioningProcessResult {
        await withTaskCancellationHandler {
            let ownership = lock.withLock { () -> LocalProcessOwnership? in
                guard current == nil, seen.count < 4096, seen.insert(invocation.id).inserted else { return nil }
                let value = LocalProcessOwnership(invocation)
                guard LocalSessionAdmission.shared.claim(value.sessionKey, id: value.id) else { return nil }
                current = value; return value
            }
            guard let ownership else { return result(invocation, .notStarted) }
            if Task.isCancelled { ownership.cancel() }
            return await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let value = execute(invocation, ownership: ownership)
                    if case .cleanupUnconfirmed = value.termination {} else {
                        LocalSessionAdmission.shared.release(ownership.sessionKey, id: ownership.id)
                        lock.withLock { current = nil }
                    }
                    continuation.resume(returning: value)
                }
            }
        } onCancel: { self.cancel(invocation.id) }
    }

    /// Retry only local cleanup for the exact retained invocation. No relaunch,
    /// guest reconnection, input or new grant is possible through this API.
    public func reconcileLocalCleanup(invocationID: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let ownership = lock.withLock({ current }), ownership.id == invocationID,
                      var child = ownership.uncertain else { continuation.resume(returning: false); return }
                let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
                var status: Int32 = 0
                var done = false
                repeat {
                    let observed = devvm_observe(child.pid, &status)
                    if observed < 0 { break } // Never signal a PID whose ownership was lost.
                    _ = kill(-child.pid, SIGKILL)
                    discardPendingOutput(&child)
                    if observed == 1, devvm_group_live(child.pid) == 0, child.output_fd < 0, child.error_fd < 0,
                       devvm_reap(child.pid) == 0 { done = true; break }
                    usleep(10_000)
                } while DispatchTime.now().uptimeNanoseconds < deadline
                if done {
                    closeDescriptors(&child); ownership.uncertain = nil
                    LocalSessionAdmission.shared.release(ownership.sessionKey, id: ownership.id)
                    lock.withLock { current = nil }
                } else {
                    // EOF may have closed only some descriptors. Preserve the
                    // updated set so a retry cannot touch reused descriptor IDs.
                    ownership.uncertain = child
                }
                continuation.resume(returning: done)
            }
        }
    }

    private func result(_ invocation: ProvisioningProcessInvocation, _ termination: ProvisioningProcessTermination,
                        stdout: Data = Data(), stderr: Data = Data()) -> ProvisioningProcessResult {
        ProvisioningProcessResult(invocationID: invocation.id, termination: termination, stdout: stdout, stderr: stderr)
    }
    private func validate(_ invocation: ProvisioningProcessInvocation) throws {
        try transportPath(invocation.executable); try transportPath(invocation.workingDirectory)
        let values = [invocation.executable.path, invocation.workingDirectory.path] + invocation.arguments +
            invocation.environment.flatMap { [$0.key, $0.value] }
        guard invocation.timeoutSeconds > 0, invocation.timeoutSeconds <= 3600,
              invocation.arguments.count < 4096, invocation.environment.count < 256,
              values.reduce(0, { $0 + $1.utf8.count }) <= 128 * 1024,
              values.allSatisfy({ !$0.contains("\0") }),
              invocation.environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") })
        else { throw SequencingFailure.invalidRequest }
        if case .bytes(let bytes) = invocation.input, bytes.count > 64 * 1024 { throw SequencingFailure.invalidRequest }
        if case .terminalLease = invocation.input {
            guard case .terminalStream = invocation.output else { throw SequencingFailure.invalidRequest }
        }
    }

    private func execute(_ invocation: ProvisioningProcessInvocation, ownership: LocalProcessOwnership) -> ProvisioningProcessResult {
        let isTTY: Bool
        if case .terminalLease = invocation.input { isTTY = true } else { isTTY = false }
        let streaming: Bool
        if case .terminalStream = invocation.output { streaming = true } else { streaming = false }
        var terminalStarted = false
        var child = devvm_child(pid: -1, input_fd: -1, output_fd: -1, error_fd: -1)
        do {
            try validate(invocation)
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(invocation.timeoutSeconds) * 1_000_000_000
            guard !ownership.isCancelled else { return result(invocation, .notStarted) }
            let size: ProvisioningTerminalSize
            if streaming {
                guard let terminal else { return result(invocation, .notStarted) }
                size = try terminal.begin(invocation); terminalStarted = true
            } else { size = try ProvisioningTerminalSize(rows: 24, columns: 80) }
            defer { if terminalStarted { terminal?.end(invocation.id) } }
            guard !ownership.isCancelled else { return result(invocation, .notStarted) }
            let executable: URL
            if isTTY {
                guard let ptyLauncher else { return result(invocation, .notStarted) }
                executable = try ptyLauncher.verify()
            } else { executable = invocation.executable }
            let arguments = (isTTY ? [executable.path] : []) + [invocation.executable.path] + invocation.arguments
            let argv = arguments.map { strdup($0) }
            let env = invocation.environment.keys.sorted().map { strdup($0 + "=" + invocation.environment[$0]!) }
            defer { for pointer in argv + env { free(pointer) } }
            guard (argv + env).allSatisfy({ $0 != nil }) else { return result(invocation, .notStarted) }
            let error = (argv + [nil]).withUnsafeBufferPointer { argvBuffer in
                (env + [nil]).withUnsafeBufferPointer { envBuffer in
                    devvm_spawn(executable.path, argvBuffer.baseAddress!, envBuffer.baseAddress!,
                                invocation.workingDirectory.path, isTTY ? 1 : 0, Int32(size.rows), Int32(size.columns), &child)
                }
            }
            guard error == 0 else { return result(invocation, .notStarted) }
            return monitor(invocation, ownership: ownership, child: &child, isTTY: isTTY, streaming: streaming, deadline: deadline)
        } catch { return result(invocation, .notStarted) }
    }

    private func monitor(_ invocation: ProvisioningProcessInvocation, ownership: LocalProcessOwnership,
                         child: inout devvm_child, isTTY: Bool, streaming: Bool, deadline: UInt64) -> ProvisioningProcessResult {
        var reason = ProvisioningExitReason.normal
        var stopTime: UInt64?
        var killed = false
        var leaderExited = false
        var exitObservedAt: UInt64?
        var status: Int32 = 0
        var output = Data(), errors = Data(), input = Data()
        if case .bytes(let bytes) = invocation.input { input = bytes }
        if !isTTY, input.isEmpty { close(child.input_fd); child.input_fd = -1 }

        func stop(_ failure: ProvisioningExitReason) {
            if stopTime == nil {
                reason = failure; stopTime = DispatchTime.now().uptimeNanoseconds
                _ = kill(-child.pid, SIGTERM)
            }
        }
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            let observed = devvm_observe(child.pid, &status)
            if observed < 0 {
                // A foreign SIGCHLD reaper invalidates our ownership guarantee.
                ownership.uncertain = child
                return result(invocation, .cleanupUnconfirmed)
            }
            leaderExited = observed == 1
            if leaderExited, exitObservedAt == nil { exitObservedAt = now }
            if ownership.isCancelled { stop(.cancelled) }
            if now >= deadline { stop(.timedOut) }
            if leaderExited, stopTime == nil {
                // Parent exit does not mean its background children have exited.
                // Clean only its reserved group, before reaping the leader.
                let live = devvm_group_live(child.pid)
                if live < 0 { stop(.ioFailure) }
                else if live > 0 { stop(.ioFailure) }
            }
            if let ended = exitObservedAt, now > ended + 250_000_000,
               child.output_fd >= 0 || child.error_fd >= 0 { stop(.ioFailure) }
            if let stopped = stopTime, now >= stopped + 150_000_000, !killed {
                _ = kill(-child.pid, SIGKILL); killed = true
            }
            if !leaderExited, stopTime == nil {
                if isTTY {
                    if terminal?.flushInput(invocation.id, fd: child.input_fd) != true { stop(.ioFailure) }
                } else if child.input_fd >= 0 {
                    let n = input.withUnsafeBytes { Darwin.write(child.input_fd, $0.baseAddress, min($0.count, 4096)) }
                    if n > 0 { input.removeFirst(n) }
                    else if n < 0, errno != EAGAIN, errno != EINTR { stop(.ioFailure) }
                    if input.isEmpty { close(child.input_fd); child.input_fd = -1 }
                }
            }
            for (fd, channel) in [(child.output_fd, isTTY ? ProvisioningTerminalChannel.pty : .stdout), (child.error_fd, .stderr)] {
                if fd < 0 { continue }
                for _ in 0..<8 { // Bounded drain work: floods cannot starve cancellation.
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let n = read(fd, &buffer, buffer.count)
                    if n > 0 {
                        let data = Data(buffer.prefix(n))
                        if streaming { terminal?.publish(invocation.id, channel: channel, bytes: data) }
                        else {
                            let remaining = invocation.maximumCapturedBytes - output.count - errors.count
                            if channel == .stderr { errors.append(data.prefix(remaining)) } else { output.append(data.prefix(remaining)) }
                            if n > remaining { stop(.outputLimit) }
                        }
                    } else {
                        if n == 0 || (isTTY && errno == EIO) {
                            closeOutput(fd, child: &child)
                        } else if errno != EAGAIN, errno != EINTR { stop(.ioFailure) }
                        break
                    }
                }
            }
            if leaderExited, devvm_group_live(child.pid) == 0, child.output_fd < 0, child.error_fd < 0 {
                guard devvm_reap(child.pid) == 0 else {
                    ownership.uncertain = child; return result(invocation, .cleanupUnconfirmed)
                }
                closeDescriptors(&child)
                return result(invocation, .exited(status: status, reason: reason), stdout: output, stderr: errors)
            }
            if let stopped = stopTime, now >= stopped + 2_000_000_000 {
                ownership.uncertain = child
                return result(invocation, .cleanupUnconfirmed)
            }
            // No synchronous viewer calls or async waits while owning descriptors.
            var wait = pollfd(fd: child.output_fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&wait, 1, 10)
        }
    }
}

private func closeDescriptors(_ child: inout devvm_child) {
    for fd in Set([child.input_fd, child.output_fd, child.error_fd]) where fd >= 0 { close(fd) }
    child.input_fd = -1; child.output_fd = -1; child.error_fd = -1
}
private func closeOutput(_ fd: Int32, child: inout devvm_child) {
    close(fd)
    if child.input_fd == fd { child.input_fd = -1 }
    if child.output_fd == fd { child.output_fd = -1 }
    if child.error_fd == fd { child.error_fd = -1 }
}
private func discardPendingOutput(_ child: inout devvm_child) {
    for fd in [child.output_fd, child.error_fd] where fd >= 0 {
        for _ in 0..<8 {
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = read(fd, &bytes, bytes.count)
            if count == 0 || (count < 0 && errno == EIO) { closeOutput(fd, child: &child); break }
            if count < 0 { break }
        }
    }
}
