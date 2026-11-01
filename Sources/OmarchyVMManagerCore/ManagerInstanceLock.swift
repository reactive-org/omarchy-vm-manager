import Darwin
import Foundation

/// Retain for the entire application lifetime, including coordinated shutdown.
public final class ManagerInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    /// A busy lock returns nil; an unsafe or inaccessible lock fails closed.
    public static func acquire(in directory: URL) throws -> ManagerInstanceLock? {
        try PrivateFiles.directory(directory, create: true)
        let file = directory.appendingPathComponent(".application.lock")
        let fd = open(file.path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            if errno == EWOULDBLOCK { return nil }
            throw PrivateFiles.failure("Cannot safely acquire the application lock.")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o7777 == 0o600 else {
            close(fd)
            throw PrivateFiles.failure("The application lock is unsafe and was preserved.")
        }
        // Keep the file in place: unlinking it would let another process lock a new inode.
        return ManagerInstanceLock(descriptor: fd)
    }
}
