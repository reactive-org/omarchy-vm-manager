import Darwin
import Foundation

/// Same-user private socket security matches the existing command endpoint.
/// Dedicated length-framed, multi-request protocol; control.sock is unchanged.
public final class ProvisioningExternalServer: @unchecked Sendable {
    private let endpoint: ManagerCommandEndpoint
    private let listener: Int32
    private let inode: ino_t
    private let service: any ProvisioningObserving
    private let lock = NSLock()
    private var stopped = false
    private var sockets: [UUID: ProvisioningHelperSocket] = [:]
    public init(endpoint base: ManagerCommandEndpoint, service: any ProvisioningObserving) throws {
        let endpoint = base.provisioning
        self.endpoint = endpoint; self.service = service
        try PrivateFiles.directory(endpoint.directory, create: true)
        var info = stat()
        if lstat(endpoint.socket.path, &info) == 0 {
            try endpoint.validateSocket()
            let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw ProvisioningTerminalDenial.unavailable }
            defer { Darwin.close(probe) }
            CommandSocketIO.configure(probe)
            var address = try CommandSocketIO.address(endpoint.socket.path)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            let saved = errno
            var current = stat()
            guard result < 0, saved == ECONNREFUSED, lstat(endpoint.socket.path, &current) == 0,
                  current.st_ino == info.st_ino, current.st_dev == info.st_dev, unlink(endpoint.socket.path) == 0 else { throw ProvisioningTerminalDenial.busy }
        } else if errno != ENOENT { throw ProvisioningTerminalDenial.unavailable }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProvisioningTerminalDenial.unavailable }
        do {
            CommandSocketIO.configure(fd)
            var address = try CommandSocketIO.address(endpoint.socket.path)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0, chmod(endpoint.socket.path, 0o600) == 0, listen(fd, 8) == 0,
                  lstat(endpoint.socket.path, &info) == 0 else { throw ProvisioningTerminalDenial.unavailable }
            listener = fd; inode = info.st_ino
        } catch { Darwin.close(fd); throw error }
        DispatchQueue.global(qos: .utility).async { [self] in accept() }
    }
    public func stop() {
        let values = lock.withLock { () -> [ProvisioningHelperSocket]? in
            guard !stopped else { return nil }; stopped = true; return Array(sockets.values)
        }
        guard let values else { return }
        _ = Darwin.shutdown(listener, SHUT_RDWR); values.forEach { $0.stop() }
    }
    private func accept() {
        defer {
            Darwin.close(listener)
            var info = stat()
            if lstat(endpoint.socket.path, &info) == 0, info.st_ino == inode, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK { unlink(endpoint.socket.path) }
        }
        while !lock.withLock({ stopped }) {
            var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 100) > 0, !lock.withLock({ stopped }) else { continue }
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            guard let socket = try? ProvisioningHelperSocket(taking: fd) else { continue }
            let id = UUID()
            let admitted = lock.withLock { if stopped || sockets.count >= 8 { return false }; sockets[id] = socket; return true }
            guard admitted else { socket.stop(); continue }
            Task.detached { [self] in
                let session = ProvisioningExternalSession(service: service)
                let activity = ProvisioningExternalActivity()
                let monitor = Task {
                    while !Task.isCancelled {
                        if socket.peerClosed || activity.expired { socket.stop(); await session.close(); return }
                        do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                    }
                }
                do {
                    while !Task.isCancelled {
                        let data = try await helperBlocking { try socket.receive(idle: true) }
                        let request = try ProvisioningExternalRequest.decode(data)
                        activity.touch()
                        let response = try await session.handle(request)
                        let bytes = try helperJSON(response)
                        guard bytes.count <= 128 * 1024 else { throw ProvisioningTerminalDenial.bounds }
                        try await helperBlocking { try socket.send(bytes) }
                    }
                } catch { /* Fixed public failures only; no packets/bytes logged. */ }
                monitor.cancel(); socket.stop(); await session.close()
                _ = lock.withLock { sockets.removeValue(forKey: id) }
            }
        }
    }
}
private final class ProvisioningExternalActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var time = ContinuousClock.now
    var expired: Bool { lock.withLock { ContinuousClock.now - time > .seconds(15) } }
    func touch() { lock.withLock { time = .now } }
}

/// A lost reply poisons this connection. No reconnect or mutation replay. The
/// helper's tokens stay inside the server-side attachment, never on this wire.
public actor ProvisioningExternalClient {
    private let endpoint: ManagerCommandEndpoint
    private var socket: ProvisioningHelperSocket?
    private var sequence: UInt64 = 0
    private var inFlight = false, closed = false
    public init(endpoint: ManagerCommandEndpoint) { self.endpoint = endpoint.provisioning }
    deinit { socket?.stop() }
    public func close() { closed = true; socket?.stop(); socket = nil }
    public func request(_ operation: ProvisioningExternalOperation, workflowID: UUID? = nil, invocationID: UUID? = nil,
                        bytes: Data? = nil, rows: Int? = nil, columns: Int? = nil,
                        previewID: UUID? = nil, vmID: UUID? = nil, source: ProvisioningSetupSource? = nil,
                        consent: ProvisioningApplyConsent? = nil, taskName: String? = nil, offset: Int? = nil,
                        action: ProvisioningWorkflowAction? = nil, actionReviewID: UUID? = nil, actionConsent: ProvisioningWorkflowActionConsent? = nil) async throws -> ProvisioningExternalReply {
        guard !inFlight, !closed, sequence < UInt64(Int64.max) - 1 else { throw ProvisioningTerminalDenial.busy }
        inFlight = true; defer { inFlight = false }
        var request = ProvisioningExternalRequest(sequence: sequence + 1, operation: operation, workflowID: workflowID)
        request.action = action; request.actionReviewID = actionReviewID; request.actionConsent = actionConsent
        request.previewID = previewID; request.vmID = vmID; request.source = source; request.consent = consent; request.taskName = taskName; request.offset = offset
        request.invocationID = invocationID; request.bytes = bytes; request.rows = rows; request.columns = columns
        let payload = try helperJSON(request)
        _ = try ProvisioningExternalRequest.decode(payload)
        sequence += 1
        do {
            if socket == nil {
                let endpoint = endpoint
                let value = try await helperBlocking {
                    try endpoint.validateSocket()
                    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                    guard fd >= 0 else { throw ProvisioningTerminalDenial.unavailable }
                    do { try CommandSocketIO.connect(fd, path: endpoint.socket.path) }
                    catch { Darwin.close(fd); throw error }
                    return try ProvisioningHelperSocket(taking: fd)
                }
                guard !closed else { value.stop(); throw ProvisioningTerminalDenial.unavailable }
                socket = value
            }
            let socket = socket!
            let response = try await helperBlocking { try socket.send(payload); return try socket.receive() }
            guard !closed else { throw ProvisioningTerminalDenial.unavailable }
            return try .decode(response, request: request)
        } catch { close(); throw ProvisioningTerminalDenial.unavailable }
    }
}
