import Darwin
import Foundation

public protocol SSHReadinessChecking: Sendable {
    func monitor(_ request: VMStartRequest, update: @escaping @Sendable (SSHReadiness) async -> Void) async
}

public struct ManagedSSHProbe: SSHReadinessChecking {
    public init() {}
    struct Status: Decodable {
        struct Report: Decodable { let managedSSH: Guest? }
        let receivedAt: Date
        let report: Report
    }
    struct Guest: Codable, Sendable {
        let schemaVersion: Int
        let vmID: UUID
        let sessionToken: UUID
        let state: String
        let owner: String?
        var failureStage: String? = nil
        var failureCode: String? = nil
        var failureStatus: Int? = nil
    }
    struct Identity: Decodable { let vmID: UUID; let sessionToken: UUID; let user: String; let uid: Int }

    public func monitor(_ request: VMStartRequest, update: @escaping @Sendable (SSHReadiness) async -> Void) async {
        let storage = ManagedSSHStorage(root: request.storageRoot)
        let deadline = Date().addingTimeInterval(1800)
        var hasConnected = false
        while !Task.isCancelled {
            do {
                try storage.validate(request.profile)
                guard let report = try currentReport(request) else {
                    await update(.provisioning)
                    if !hasConnected, Date() > deadline { await update(.failed("SSH provisioning timed out. Complete guest setup and retry the SSH check.")); return }
                    try await Task.sleep(for: .seconds(2)); continue
                }
                guard report.state != "error" else {
                    var detail = ""
                    if let stage = report.failureStage {
                        let code = report.failureCode ?? "unknown"
                        let status = report.failureStatus.map { ":\($0)" } ?? ""
                        detail = " at \(stage) (\(code)\(status))"
                    }
                    await update(.failed("Guest SSH provisioning failed" + detail + ". Its identities were preserved.")); return
                }
                guard let user = report.owner, Self.validUser(user), report.state == "configured" else {
                    await update(.waitingForOwner)
                    if Date() > deadline { await update(.failed("Waiting for the guest’s normal owner-account setup. Retry SSH after setup finishes.")); return }
                    try await Task.sleep(for: .seconds(2)); continue
                }
                await update(.connecting)
                let process = SSHProbeProcess()
                let result = try await withTaskCancellationHandler {
                    try await Task.detached { try process.run(arguments: storage.arguments(profile: request.profile, user: user)) }.value
                } onCancel: { process.cancel() }
                try Task.checkCancellation()
                if result.hostKeyMismatch { await update(.failed("The guest SSH host key changed. Explicit recovery is required; it was not accepted.")); return }
                if result.status == 0, let identity = try? JSONDecoder().decode(Identity.self, from: result.output),
                   identity.vmID == request.profile.id, identity.sessionToken == request.sessionID, identity.user == user, identity.uid >= 1000, identity.uid < 60000 {
                    let command = try storage.command(profile: request.profile, user: user)
                    hasConnected = true; await update(.ready(user: user, command: command))
                    try await Task.sleep(for: .seconds(30))
                } else {
                    if !hasConnected, Date() > deadline { await update(.failed("SSH authentication could not be verified. The VM remains running; retry the SSH check after reviewing setup.")); return }
                    try await Task.sleep(for: .seconds(3))
                }
            } catch is CancellationError { return }
            catch {
                await update(.failed((error as? VMFailure)?.message ?? "SSH verification failed; credentials and host-key pins were preserved.")); return
            }
        }
    }

    static func validUser(_ value: String) -> Bool {
        value.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil && value != "root"
    }
    func currentReport(_ request: VMStartRequest) throws -> Guest? {
        let path = request.storageRoot.appendingPathComponent("shell/guest-status.json")
        guard PrivateFiles.exists(path) else { return nil }
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw PrivateFiles.failure("Cannot read guest SSH status.") }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1,
              s.st_mode & 0o022 == 0, s.st_size <= 8192 else { throw PrivateFiles.failure("Unsafe guest SSH status was refused.") }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 8193) ?? Data()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let status = try? decoder.decode(Status.self, from: data), let report = status.report.managedSSH,
              status.receivedAt >= request.startedAt.addingTimeInterval(-1),
              report.schemaVersion == 1, report.vmID == request.profile.id, report.sessionToken == request.sessionID,
              ["waiting-owner", "configured", "error"].contains(report.state), report.owner == nil || Self.validUser(report.owner!) else { return nil }
        let stages = ["host-settings", "run-directory", "share-mount", "manifest", "identity", "host-key-read", "host-key-verify", "owner", "authorized-keys", "daemon-config", "daemon-check", "daemon-start"]
        let codes = ["unsafe-directory", "unsafe-share", "file-type", "file-links", "file-size", "invalid-data", "command-failed", "timeout", "file-access", "unexpected"]
        guard report.failureStage == nil || stages.contains(report.failureStage!),
              report.failureCode == nil || codes.contains(report.failureCode!),
              report.failureStatus == nil || (-255...255).contains(report.failureStatus!) else { return nil }
        return report
    }
}

final class SSHProbeProcess: @unchecked Sendable {
    struct Result { let status: Int32; let output: Data; let hostKeyMismatch: Bool }
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true; if let process, process.isRunning { process.terminate() } } }
    func run(arguments: [String]) throws -> Result {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        let output = Pipe(), errors = Pipe()
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = errors
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try child.run(); process = child
        }
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + 8)
        timer.setEventHandler { [weak self] in self?.cancel() }; timer.resume()
        defer {
            timer.cancel()
            lock.withLock { if child.isRunning { child.terminate() }; process = nil }
            child.waitUntilExit()
        }
        let data = try output.fileHandleForReading.read(upToCount: 4097) ?? Data()
        if data.count > 4096 { cancel(); throw VMFailure(code: "ssh-response-too-large", message: "Oversized SSH identity response was refused.") }
        let error = try errors.fileHandleForReading.read(upToCount: 8193) ?? Data()
        if error.count > 8192 { cancel() }
        child.waitUntilExit()
        let message = String(decoding: error, as: UTF8.self)
        return Result(status: child.terminationStatus, output: data, hostKeyMismatch: message.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || message.contains("Host key verification failed"))
    }
}
