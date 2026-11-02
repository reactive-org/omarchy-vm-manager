import Darwin
import Foundation

public enum ProvisioningProcessInput: Sendable {
    case closed, bytes(Data), terminalLease(UUID)
}
public enum ProvisioningProcessOutput: Sendable { case boundedCapture, terminalStream }
public enum ProvisioningProcessPurpose: String, Sendable {
    case identity, bootstrap, copyPayload, preparePayload, native, packages, features, repository, quiesce, remove
}
/// Describes an exact executable/argv/environment. It has no launch method.
public struct ProvisioningProcessInvocation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let commandID: UUID
    public let context: GuestJobContext
    public let purpose: ProvisioningProcessPurpose
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL
    public let input: ProvisioningProcessInput
    public let output: ProvisioningProcessOutput
    public let timeoutSeconds: Int
    public let maximumCapturedBytes = 32 * 1024
    public var description: String { "ProvisioningProcessInvocation(\(purpose.rawValue), redacted)" }
    public var debugDescription: String { description }
}
public enum ProvisioningExitReason: Sendable { case normal, cancelled, timedOut, outputLimit, ioFailure }
public enum ProvisioningProcessTermination: Sendable {
    /// Matching leader reaped and no live members of its owned process group.
    /// Deliberately detached sessions are not contained by a process group.
    case exited(status: Int32, reason: ProvisioningExitReason)
    /// Ownership is retained by the runner; do not infer exit or launch again.
    case cleanupUnconfirmed
    case notStarted
}
public struct ProvisioningProcessResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let invocationID: UUID
    public let termination: ProvisioningProcessTermination
    public let stdout: Data
    public let stderr: Data
    public init(invocationID: UUID, termination: ProvisioningProcessTermination, stdout: Data = Data(), stderr: Data = Data()) {
        self.invocationID = invocationID; self.termination = termination; self.stdout = stdout; self.stderr = stderr
    }
    public var description: String { "ProvisioningProcessResult(redacted)" }
    public var debugDescription: String { description }
}
/// A runner must register ownership before launch,
/// enforce output/deadline/PTY rules, and return only after matching local exit
/// and owned group cleanup, report uncertainty, or fail before starting. Interrupt is
/// scoped to the invocation ID; it never means the guest job has stopped.
public protocol ProvisioningProcessRunner: Sendable {
    func run(_ invocation: ProvisioningProcessInvocation) async -> ProvisioningProcessResult
    func interrupt(invocationID: UUID) async
}
/// VM/session authority remains manager-owned. SSH proves the host key and owner;
/// it cannot infer a manager VM/runtime-session identity from a listening port.
public protocol ProvisioningSessionAuthority: Sendable {
    func revalidate(_ binding: GuestBinding, dependencyDigest: String) async throws
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
func shellJoin(_ values: [String]) -> String { values.map(shellQuote).joined(separator: " ") }
func transportPath(_ url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/"), url.standardizedFileURL.path == url.path,
          !url.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { throw SequencingFailure.invalidRequest }
}
struct FileStamp: Sendable, Equatable {
    let device: dev_t, inode: ino_t, mode: mode_t, owner: uid_t, size: off_t
    let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; mode = s.st_mode; owner = s.st_uid; size = s.st_size
        modifiedSeconds = s.st_mtimespec.tv_sec; modifiedNanos = s.st_mtimespec.tv_nsec
        changedSeconds = s.st_ctimespec.tv_sec; changedNanos = s.st_ctimespec.tv_nsec
    }
}
func fileStamp(_ url: URL) throws -> FileStamp {
    var s = stat()
    guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG,
          s.st_uid == getuid() || s.st_uid == 0 else { throw SequencingFailure.dependencyChanged }
    return FileStamp(s)
}
private func pinnedBytes(_ url: URL, stamp: FileStamp) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw SequencingFailure.dependencyChanged }
    defer { close(fd) }
    var before = stat(), after = stat()
    guard fstat(fd, &before) == 0, FileStamp(before) == stamp else { throw SequencingFailure.dependencyChanged }
    let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
    guard data.count == stamp.size, fstat(fd, &after) == 0, FileStamp(after) == stamp else { throw SequencingFailure.dependencyChanged }
    return data
}
/// Captures an admitted executable without running a version/import probe.
/// Symlink entry and canonical target are rechecked before every invocation.
public struct ProvisioningExecutablePin: Sendable {
    let entry: URL, target: URL, stamp: FileStamp, sha256: String
    public init(_ url: URL) throws {
        try transportPath(url)
        entry = url; target = url.resolvingSymlinksInPath()
        stamp = try fileStamp(target)
        guard stamp.mode & 0o022 == 0, stamp.mode & 0o111 != 0, stamp.size <= 32 * 1024 * 1024 else { throw SequencingFailure.invalidRequest }
        sha256 = digest(try pinnedBytes(target, stamp: stamp))
    }
    func verify() throws -> URL {
        guard entry.resolvingSymlinksInPath() == target, try fileStamp(target) == stamp,
              digest(try pinnedBytes(target, stamp: stamp)) == sha256 else { throw SequencingFailure.dependencyChanged }
        // Preserve launcher/argv[0] identity (Ansible commands may share a
        // symlink target but dispatch differently). Pin the target, execute entry.
        return entry
    }
}
/// This reference stats the explicit credential only; it never reads its bytes.
public struct ProvisioningIdentityFile: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let url: URL, stamp: FileStamp
    public init(_ url: URL) throws {
        try transportPath(url); self.url = url; stamp = try fileStamp(url)
        guard stamp.owner == getuid(), stamp.mode & 0o077 == 0 else { throw SequencingFailure.invalidRequest }
    }
    func verify() throws {
        guard try fileStamp(url) == stamp else { throw SequencingFailure.identityMismatch }
    }
    public var description: String { "ProvisioningIdentityFile(redacted)" }
    public var debugDescription: String { description }
}
public struct ProvisioningSSHConnection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let binding: GuestBinding
    public let port: UInt16
    let identity: ProvisioningIdentityFile
    let hostKey: Data
    public var description: String { "ProvisioningSSHConnection(redacted)" }
    public var debugDescription: String { description }
    public init(binding: GuestBinding, port: UInt16, identity: ProvisioningIdentityFile, ed25519HostKey: Data) throws {
        let bytes = Array(ed25519HostKey)
        guard port >= 1024, bytes.count == 51, Array(bytes.prefix(4)) == [0, 0, 0, 11],
              Array(bytes[4..<15]) == Array("ssh-ed25519".utf8), Array(bytes[15..<19]) == [0, 0, 0, 32],
              digest(ed25519HostKey) == binding.hostKeyDigest else { throw SequencingFailure.identityMismatch }
        self.binding = binding; self.port = port; self.identity = identity; hostKey = ed25519HostKey
    }
    var alias: String { "omarchy-" + binding.vmID.uuidString.lowercased() }
}
public struct ProvisioningTransportTools: Sendable {
    let ssh: ProvisioningExecutablePin, scp: ProvisioningExecutablePin, sftp: ProvisioningExecutablePin
    let playbook: ProvisioningExecutablePin, inventory: ProvisioningExecutablePin
    public init(ssh: ProvisioningExecutablePin, scp: ProvisioningExecutablePin, sftp: ProvisioningExecutablePin,
                ansiblePlaybook: ProvisioningExecutablePin, ansibleInventory: ProvisioningExecutablePin) {
        self.ssh = ssh; self.scp = scp; self.sftp = sftp; playbook = ansiblePlaybook; inventory = ansibleInventory
    }
    func verify() throws {
        for pin in [ssh, scp, sftp, playbook, inventory] { _ = try pin.verify() }
    }
}
