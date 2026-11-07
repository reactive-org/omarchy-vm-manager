import Darwin
import Foundation

/// Saved output of the most recent setup run for one VM (user direction,
/// 7 November 2026; see intent.md). One private file inside the VM's own root:
/// `.manager-setup/last-run.log`, folder 0700, file 0600. It is bounded, never
/// journaled, not redacted, and moves to Trash with the VM. Raw input is never
/// recorded; output received while a job accepts interactive input is omitted.
public enum ProvisioningSetupLog {
    static let directoryName = ".manager-setup"
    static let fileName = "last-run.log"
    /// Bytes written directly from the start of the run.
    static let headBytes = 1_048_576
    /// Rolling tail kept in memory once the head is full; failures are at the end.
    static let tailBytes = 2_097_152
    /// Largest file the reader accepts (head + tail + markers, with headroom).
    public static let maximumBytes = 4_194_304

    static func directory(root: URL) -> URL { root.appendingPathComponent(directoryName, isDirectory: true) }
    static func file(root: URL) -> URL { directory(root: root).appendingPathComponent(fileName) }
    /// For Reveal in Finder only; reads go through `read(root:)`.
    public static func fileURL(root: URL) -> URL { file(root: root) }

    /// Reads the saved log for a VM root, or nil when none exists. Refuses links,
    /// shared or oversized files and folders not private to this user.
    public static func read(root: URL) throws -> Data? {
        let folder = directory(root: root), url = file(root: root)
        var info = stat()
        guard lstat(folder.path, &info) == 0 else { return nil }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ProvisioningSetupLogFailure.unsafe }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw ProvisioningSetupLogFailure.unsafe }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size <= off_t(maximumBytes) else { throw ProvisioningSetupLogFailure.unsafe }
        let size = Int(info.st_size)
        var data = Data(count: size), offset = 0
        while offset < size {
            let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, size - offset) }
            guard count > 0 else { break }
            offset += count
        }
        return data.prefix(offset)
    }
}

public enum ProvisioningSetupLogFailure: Error, Equatable { case unsafe, rootMissing }

/// Appends to the private log. Apply jobs start a fresh file; check jobs of the
/// same run append. Never creates the VM root itself.
final class ProvisioningSetupLogWriter: @unchecked Sendable {
    private var fd: Int32
    private var written: Int
    private var tail = Data()
    private var omitted = 0

    init(root: URL, replace: Bool, header: String) throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw ProvisioningSetupLogFailure.rootMissing }
        try PrivateFiles.directory(ProvisioningSetupLog.directory(root: root), create: true)
        let url = ProvisioningSetupLog.file(root: root)
        if replace, unlink(url.path) != 0, errno != ENOENT { throw ProvisioningSetupLogFailure.unsafe }
        var handle = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if handle < 0, errno == EEXIST { handle = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC) }
        guard handle >= 0 else { throw ProvisioningSetupLogFailure.unsafe }
        guard fstat(handle, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else { close(handle); throw ProvisioningSetupLogFailure.unsafe }
        fd = handle; written = Int(info.st_size)
        marker(header)
    }
    deinit { if fd >= 0 { close(fd) } }

    /// Output bytes: written directly until the head is full, then kept as a rolling tail.
    func append(_ bytes: Data) {
        guard fd >= 0, !bytes.isEmpty else { return }
        if written < ProvisioningSetupLog.headBytes {
            let direct = bytes.prefix(ProvisioningSetupLog.headBytes - written)
            write(direct)
            if direct.count < bytes.count { keep(bytes.dropFirst(direct.count)) }
        } else { keep(bytes) }
    }
    /// A visible line of manager text, e.g. a gap or omission marker.
    func marker(_ text: String) {
        flushTail()
        write(Data(("\r\n[" + text + "]\r\n").utf8))
    }
    func finish(_ text: String) {
        guard fd >= 0 else { return }
        marker(text)
        fsync(fd); close(fd); fd = -1
    }

    private func keep(_ bytes: Data) {
        tail.append(bytes)
        if tail.count > ProvisioningSetupLog.tailBytes {
            let drop = tail.count - ProvisioningSetupLog.tailBytes
            omitted += drop; tail.removeFirst(drop)
        }
    }
    private func flushTail() {
        guard !tail.isEmpty || omitted > 0 else { return }
        if omitted > 0 { write(Data(("\r\n[… \(omitted) bytes of output omitted to keep this log small …]\r\n").utf8)); omitted = 0 }
        let pending = tail; tail.removeAll(); write(pending)
    }
    private func write(_ bytes: Data) {
        guard fd >= 0, !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count <= 0 { if errno == EINTR { continue }; close(fd); fd = -1; return }
                offset += count
            }
        }
        written += bytes.count
    }
}

/// The reads a recorder needs; `ProvisioningTerminalAttachment` provides them.
protocol ProvisioningTerminalReading: Sendable {
    func poll() async throws -> ProvisioningTerminalPage
    func acknowledgeReset() async throws -> ProvisioningTerminalPage
    func detach() async
}
extension ProvisioningTerminalAttachment: ProvisioningTerminalReading {}

/// View-only recorder for one job. It never claims input, and it paces reads so
/// the shared terminal slot stays available to UI and CLI viewers.
actor ProvisioningSetupRecorder {
    static let burstFrames = 32
    static let burstPause: Duration = .milliseconds(15)
    static let idlePause: Duration = .milliseconds(40)

    private let reader: any ProvisioningTerminalReading
    private let writer: ProvisioningSetupLogWriter
    private var stopRequested = false
    private var interactive = false
    private var drained = false
    private var task: Task<Void, Never>?

    init(reader: any ProvisioningTerminalReading, writer: ProvisioningSetupLogWriter) {
        self.reader = reader; self.writer = writer
    }
    func start() { task = Task { await self.run() } }

    private func run() async {
        var burst = 0
        while !Task.isCancelled {
            let page: ProvisioningTerminalPage
            do { page = try await reader.poll() }
            catch ProvisioningTerminalDenial.busy { try? await Task.sleep(for: Self.idlePause); continue }
            catch { if !stopRequested { writer.marker("recording stopped: live output became unavailable") }; break }
            if page.resetRequired {
                writer.marker("output gap: some output was dropped before it could be saved")
                do { _ = try await reader.acknowledgeReset() } catch { writer.marker("recording stopped: live output became unavailable"); break }
                continue
            }
            if page.acceptsInput {
                if !interactive { interactive = true; writer.marker("interactive section omitted; typed input and its output are not saved") }
            } else {
                interactive = false
                for frame in page.frames { writer.append(frame.bytes) }
            }
            if page.frames.isEmpty {
                if stopRequested { drained = true; break }
                burst = 0; try? await Task.sleep(for: Self.idlePause)
            } else {
                burst += 1
                if burst >= Self.burstFrames { burst = 0; try? await Task.sleep(for: Self.burstPause) }
            }
        }
    }

    /// Drains what is still buffered (bounded by `deadline`), then closes the file.
    func finish(result: String, deadline: Duration = .seconds(2)) async {
        stopRequested = true
        let running = task
        let timeout = Task { try? await Task.sleep(for: deadline); running?.cancel() }
        await running?.value
        timeout.cancel()
        await reader.detach()
        writer.finish(drained ? "setup " + result : "setup " + result + "; final output may be incomplete")
    }
    /// Abort path: stop immediately and mark the file.
    func abort() async {
        task?.cancel(); await task?.value
        await reader.detach()
        writer.finish("recording ended early: setup was interrupted")
    }
}
