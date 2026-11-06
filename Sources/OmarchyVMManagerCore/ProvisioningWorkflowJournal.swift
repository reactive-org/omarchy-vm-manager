import Darwin
import DevVMProvisioningCore
import Foundation

public enum ProvisioningWorkflowStage: String, Codable, Sendable {
    case waitingForSSH, readyForReview, running, restartRequired, waitingForExit, restarting, waitingForRebind, readyForCheck, checking
    case succeeded, checked, failed, cancelled, interrupted, cleanupRequired
    var unfinished: Bool { [.waitingForSSH, .readyForReview, .running, .waitingForExit, .restarting, .waitingForRebind, .readyForCheck, .checking].contains(self) }
}
public enum ProvisioningWorkflowFailure: String, Codable, Sendable {
    case disabled, cancelled, invalidReview, targetChanged, dependencyChanged, sourceChanged, sshTimeout, restartTimeout, helperUnavailable, journalUnavailable, processInterrupted, childFailed, systemUpdateFailed
}
public struct ProvisioningWorkflowSnapshot: Codable, Equatable, Sendable {
    public let id: UUID, vmID: UUID, originalSessionID: UUID
    public let sequence: UInt64
    public let stage: ProvisioningWorkflowStage
    public let cleanupRequired: Bool
    public let failure: ProvisioningWorkflowFailure?
    public let applyJobID: UUID?
    public let checkJobID: UUID?
    public let restartID: UUID?
    public let newSessionID: UUID?
}
struct ProvisioningWorkflowRecord: Codable, Equatable, Sendable {
    let id: UUID, vmID: UUID, originalSessionID: UUID
    let planDigest: String, inputDigest: String, engineDigest: String
    var sequence: UInt64 = 1
    var stage: ProvisioningWorkflowStage = .waitingForSSH
    var cleanupRequired = false
    var failure: ProvisioningWorkflowFailure?
    var reviewDigest: String?
    var applyJobID: UUID?
    var checkJobID: UUID?
    var restartID: UUID?
    var restartReviewDigest: String?
    var newSessionID: UUID?
    var checkReviewDigest: String?
    var checkActivationID: UUID?
    var snapshot: ProvisioningWorkflowSnapshot { .init(id: id, vmID: vmID, originalSessionID: originalSessionID, sequence: sequence, stage: stage,
        cleanupRequired: cleanupRequired, failure: failure, applyJobID: applyJobID, checkJobID: checkJobID, restartID: restartID, newSessionID: newSessionID) }
    enum CodingKeys: String, CodingKey, CaseIterable { case id, vmID, originalSessionID, planDigest, inputDigest, engineDigest, sequence, stage, cleanupRequired, failure, reviewDigest, applyJobID, checkJobID, restartID, restartReviewDigest, newSessionID, checkReviewDigest, checkActivationID }
    func validate() throws {
        guard sequence > 0, sequence < UInt64(Int64.max), [planDigest, inputDigest, engineDigest].allSatisfy(provisioningDigest),
              [reviewDigest, restartReviewDigest, checkReviewDigest].compactMap({ $0 }).allSatisfy(provisioningDigest),
              stage != .cleanupRequired || cleanupRequired,
              ![.succeeded, .checked, .restartRequired].contains(stage) || !cleanupRequired,
              applyJobID == nil || (reviewDigest != nil && applyJobID == id),
              stage != .readyForReview || reviewDigest != nil,
              ![.running, .succeeded, .checked, .restartRequired].contains(stage) || applyJobID != nil,
              ![.waitingForExit, .restarting, .waitingForRebind, .readyForCheck, .checking].contains(stage) || restartID != nil,
              ![.readyForCheck, .checking].contains(stage) || checkReviewDigest != nil,
              stage != .checking || checkActivationID != nil,
              checkJobID == nil || checkJobID != applyJobID,
              (restartID == nil) == (restartReviewDigest == nil),
              restartID == nil || applyJobID != nil,
              newSessionID == nil || (restartID != nil && newSessionID != originalSessionID),
              checkReviewDigest == nil || (checkJobID != nil && newSessionID != nil),
              checkActivationID == nil || checkReviewDigest != nil else { throw ProvisioningJobFailure.journalUnavailable }
    }
}
/// Separate non-secret workflow index. No source/resource paths, raw output,
/// credentials, saved PIDs or launch capabilities can be encoded.
final class ProvisioningWorkflowJournal: @unchecked Sendable {
    private struct Document: Codable { let schemaVersion: Int; let revision: UInt64; let workflows: [ProvisioningWorkflowRecord] }
    let directory: URL
    private let access = NSLock()
    private var fd: Int32
    private let inode: ino_t, device: dev_t, lockInode: ino_t
    private var fingerprint: String?, revision: UInt64 = 0
    private var loaded = false, poisoned = false
    init(directory: URL) throws {
        self.directory = directory; try PrivateFiles.directory(directory, create: true)
        var info = stat(); guard lstat(directory.path, &info) == 0 else { throw ProvisioningJobFailure.journalUnavailable }
        inode = info.st_ino; device = info.st_dev
        let lock = directory.appendingPathComponent(".workflow.lock")
        fd = open(lock.path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0, fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o7777 == 0o600, info.st_nlink == 1 else {
            if fd >= 0 { Darwin.close(fd) }; throw ProvisioningJobFailure.journalUnavailable
        }
        lockInode = info.st_ino
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    func close() { access.withLock { if fd >= 0 { Darwin.close(fd); fd = -1 } } }
    private var file: URL { directory.appendingPathComponent("workflows.json") }
    private func verify() throws {
        try PrivateFiles.directory(directory)
        var d = stat(), l = stat()
        guard fd >= 0, !poisoned, lstat(directory.path, &d) == 0, d.st_ino == inode, d.st_dev == device,
              lstat(directory.appendingPathComponent(".workflow.lock").path, &l) == 0, l.st_ino == lockInode,
              l.st_dev == device, l.st_mode & 0o7777 == 0o600, l.st_uid == getuid(), l.st_nlink == 1 else { throw ProvisioningJobFailure.journalUnavailable }
    }
    func load() throws -> [ProvisioningWorkflowRecord] {
        try access.withLock {
            do {
                try verify()
                guard PrivateFiles.exists(file) else { guard !loaded || fingerprint == nil else { throw ProvisioningJobFailure.journalUnavailable }; loaded = true; return [] }
                let data = try PrivateFiles.read(file, maximum: 256 * 1024)
                guard !loaded || fingerprint == KitVerifier.sha256(data) else { throw ProvisioningJobFailure.journalUnavailable }
                let object = try transportFields(DevVMProvisioningCore.PlainDataParser.parse(data, format: .json), required: ["schemaVersion", "revision", "workflows"])
                guard object["schemaVersion"] == .integer(1), case .array(let rows) = object["workflows"], rows.count <= 128 else { throw ProvisioningJobFailure.journalUnavailable }
                let required: Set<String> = ["id", "vmID", "originalSessionID", "planDigest", "inputDigest", "engineDigest", "sequence", "stage", "cleanupRequired"]
                let all = Set(ProvisioningWorkflowRecord.CodingKeys.allCases.map(\.rawValue))
                for row in rows {
                    let fields = try transportFields(row, required: required, optional: all.subtracting(required))
                    for key in all.subtracting(required) where fields[key] != nil { guard case .string = fields[key] else { throw ProvisioningJobFailure.journalUnavailable } }
                }
                let doc = try JSONDecoder().decode(Document.self, from: data)
                guard doc.revision > 0, Set(doc.workflows.map(\.id)).count == doc.workflows.count else { throw ProvisioningJobFailure.journalUnavailable }
                try doc.workflows.forEach { try $0.validate() }
                revision = doc.revision; fingerprint = KitVerifier.sha256(data); loaded = true; return doc.workflows
            } catch { poisoned = true; throw ProvisioningJobFailure.journalUnavailable }
        }
    }
    func save(_ rows: [ProvisioningWorkflowRecord]) throws {
        try access.withLock {
            do {
                try verify(); guard loaded, revision < UInt64(Int64.max), rows.count <= 128, Set(rows.map(\.id)).count == rows.count else { throw ProvisioningJobFailure.journalUnavailable }
                try rows.forEach { try $0.validate() }
                guard (PrivateFiles.exists(file) ? KitVerifier.sha256(try PrivateFiles.read(file, maximum: 256 * 1024)) : nil) == fingerprint else { throw ProvisioningJobFailure.journalUnavailable }
                let data = try helperJSON(Document(schemaVersion: 1, revision: revision + 1, workflows: rows.sorted { $0.id.uuidString < $1.id.uuidString }))
                guard data.count <= 256 * 1024 else { throw ProvisioningJobFailure.journalUnavailable }
                try PrivateFiles.write(data, name: file.lastPathComponent, in: directory, exclusively: fingerprint == nil)
                try verify(); guard try PrivateFiles.read(file, maximum: 256 * 1024) == data else { throw ProvisioningJobFailure.journalUnavailable }
                revision += 1; fingerprint = KitVerifier.sha256(data)
            } catch { poisoned = true; throw ProvisioningJobFailure.journalUnavailable }
        }
    }
}
