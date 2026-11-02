import Darwin
import DevVMProvisioningCore
import Foundation

struct ProvisioningArtifactReferences: Sendable {
    let inputsSHA256: String
    let cleanupSHA256: String
}

/// Explicit private storage, separate from the non-secret journal/status data.
/// Immutable UUID-named files; no extraction into a user tree or automatic replay.
final class ProvisioningJobArtifacts: @unchecked Sendable {
    let directory: URL
    private let mutex = NSLock()
    private let fd: Int32
    private let inode: ino_t
    private let device: dev_t
    private let maximumTotalBytes: Int
    init(directory: URL, maximumTotalBytes: Int = 256 * 1024 * 1024) throws {
        guard maximumTotalBytes >= 0, maximumTotalBytes <= 1024 * 1024 * 1024 else { throw ProvisioningJobFailure.artifactUnavailable }
        self.directory = directory; self.maximumTotalBytes = maximumTotalBytes
        try PrivateFiles.directory(directory, create: true)
        fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0 else {
            if fd >= 0 { close(fd) }
            throw ProvisioningJobFailure.artifactUnavailable
        }
        inode = info.st_ino; device = info.st_dev
    }
    deinit { close(fd) }
    func prepare(_ request: ProvisioningRequest, payloadID: UUID, workerToken: UUID, engineDigest: String) throws -> ProvisioningArtifactReferences {
        try mutex.withLock {
            do {
                try checkDirectory()
                let inputs = try request.plan.snapshot.privateArchive()
                let scope = try CleanupRecoveryIdentity(jobID: request.jobID, payloadID: payloadID, target: request.target,
                    dependencyDigest: request.dependencyDigest, engineDigest: engineDigest, mode: request.mode)
                let value: [String: Any] = ["format": 1, "workerToken": workerToken.uuidString,
                                          "checkpoint": try scope.privateCheckpoint().base64EncodedString()]
                let cleanup = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                try quota(adding: inputs.count + cleanup.count)
                try writeImmutable(inputs, name: name(request.jobID, "inputs"))
                try writeImmutable(cleanup, name: name(request.jobID, "cleanup"))
                try checkDirectory()
                return .init(inputsSHA256: KitVerifier.sha256(inputs), cleanupSHA256: KitVerifier.sha256(cleanup))
            } catch { throw ProvisioningJobFailure.artifactUnavailable }
        }
    }
    func frozenInputs(_ record: ProvisioningJobRecord) throws -> FrozenInputsArchive {
        try mutex.withLock {
            do {
                let data = try read(record.jobID, suffix: "inputs", expected: record.inputArchiveSHA256, maximum: FrozenInputsArchive.maximumArchiveBytes)
                return try FrozenInputsArchive(privateArchive: data, expectedIdentity: record.inputDigest)
            } catch { throw ProvisioningJobFailure.artifactUnavailable }
        }
    }
    func verifyInputs(_ record: ProvisioningJobRecord) throws {
        try mutex.withLock { _ = try read(record.jobID, suffix: "inputs", expected: record.inputArchiveSHA256, maximum: FrozenInputsArchive.maximumArchiveBytes) }
    }
    func cleanupTicket(_ record: ProvisioningJobRecord, target: GuestBinding) throws -> CleanupTicket {
        try mutex.withLock {
            do {
                let data = try read(record.jobID, suffix: "cleanup", expected: record.cleanupCheckpointSHA256, maximum: 32 * 1024)
                guard case .object(let fields) = try PlainDataParser.parse(data, format: .json),
                      Set(fields.keys) == ["format", "workerToken", "checkpoint"], fields["format"] == .integer(1),
                      let token = record.workerToken, fields["workerToken"] == .string(token.uuidString),
                      case .string(let encoded) = fields["checkpoint"], let checkpoint = Data(base64Encoded: encoded),
                      let payload = record.payloadID else { throw ProvisioningJobFailure.artifactUnavailable }
                let identity = try CleanupRecoveryIdentity(jobID: record.jobID, payloadID: payload, target: target,
                    dependencyDigest: record.dependencyDigest, engineDigest: record.engineDigest, mode: record.mode)
                return try identity.restore(privateCheckpoint: checkpoint)
            } catch { throw ProvisioningJobFailure.artifactUnavailable }
        }
    }
    private func name(_ id: UUID, _ suffix: String) -> String { id.uuidString + "." + suffix }
    private func read(_ id: UUID, suffix: String, expected: String?, maximum: Int) throws -> Data {
        do {
            try checkDirectory()
            guard let expected, provisioningDigest(expected) else { throw ProvisioningJobFailure.artifactUnavailable }
            let data = try PrivateFiles.read(directory.appendingPathComponent(name(id, suffix)), maximum: maximum)
            guard KitVerifier.sha256(data) == expected else { throw ProvisioningJobFailure.artifactUnavailable }
            try checkDirectory()
            return data
        } catch { throw ProvisioningJobFailure.artifactUnavailable }
    }
    private func writeImmutable(_ data: Data, name: String) throws {
        let url = directory.appendingPathComponent(name)
        if PrivateFiles.exists(url) {
            guard try PrivateFiles.read(url, maximum: FrozenInputsArchive.maximumArchiveBytes) == data else { throw ProvisioningJobFailure.artifactUnavailable }
        } else { try PrivateFiles.write(data, name: name, in: directory, exclusively: true) }
        guard try PrivateFiles.read(url, maximum: FrozenInputsArchive.maximumArchiveBytes) == data else { throw ProvisioningJobFailure.artifactUnavailable }
    }
    private func checkDirectory() throws {
        try PrivateFiles.directory(directory)
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_ino == inode, info.st_dev == device else { throw ProvisioningJobFailure.artifactUnavailable }
    }
    private func quota(adding count: Int) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard entries.count <= 510 else { throw ProvisioningJobFailure.artifactUnavailable }
        var total = count
        for entry in entries {
            var info = stat()
            guard lstat(directory.appendingPathComponent(entry).path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_mode & 0o7777 == 0o600, info.st_size >= 0, info.st_size <= FrozenInputsArchive.maximumArchiveBytes
            else { throw ProvisioningJobFailure.artifactUnavailable }
            total += Int(info.st_size)
            guard total <= maximumTotalBytes else { throw ProvisioningJobFailure.artifactUnavailable }
        }
        guard total <= maximumTotalBytes else { throw ProvisioningJobFailure.artifactUnavailable }
    }
}

