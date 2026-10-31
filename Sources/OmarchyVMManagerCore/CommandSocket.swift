import Darwin
import Foundation

public struct ManagerCommandEndpoint: Sendable {
    public let directory: URL
    public var socket: URL { directory.appendingPathComponent("control.sock") }
    public init(applicationSupport: URL) {
        let identity = KitVerifier.sha256(Data(applicationSupport.resolvingSymlinksInPath().path.utf8)).prefix(16)
        directory = URL(fileURLWithPath: "/private/tmp/omarchy-manager-\(getuid())-\(identity)")
    }
    public init(directory: URL) { self.directory = directory }
    func validateSocket() throws {
        var value = stat()
        if lstat(directory.path, &value) != 0, errno == ENOENT { throw commandFailure("manager-unavailable", "The manager is not running.") }
        try PrivateFiles.directory(directory)
        if lstat(socket.path, &value) != 0, errno == ENOENT { throw commandFailure("manager-unavailable", "The manager is not serving commands.") }
        guard value.st_mode & S_IFMT == S_IFSOCK, value.st_uid == getuid(), value.st_mode & 0o7777 == 0o600 else {
            throw commandFailure("unsafe-command-endpoint", "The command endpoint is unsafe and was preserved.")
        }
    }
}

private enum CommandSocketIO {
    static let requestLimit = 32768
    static let responseLimit = 1_048_576
    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un(); value.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw commandFailure("socket-path-too-long", "The command socket path is too long.") }
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: bytes) }
        return value
    }
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }
    static func connect(_ fd: Int32, path: String) throws {
        configure(fd)
        var address = try address(path)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if result == 0 { return }
        guard errno == EINPROGRESS else { throw commandFailure("manager-unavailable", "The manager is not serving commands.") }
        var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var failure: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
        guard poll(&event, 1, 2000) > 0, getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length) == 0, failure == 0 else {
            throw commandFailure("manager-unavailable", "The manager command connection could not be established.")
        }
    }
    static func sameUser(_ fd: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw commandFailure("peer-refused", "The command peer is not this user.") }
    }
    static func read(_ fd: Int32, maximum: Int, timeout: Int) throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline {
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let count = poll(&event, 1, 250)
            if count < 0 { if errno == EINTR { continue }; break }
            if count == 0 { continue }
            let n = Darwin.recv(fd, &buffer, buffer.count, 0)
            if n < 0, errno == EAGAIN || errno == EINTR { continue }
            guard n > 0 else { throw commandFailure("manager-disconnected", "The command connection closed before its response. Do not automatically repeat a mutation.") }
            data.append(contentsOf: buffer.prefix(n))
            if let newline = data.firstIndex(of: 10) {
                guard newline <= maximum else { throw commandFailure("message-too-large", "The command message exceeds its limit.") }
                return Data(data[..<newline])
            }
            guard data.count <= maximum else { throw commandFailure("message-too-large", "The command message exceeds its limit.") }
        }
        throw commandFailure("transport-timeout", "The command connection timed out. Its outcome may be unknown; inspect the guest before retrying a mutation.")
    }
    static func write(_ fd: Int32, data: Data) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count, ContinuousClock.now < deadline {
                var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&event, 1, 250)
                if ready < 0, errno == EINTR { continue }
                guard ready >= 0 else { break }
                if ready == 0 { continue }
                let n = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                guard n > 0 else { break }
                offset += n
            }
            guard offset == bytes.count else { throw commandFailure("manager-disconnected", "The command message could not be delivered completely. Do not automatically repeat a mutation.") }
        }
    }
}

private final class CommandConnection: @unchecked Sendable {
    let fd: Int32
    init(_ fd: Int32) { self.fd = fd; CommandSocketIO.configure(fd) }
    deinit { Darwin.close(fd) }
    func shutDown() { _ = Darwin.shutdown(fd, SHUT_RDWR) }
    var disconnected: Bool {
        var byte: UInt8 = 0
        let n = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)
    }
}

