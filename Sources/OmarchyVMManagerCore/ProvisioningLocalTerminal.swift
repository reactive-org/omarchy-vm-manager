import Darwin
import Foundation

/// Scoped CLI support, used only after deliberate interactive attachment. Own a
/// duplicate of the original TTY descriptor so restoration cannot touch a reused
/// descriptor number. No input read/logging, signal handlers or global stdio swap.
final class ProvisioningLocalTerminal: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var original: termios
    init(descriptor source: Int32) throws {
        let fd = fcntl(source, F_DUPFD_CLOEXEC, 10)
        guard fd >= 0 else { throw ProvisioningTerminalDenial.unavailable }
        var attributes = termios()
        guard isatty(fd) == 1, tcgetattr(fd, &attributes) == 0 else { close(fd); throw ProvisioningTerminalDenial.unavailable }
        descriptor = fd; original = attributes
        var raw = attributes; cfmakeraw(&raw)
        guard tcsetattr(fd, TCSANOW, &raw) == 0 else { close(fd); descriptor = -1; throw ProvisioningTerminalDenial.unavailable }
    }
    @discardableResult func restore() -> Bool {
        lock.withLock {
            guard descriptor >= 0 else { return true }
            // Retry EINTR; keep the duplicate for a later retry after an error.
            var result: Int32
            repeat { result = tcsetattr(descriptor, TCSANOW, &original) } while result < 0 && errno == EINTR
            guard result == 0 else { return false }
            close(descriptor); descriptor = -1; return true
        }
    }
    deinit { if !restore(), descriptor >= 0 { close(descriptor) } }
    static func withRaw<T: Sendable>(descriptor: Int32, body: @Sendable () async throws -> T) async throws -> T {
        let lease = try ProvisioningLocalTerminal(descriptor: descriptor)
        do {
            let value = try await body()
            guard lease.restore() else { throw ProvisioningTerminalDenial.unavailable }
            return value
        } catch {
            _ = lease.restore()
            throw error
        }
    }
}