/// Must be supplied by an authenticated ownership channel, never a PID or
/// a disk observation. The prior worker must be stopped AND fenced from launch.
struct ProvisioningRecoveryExpectation: Sendable, Equatable, Codable {
    let challenge: UUID
    let jobID: UUID, vmID: UUID, sessionID: UUID, payloadID: UUID, workerToken: UUID
    let engineDigest: String, dependencyDigest: String, bindingDigest: String, reviewDigest: String, checkpointDigest: String
    func validate() throws {
        guard [engineDigest, dependencyDigest, bindingDigest, reviewDigest, checkpointDigest].allSatisfy(provisioningDigest) else { throw ProvisioningHelperIPCFailure.protocolViolation }
    }
    func sameWorker(as other: Self) -> Bool {
        jobID == other.jobID && vmID == other.vmID && sessionID == other.sessionID && payloadID == other.payloadID && workerToken == other.workerToken && engineDigest == other.engineDigest && dependencyDigest == other.dependencyDigest && bindingDigest == other.bindingDigest && reviewDigest == other.reviewDigest && checkpointDigest == other.checkpointDigest
    }
}
enum ProvisioningPriorWorkerState: String, Sendable, Codable { case stoppedAndFenced, running, unknown }
struct ProvisioningRecoveryPermit: Sendable {
    let expectation: ProvisioningRecoveryExpectation
    let priorWorker: ProvisioningPriorWorkerState
}
protocol ProvisioningRecoveryAuthorizing: Sendable {
    func reconcile(_ expectation: ProvisioningRecoveryExpectation) async throws -> ProvisioningRecoveryPermit
}
