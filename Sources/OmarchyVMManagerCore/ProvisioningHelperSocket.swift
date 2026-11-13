import Darwin
import Foundation

/// Owns exactly one inherited AF_UNIX stream. No path listener, reconnect,
/// PID lookup, descriptor replacement or automatic mutation retry.
final class ProvisioningHelperSocket: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    let timeout: Duration
    init(taking fd: Int32, timeout: Duration = .seconds(3)) throws {
        self.fd = fd; self.timeout = timeout
        do {
            guard fd >= 0, timeout > .zero, timeout <= .seconds(5) else { throw ProvisioningHelperIPCFailure.unavailable }
            var kind: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size), uid: uid_t = 0, gid: gid_t = 0
            guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &length) == 0, kind == SOCK_STREAM,
                  getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw ProvisioningHelperIPCFailure.authentication }
            var address = sockaddr_un(), size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
            }
            guard result == 0, address.sun_family == sa_family_t(AF_UNIX), fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw ProvisioningHelperIPCFailure.authentication }
            let flags = fcntl(fd, F_GETFL)
            var enabled: Int32 = 1
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        } catch { if fd >= 0 { Darwin.close(fd) }; throw error }
    }
    deinit { Darwin.close(fd) }
    func stop() {
        lock.withLock {
            if !stopped { stopped = true; _ = Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }
    var peerClosed: Bool {
        if lock.withLock({ stopped }) { return true }
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&event, 1, 0) > 0, event.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        let count = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)
    }
    func receive(idle: Bool = false, wait: Duration? = nil) throws -> Data {
        // Idle waiting is interruptible by shutdown; a partially sent frame has
        // an absolute deadline and cannot extend it by trickling more bytes.
        let allowed = wait ?? timeout
        guard allowed > .zero, allowed <= .seconds(120) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        let transactionEnd = ContinuousClock.now + allowed
        let first = try Self.readExact(fd, count: 1, deadline: idle ? nil : transactionEnd)
        let end = idle ? ContinuousClock.now + allowed : transactionEnd
        let prefix = first + (try Self.readExact(fd, count: 3, deadline: end))
        let count = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= ProvisioningHelperFrameCodec.maximumFrameBytes else { throw ProvisioningHelperIPCFailure.protocolViolation }
        return try Self.readExact(fd, count: count, deadline: end)
    }
    func finishSending() { _ = Darwin.shutdown(fd, SHUT_WR) }
    func requireEOF(wait: Duration? = nil) throws {
        let allowed = wait ?? timeout
        guard allowed > .zero, allowed <= .seconds(5) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        let end = ContinuousClock.now + allowed
        while ContinuousClock.now < end {
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 20) < 0 { if errno == EINTR { continue }; throw ProvisioningHelperIPCFailure.unavailable }
            var byte: UInt8 = 0
            let count = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count == 0 { return }
            guard count < 0, errno == EAGAIN || errno == EINTR else { throw ProvisioningHelperIPCFailure.protocolViolation }
        }
        throw ProvisioningHelperIPCFailure.timeout
    }
    func send(_ data: Data, wait: Duration? = nil) throws {
        guard !data.isEmpty, data.count <= ProvisioningHelperFrameCodec.maximumFrameBytes else { throw ProvisioningHelperIPCFailure.protocolViolation }
        let size = UInt32(data.count)
        var packet = Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        packet.append(data)
        let allowed = wait ?? timeout
        guard allowed > .zero, allowed <= .seconds(5) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        let end = ContinuousClock.now + allowed
        try packet.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Self.ready(fd, event: Int16(POLLOUT), deadline: end)
                let n = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                guard n > 0 else { throw ProvisioningHelperIPCFailure.unavailable }
                offset += n
            }
        }
    }
    /// The one-time bootstrap is accepted only from a pipe, with bounded bytes,
    /// deadline and exact framing. Neither a TTY nor a saved credential file.
    static func bootstrapFromPipe(_ fd: Int32) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { throw ProvisioningHelperIPCFailure.authentication }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        let end = ContinuousClock.now + .seconds(3)
        let prefix = try readExact(fd, count: 4, deadline: end, pipe: true)
        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 4096 else { throw ProvisioningHelperIPCFailure.protocolViolation }
        return try readExact(fd, count: length, deadline: end, pipe: true)
    }
    private static func readExact(_ fd: Int32, count: Int, deadline: ContinuousClock.Instant?, pipe: Bool = false) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count), offset = 0
        while offset < count {
            try ready(fd, event: Int16(POLLIN), deadline: deadline)
            let n = bytes.withUnsafeMutableBytes { buffer in
                pipe ? Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                     : Darwin.recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if n < 0, errno == EINTR || errno == EAGAIN { continue }
            guard n > 0 else { throw ProvisioningHelperIPCFailure.unavailable }
            offset += n
        }
        return Data(bytes)
    }
    private static func ready(_ fd: Int32, event: Int16, deadline: ContinuousClock.Instant?) throws {
        while deadline == nil || ContinuousClock.now < deadline! {
            var value = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&value, 1, 20)
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw ProvisioningHelperIPCFailure.unavailable }
            if result > 0 { return } // recv/send classifies EOF/errors, including HUP.
        }
        throw ProvisioningHelperIPCFailure.timeout
    }
}

func helperBlocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(with: Result(catching: body)) }
    }
}
