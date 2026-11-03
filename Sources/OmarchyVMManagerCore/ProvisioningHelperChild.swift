import Darwin
import Foundation

/// Waitable child created by this launcher, never reconstructed from a PID.
final class ProvisioningHelperChild: @unchecked Sendable {
    enum Exit: Sendable, Equatable { case exited(Int32), unconfirmed }
    let identity = UUID()
    let pid: pid_t
    let socket: ProvisioningHelperSocket
    private let input: ProvisioningHelperSocket?
    let sessionSocket: ProvisioningHelperSocket?
    private let transportSocket: ProvisioningHelperSocket?
    let terminalSocket: ProvisioningHelperSocket?
    private let lock = NSLock()
    private var bootstrapFD: Int32
    private var exit: Exit?
    private var waiters: [CheckedContinuation<Exit, Never>] = []
    private init(pid: pid_t, socket: ProvisioningHelperSocket, writer: Int32, input: ProvisioningHelperSocket?, sessionSocket: ProvisioningHelperSocket?, transportSocket: ProvisioningHelperSocket?, terminalSocket: ProvisioningHelperSocket?) {
        self.pid = pid; self.socket = socket; bootstrapFD = writer; self.input = input; self.sessionSocket = sessionSocket; self.transportSocket = transportSocket; self.terminalSocket = terminalSocket
        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0, result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
            let observed: Exit = result == pid ? .exited(status) : .unconfirmed
            let callbacks = lock.withLock { exit = observed; let values = waiters; waiters.removeAll(); return values }
            callbacks.forEach { $0.resume(returning: observed) }
        }
    }
    deinit { if bootstrapFD >= 0 { Darwin.close(bootstrapFD) } }
    func waitForExit() async -> Exit {
        await withCheckedContinuation { continuation in
            lock.withLock { if let exit { continuation.resume(returning: exit) } else { waiters.append(continuation) } }
        }
    }
    func disconnect() {
        socket.stop(); input?.stop(); sessionSocket?.stop(); transportSocket?.stop(); terminalSocket?.stop()
        lock.withLock { if bootstrapFD >= 0 { Darwin.close(bootstrapFD); bootstrapFD = -1 } }
    }
    func deliver(_ data: Data) throws {
        guard let input else { throw ProvisioningJobFailure.artifactUnavailable }
        try ProvisioningFrozenChannel.send(data, over: input)
    }
    func deliverTransport(_ data: Data) throws {
        guard let transportSocket else { throw ProvisioningJobFailure.invalidRequest }; try ProvisioningFrozenChannel.send(data, over: transportSocket)
    }
    func bootstrap(_ data: Data) throws {
        try lock.withLock {
            guard bootstrapFD >= 0, exit == nil, data.count <= 4096 else { throw ProvisioningHelperIPCFailure.unavailable }
            defer { Darwin.close(bootstrapFD); bootstrapFD = -1 }
            let size = UInt32(data.count)
            let packet = Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + data
            let end = ContinuousClock.now + .seconds(3)
            try packet.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count, ContinuousClock.now < end {
                    var event = pollfd(fd: bootstrapFD, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&event, 1, 20)
                    if ready < 0, errno == EINTR { continue }
                    guard ready >= 0 else { throw ProvisioningHelperIPCFailure.unavailable }
                    if ready == 0 { continue }
                    let count = Darwin.write(bootstrapFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EAGAIN || errno == EINTR { continue }
                    guard count > 0 else { throw ProvisioningHelperIPCFailure.unavailable }
                    offset += count
                }
                guard offset == bytes.count else { throw ProvisioningHelperIPCFailure.timeout }
            }
        }
    }
    static func spawn(admission: ProvisioningHelperLaunchAdmission, directory: URL, hasDelivery: Bool = false, hasSessionAuthority: Bool = false, hasTransport: Bool = false, hasTerminal: Bool = false) throws -> ProvisioningHelperChild {
        try admission.revalidate(); try PrivateFiles.directory(directory)
        var pair = [Int32](repeating: -1, count: 2), bootstrap = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        defer { if pair[1] >= 0 { Darwin.close(pair[1]) } }
        guard fcntl(pair[1], F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(pair[0]); throw ProvisioningHelperIPCFailure.unavailable }
        let parent = try ProvisioningHelperSocket(taking: pair[0])
        guard pipe(&bootstrap) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        defer { if bootstrap[0] >= 0 { Darwin.close(bootstrap[0]) }; if bootstrap[1] >= 0 { Darwin.close(bootstrap[1]) } }
        guard fcntl(bootstrap[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(bootstrap[1], F_SETFD, FD_CLOEXEC) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        var inputPair = [Int32](repeating: -1, count: 2)
        defer { if inputPair[1] >= 0 { Darwin.close(inputPair[1]) } }
        var input: ProvisioningHelperSocket?
        if hasDelivery {
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &inputPair) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
            guard fcntl(inputPair[1], F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(inputPair[0]); throw ProvisioningHelperIPCFailure.unavailable }
            input = try ProvisioningHelperSocket(taking: inputPair[0])
        }
        let inputSource = hasDelivery ? fcntl(inputPair[1], F_DUPFD_CLOEXEC, 10) : -1
        defer { if inputSource >= 0 { Darwin.close(inputSource) } }
        guard !hasDelivery || inputSource >= 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        var sessionPair = [Int32](repeating: -1, count: 2)
        defer { if sessionPair[1] >= 0 { Darwin.close(sessionPair[1]) } }
        var sessionSocket: ProvisioningHelperSocket?
        if hasSessionAuthority {
            guard hasDelivery, socketpair(AF_UNIX, SOCK_STREAM, 0, &sessionPair) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
            guard fcntl(sessionPair[1], F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(sessionPair[0]); throw ProvisioningHelperIPCFailure.unavailable }
            sessionSocket = try ProvisioningHelperSocket(taking: sessionPair[0])
        }
        let sessionSource = hasSessionAuthority ? fcntl(sessionPair[1], F_DUPFD_CLOEXEC, 10) : -1
        defer { if sessionSource >= 0 { Darwin.close(sessionSource) } }
        guard !hasSessionAuthority || sessionSource >= 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        var transportPair = [Int32](repeating: -1, count: 2)
        defer { if transportPair[1] >= 0 { Darwin.close(transportPair[1]) } }
        var transportSocket: ProvisioningHelperSocket?
        if hasTransport {
            guard hasSessionAuthority, socketpair(AF_UNIX, SOCK_STREAM, 0, &transportPair) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
            guard fcntl(transportPair[1], F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(transportPair[0]); throw ProvisioningHelperIPCFailure.unavailable }
            transportSocket = try ProvisioningHelperSocket(taking: transportPair[0])
        }
        let transportSource = hasTransport ? fcntl(transportPair[1], F_DUPFD_CLOEXEC, 10) : -1
        defer { if transportSource >= 0 { Darwin.close(transportSource) } }
        guard !hasTransport || transportSource >= 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        var terminalPair = [Int32](repeating: -1, count: 2)
        defer { if terminalPair[1] >= 0 { Darwin.close(terminalPair[1]) } }
        var terminalSocket: ProvisioningHelperSocket?
        if hasTerminal {
            guard hasTransport, socketpair(AF_UNIX, SOCK_STREAM, 0, &terminalPair) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
            guard fcntl(terminalPair[1], F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(terminalPair[0]); throw ProvisioningHelperIPCFailure.unavailable }
            terminalSocket = try ProvisioningHelperSocket(taking: terminalPair[0])
        }
        let terminalSource = hasTerminal ? fcntl(terminalPair[1], F_DUPFD_CLOEXEC, 10) : -1
        defer { if terminalSource >= 0 { Darwin.close(terminalSource) } }
        guard !hasTerminal || terminalSource >= 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        // Sources above stdio/control avoid dup2 aliasing. CLOEXEC_DEFAULT closes
        // every unrelated descriptor; only 0/1/2/3 and optional 4/5/6/7 are explicitly inherited.
        let sourceSocket = fcntl(pair[1], F_DUPFD_CLOEXEC, 10), sourceInput = fcntl(bootstrap[0], F_DUPFD_CLOEXEC, 10)
        defer { if sourceSocket >= 0 { Darwin.close(sourceSocket) }; if sourceInput >= 0 { Darwin.close(sourceInput) } }
        let null = open("/dev/null", O_RDWR | O_CLOEXEC)
        defer { if null >= 0 { Darwin.close(null) } }
        guard sourceSocket >= 0, sourceInput >= 0, null >= 0,
              fcntl(bootstrap[1], F_SETFD, FD_CLOEXEC) == 0, fcntl(bootstrap[1], F_SETNOSIGPIPE, 1) == 0,
              fcntl(bootstrap[1], F_SETFL, O_NONBLOCK) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_adddup2(&actions, sourceInput, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, null, 1) == 0,
              posix_spawn_file_actions_adddup2(&actions, null, 2) == 0,
              posix_spawn_file_actions_adddup2(&actions, sourceSocket, 3) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        if hasDelivery { guard posix_spawn_file_actions_adddup2(&actions, inputSource, 4) == 0 else { throw ProvisioningHelperIPCFailure.unavailable } }
        if hasSessionAuthority { guard posix_spawn_file_actions_adddup2(&actions, sessionSource, 5) == 0 else { throw ProvisioningHelperIPCFailure.unavailable } }
        if hasTransport { guard posix_spawn_file_actions_adddup2(&actions, transportSource, 6) == 0 else { throw ProvisioningHelperIPCFailure.unavailable } }
        if hasTerminal { guard posix_spawn_file_actions_adddup2(&actions, terminalSource, 7) == 0 else { throw ProvisioningHelperIPCFailure.unavailable } }
        let arguments = [admission.executable.path, "--ownership-channel-fd", "3"].map { strdup($0) } + [nil]
        let environment = ["PATH=/nonexistent", "LC_ALL=C", "HOME=" + directory.path, "TMPDIR=" + directory.path].map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
        var pid: pid_t = 0
        let result = arguments.withUnsafeBufferPointer { args in environment.withUnsafeBufferPointer { env in
            posix_spawn(&pid, admission.executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
        } }
        guard result == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        Darwin.close(pair[1]); pair[1] = -1; Darwin.close(bootstrap[0]); bootstrap[0] = -1
        let child = ProvisioningHelperChild(pid: pid, socket: parent, writer: bootstrap[1], input: input, sessionSocket: sessionSocket, transportSocket: transportSocket, terminalSocket: terminalSocket); bootstrap[1] = -1
        return child
    }
}
