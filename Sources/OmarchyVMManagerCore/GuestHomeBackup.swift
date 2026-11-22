import Darwin
import Foundation

public enum GuestHomeBackupState: Equatable, Sendable {
    case idle, working(URL), cancelling(URL), completed(URL, Int64), failed(URL, String)
    public var isBusy: Bool {
        switch self { case .working, .cancelling: true; default: false }
    }
}

public protocol GuestHomeBackingUp: Sendable {
    func backup(_ request: VMStartRequest, user: String, operationID: UUID) async throws -> Int64
}

public struct SSHGuestHomeBackup: GuestHomeBackingUp {
    public init() {}
    static func directoryName(_ operationID: UUID) -> String { "home-backup-" + operationID.uuidString.lowercased() }
    static func destination(_ share: SharedFolderMapping, operationID: UUID) -> URL {
        URL(fileURLWithPath: share.hostPath).appendingPathComponent(directoryName(operationID)).appendingPathComponent("home.tgz")
    }
    /// Fixed guest supervisor steps. Only these names (and a numeric errno)
    /// are accepted from the guest's failure report; never names or stderr.
    static let failureStages: Set<String> = ["prerequisites", "archive", "verification", "publish", "sync"]
    static func failure(stage: String? = nil, errno code: Int32? = nil) -> VMFailure {
        let stage = stage.flatMap { failureStages.contains($0) ? $0 : nil }
        let label = stage.map { " (\($0))" } ?? ""
        let diagnostics = stage.map { "stage=\($0)" + (code.map { " errno=\($0)" } ?? "") } ?? ""
        return VMFailure(code: "home-backup-failed", message: "The home backup could not be verified\(label). Check free space, guest file access and the shared mount. Close apps that change files and retry. Any home.tgz.partial in this backup’s folder is incomplete; a lost connection can also leave an unconfirmed home.tgz. Existing backups were preserved.", diagnostics: diagnostics)
    }
    /// Decodes the guest's bounded `{"failure": stage, "errno": n}` report.
    /// Unknown stages, extra types or out-of-range numbers give no detail.
    static func failureReport(_ data: Data) -> (stage: String, errno: Int32?)? {
        struct Report: Decodable { let failure: String; let errno: Int? }
        guard data.count <= 4096, let report = try? JSONDecoder().decode(Report.self, from: data),
              failureStages.contains(report.failure) else { return nil }
        if let code = report.errno {
            guard (1...4095).contains(code) else { return nil }
            return (report.failure, Int32(code))
        }
        return (report.failure, nil)
    }
    static func failure(report data: Data) -> VMFailure {
        guard let report = failureReport(data) else { return failure() }
        return failure(stage: report.stage, errno: report.errno)
    }
    public func backup(_ request: VMStartRequest, user: String, operationID: UUID) async throws -> Int64 {
        guard let share = request.profile.sharedFolder, share.enabled, request.profile.ssh != nil,
              ManagedSSHProbe.validUser(user) else { throw Self.failure() }
        try Task.checkCancellation()
        try SharedFolderPolicy.validateHost(share)
        let storage = ManagedSSHStorage(root: request.storageRoot)
        try storage.validate(request.profile)
        let shareFD = open(share.hostPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard shareFD >= 0 else { throw Self.failure() }
        defer { close(shareFD) }
        guard let url = ManagerResources.bundle.url(forResource: "GuestHomeBackup", withExtension: "py") else { throw Self.failure() }
        let script = try String(contentsOf: url, encoding: .utf8)
        // Only validated owner/UUID literals enter the fixed program. Paths and
        // profile names never become shell syntax; SSH uses existing host pins.
        let program = script + "\nmain('\(request.profile.id.uuidString)', '\(request.sessionID.uuidString)', '\(user)', '\(operationID.uuidString)')\n"
        var arguments = storage.arguments(profile: request.profile, user: user)
        arguments.insert(contentsOf: ["-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"], at: 0)
        arguments[arguments.count - 1] = "/usr/bin/python3 -I -c '" + program.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let launchArguments = arguments, process = HomeBackupSSHProcess()
        let data = try await withTaskCancellationHandler {
            try await Task.detached { try process.run(arguments: launchArguments) }.value
        } onCancel: { process.cancel() }
        try Task.checkCancellation()
        let bytes = try Self.decode(data, request: request, operationID: operationID)
        // Verify the output through the same host directory opened before SSH,
        // then check it still names the configured share. Never trust a remote path.
        try Self.verifyOutput(shareFD: shareFD, share: share, operationID: operationID, bytes: bytes)
        return bytes
    }
    static func verifyOutput(shareFD: Int32, share: SharedFolderMapping, operationID: UUID, bytes: Int64) throws {
        let directory = openat(shareFD, Self.directoryName(operationID), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Self.failure() }
        defer { close(directory) }
        let file = openat(directory, "home.tgz", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Self.failure() }
        defer { close(file) }
        var info = stat(), before = stat(), current = stat(), folder = stat()
        guard fstat(shareFD, &before) == 0, lstat(share.hostPath, &current) == 0,
              before.st_dev == current.st_dev, before.st_ino == current.st_ino,
              fstat(directory, &folder) == 0, folder.st_uid == getuid(), folder.st_mode & 0o077 == 0,
              fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size == bytes else { throw Self.failure() }
    }
    static func decode(_ data: Data, request: VMStartRequest, operationID: UUID) throws -> Int64 {
        struct Report: Decodable { let vmID: UUID; let sessionID: UUID; let operationID: UUID; let bytes: Int64 }
        guard data.count <= 4096, let report = try? JSONDecoder().decode(Report.self, from: data),
              report.vmID == request.profile.id, report.sessionID == request.sessionID,
              report.operationID == operationID, report.bytes > 0 else { throw failure() }
        return report.bytes
    }
}

/// Long-running SSH (home backup, Reclaim space) differs from the eight-second
/// health probe: an open stdin is the cancellation lease. No raw stderr or guest
/// file listing is retained.
final class HomeBackupSSHProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?
    private var input: FileHandle?
    private var cancelled = false
    func cancel() {
        lock.withLock {
            cancelled = true
            try? input?.close(); input = nil
        }
        // Allow the remote supervisor to stop tar and retain its partial file.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.lock.withLock {
                if let child = self?.child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
    /// `failure` maps an unconfirmed result (nil) or a nonzero exit's bounded
    /// report to the operation's fixed failure. Home backup is the default.
    func run(arguments: [String], executable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), timeout: TimeInterval = 86_400,
             failure: (Data?) -> VMFailure = { $0.map(SSHGuestHomeBackup.failure(report:)) ?? SSHGuestHomeBackup.failure() }) throws -> Data {
        let process = Process(), control = Pipe(), output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardInput = control; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try process.run(); child = process; input = control.fileHandleForWriting
        }
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.cancel() }; timer.resume()
        defer {
            timer.cancel()
            lock.withLock {
                try? input?.close(); input = nil
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            lock.withLock { child = nil }
        }
        let data = try output.fileHandleForReading.read(upToCount: 4097) ?? Data()
        guard data.count <= 4096 else { cancel(); throw failure(nil) }
        process.waitUntilExit()
        guard !lock.withLock({ cancelled }) else { throw failure(nil) }
        // A nonzero exit may carry the supervisor's fixed stage/errno report.
        guard process.terminationStatus == 0 else { throw failure(data) }
        return data
    }
}
