import Darwin
import Foundation

struct ProvisioningExecutable: Equatable, Sendable {
    let identity: ProvisioningToolIdentity
    let firstLine: String?
}

protocol ProvisioningToolFiles: Sendable {
    func executable(_ path: String) -> ProvisioningExecutable?
}

struct LocalProvisioningToolFiles: ProvisioningToolFiles {
    func executable(_ path: String) -> ProvisioningExecutable? {
        guard ProvisioningToolConfiguration.validPath(path) else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o111 != 0, access(resolved, X_OK) == 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = read(fd, &bytes, bytes.count)
        guard count >= 0 else { return nil }
        let head = Data(bytes.prefix(count))
        let firstLine = head.starts(with: [35, 33]) ? String(data: head.prefix(while: { $0 != 10 }), encoding: .utf8) : nil
        let metadata = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mode):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        // Include the launcher prefix as well as inode/timestamps; this is a change
        // detector, not a provenance or cryptographic admission claim for host tools.
        let fingerprint = KitVerifier.sha256(Data((resolved + ":" + metadata).utf8) + head)
        // Preserve the entry path: resolving a virtualenv's python symlink before
        // execution would bypass its pyvenv.cfg and select the wrong packages.
        return ProvisioningExecutable(identity: .init(path: URL(fileURLWithPath: path).standardized.path, fingerprint: fingerprint), firstLine: firstLine)
    }
}

struct ProvisioningProbeRequest: Sendable {
    let executable: ProvisioningToolIdentity
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String
    var timeout: TimeInterval = 5
    var outputLimit = 32768
}

struct ProvisioningProbeResult: Sendable {
    enum Failure: String, Sendable { case launch, timeout, outputLimit, changed, cancelled }
    var status: Int32 = 0
    var output = Data()
    var failure: Failure?
    static func failed(_ reason: Failure) -> Self { Self(failure: reason) }
}

protocol ProvisioningToolProbing: Sendable {
    func run(_ request: ProvisioningProbeRequest) async -> ProvisioningProbeResult
}

private final class ProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.withLock { value = true } }
    var cancelled: Bool { lock.withLock { value } }
}

/// Executes fixed read-only probes in their own process group. Both output streams
/// share a bounded pipe; no output or inherited environment is logged.
struct LocalProvisioningToolProbe: ProvisioningToolProbing {
    func run(_ request: ProvisioningProbeRequest) async -> ProvisioningProbeResult {
        let cancellation = ProbeCancellation()
        return await withTaskCancellationHandler {
            await Task.detached { Self.execute(request, cancellation: cancellation) }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func execute(_ request: ProvisioningProbeRequest, cancellation: ProbeCancellation) -> ProvisioningProbeResult {
        let files = LocalProvisioningToolFiles()
        guard files.executable(request.executable.path)?.identity == request.executable else { return .failed(.changed) }
        guard !cancellation.cancelled else { return .failed(.cancelled) }
        let pipe = Pipe(), reader = pipe.fileHandleForReading.fileDescriptor, writer = pipe.fileHandleForWriting.fileDescriptor
        let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard null >= 0 else { return .failed(.launch) }
        defer { close(null) }
        _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failed(.launch) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return .failed(.launch) }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, writer, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, reader) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, request.workingDirectory) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { return .failed(.launch) }
        let argv = ([request.executable.path] + request.arguments).map { strdup($0) } + [nil]
        let envp = request.environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for value in argv + envp { free(value) } }
        var pid: pid_t = 0
        let code = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, request.executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard code == 0 else { return .failed(.launch) }
        try? pipe.fileHandleForWriting.close()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(request.timeout * 1000)))
        var output = Data(), status: Int32 = 0, exited = false
        defer {
            // A probe may fork a child that retains its pipe after the parent exits.
            // Probe completion always disposes of that private process group.
            _ = kill(-pid, SIGKILL)
            if !exited { while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
        }
        while true {
            if cancellation.cancelled { return .failed(.cancelled) }
            if ContinuousClock.now >= deadline { return .failed(.timeout) }
            var event = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
            _ = poll(&event, 1, 20)
            var buffer = [UInt8](repeating: 0, count: 4096)
            // A finite drain also lets timeout/cancellation run for noisy children.
            for _ in 0..<8 {
                let count = read(reader, &buffer, buffer.count)
                if count <= 0 { break }
                output.append(contentsOf: buffer.prefix(count))
                if output.count > request.outputLimit { return .failed(.outputLimit) }
            }
            if !exited { exited = waitpid(pid, &status, WNOHANG) == pid }
            if exited {
                // Drain only the bounded available tail, never wait for a descendant.
                while true {
                    let count = read(reader, &buffer, buffer.count)
                    if count <= 0 { break }
                    output.append(contentsOf: buffer.prefix(count))
                    if output.count > request.outputLimit { return .failed(.outputLimit) }
                    if cancellation.cancelled { return .failed(.cancelled) }
                    if ContinuousClock.now >= deadline { return .failed(.timeout) }
                }
                guard files.executable(request.executable.path)?.identity == request.executable else { return .failed(.changed) }
                // Darwin's wait status: low seven bits are the terminating signal.
                return .init(status: status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f), output: output)
            }
        }
    }
}