public final class ManagerCommandServer: @unchecked Sendable {
    private let endpoint: ManagerCommandEndpoint
    private let listener: Int32
    private let identity: ino_t
    private let handler: @Sendable (GuestCommandRequest) async -> GuestCommandResponse
    private let lock = NSLock()
    private var stopped = false
    private var connections: [UUID: CommandConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(endpoint: ManagerCommandEndpoint, handler: @escaping @Sendable (GuestCommandRequest) async -> GuestCommandResponse) throws {
        self.endpoint = endpoint; self.handler = handler
        try PrivateFiles.directory(endpoint.directory, create: true)
        var info = stat()
        if lstat(endpoint.socket.path, &info) == 0 {
            try endpoint.validateSocket()
            let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            CommandSocketIO.configure(probe)
            guard probe >= 0 else { throw commandFailure("socket-unavailable", "Cannot create a local socket.") }
            var address = try CommandSocketIO.address(endpoint.socket.path)
            let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            let savedError = errno; Darwin.close(probe)
            guard connected != 0, savedError == ECONNREFUSED, unlink(endpoint.socket.path) == 0 else { throw commandFailure("manager-already-serving", "A command server is already active or its endpoint changed.") }
        } else if errno != ENOENT { throw commandFailure("socket-unavailable", "Cannot inspect the local command endpoint.") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw commandFailure("socket-unavailable", "Cannot create the local command listener.") }
        do {
            var address = try CommandSocketIO.address(endpoint.socket.path)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0 else { throw commandFailure("socket-unavailable", "Cannot bind the private command endpoint.") }
            guard chmod(endpoint.socket.path, 0o600) == 0, listen(fd, 16) == 0, lstat(endpoint.socket.path, &info) == 0 else { throw commandFailure("socket-unavailable", "Cannot secure the local command listener.") }
            listener = fd; identity = info.st_ino
            CommandSocketIO.configure(fd)
        } catch { Darwin.close(fd); throw error }
        DispatchQueue.global(qos: .utility).async { [self] in acceptConnections() }
    }
    public func stop() {
        let active: ([CommandConnection], [Task<Void, Never>])? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            return (Array(connections.values), Array(tasks.values))
        }
        guard let active else { return }
        _ = Darwin.shutdown(listener, SHUT_RDWR)
        active.0.forEach { $0.shutDown() }; active.1.forEach { $0.cancel() }
    }
    private func acceptConnections() {
        defer {
            Darwin.close(listener)
            var info = stat()
            if lstat(endpoint.socket.path, &info) == 0, info.st_ino == identity, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK { unlink(endpoint.socket.path) }
        }
        while !lock.withLock({ stopped }) {
            var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 250) > 0, !lock.withLock({ stopped }) else { continue }
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            let connection = CommandConnection(fd), id = UUID()
            let accepted = lock.withLock { if stopped || connections.count >= 16 { return false }; connections[id] = connection; return true }
            guard accepted else { connection.shutDown(); continue }
            DispatchQueue.global(qos: .utility).async { [self] in receive(connection, id: id) }
        }
    }
    private func receive(_ connection: CommandConnection, id: UUID) {
        do {
            try CommandSocketIO.sameUser(connection.fd)
            let data = try CommandSocketIO.read(connection.fd, maximum: CommandSocketIO.requestLimit, timeout: 10)
            let request = try GuestCommandRequest.decodeStrict(data)
            lock.withLock {
                let task = Task { [self] in
                    let monitor = Task {
                        while !Task.isCancelled {
                            if connection.disconnected { self.cancel(id); return }
                            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                        }
                    }
                    let response = await handler(request)
                    monitor.cancel()
                    send(response, connection: connection)
                    lock.withLock { connections[id] = nil; tasks[id] = nil }
                }
                tasks[id] = task
                if stopped { task.cancel(); connection.shutDown() }
            }
        } catch {
            let failure = error as? VMFailure ?? commandFailure("invalid-request", "The command is malformed or unsupported.")
            send(GuestCommandResponse(requestID: UUID(), ok: false, error: GuestCommandFailure(code: failure.code, message: failure.message)), connection: connection)
            lock.withLock { connections[id] = nil }
        }
    }
    private func cancel(_ id: UUID) { lock.withLock { tasks[id]?.cancel() } }
    private func send(_ response: GuestCommandResponse, connection: CommandConnection) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(response), data.count <= CommandSocketIO.responseLimit else {
            let fallback = GuestCommandResponse(requestID: response.requestID, ok: false, error: GuestCommandFailure(code: "response-too-large", message: "The response exceeds its size limit. Query individual guests."))
            if let bytes = try? encoder.encode(fallback) { try? CommandSocketIO.write(connection.fd, data: bytes + Data([10])) }
            return
        }
        try? CommandSocketIO.write(connection.fd, data: data + Data([10]))
    }
}

public struct ManagerCommandClient: Sendable {
    public let endpoint: ManagerCommandEndpoint
    public init(endpoint: ManagerCommandEndpoint) { self.endpoint = endpoint }
    public func send(_ request: GuestCommandRequest) throws -> GuestCommandResponse {
        try request.validate(); try endpoint.validateSocket()
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw commandFailure("socket-unavailable", "Cannot create a command connection.") }
        defer { Darwin.close(fd) }
        try CommandSocketIO.connect(fd, path: endpoint.socket.path)
        try CommandSocketIO.sameUser(fd)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        guard data.count <= CommandSocketIO.requestLimit else { throw commandFailure("message-too-large", "The request exceeds its size limit.") }
        try CommandSocketIO.write(fd, data: data + Data([10]))
        let bytes = try CommandSocketIO.read(fd, maximum: CommandSocketIO.responseLimit, timeout: request.timeoutSeconds + 30)
        guard let response = try? JSONDecoder().decode(GuestCommandResponse.self, from: bytes), response.version == 1,
              response.requestID == request.requestID else { throw commandFailure("invalid-response", "The manager response is malformed or does not match this command.") }
        return response
    }
}
