import Darwin
import DevVMProvisioningCore
import Foundation

public enum ProvisioningJobState: String, Codable, Sendable {
    case queued, running, awaitingAuthorization, cleaningUp, cancelling
    case succeeded, checked, restartRequired, failed, cancelled, timedOut
    case authorizationRequired, rejected, interrupted, cleanupRequired, cleanupConfirmed
    var unfinished: Bool { [.queued, .running, .awaitingAuthorization, .cleaningUp, .cancelling].contains(self) }
}
public enum ProvisioningJobFailure: String, Codable, Error, Sendable {
    case busy, invalidRequest, approvalRequired, sourceChanged, targetChanged, dependencyChanged
    case jobConflict, unknownJob, journalUnavailable, managerRestarted, cleanupRequired
    case recoveryUnavailable, lifecycleChanged, cleanupDeadline, driverFailed
}
public struct ProvisioningJobSnapshot: Codable, Equatable, Sendable {
    public let jobID: UUID
    public let vmID: UUID
    public let sessionID: UUID
    public let sequence: UInt64
    public let state: ProvisioningJobState
    public let outcome: ProvisioningOutcome?
    public let failure: ProvisioningJobFailure?
    public let engineFailure: SequencingFailure?
    public let cleanupFailures: [SequencingFailure]
    public let cleanupRequired: Bool
    public let workerOutstanding: Bool
}

/// Private metadata only. No source paths/bytes, owner/key/credential references,
/// terminal bytes, helper PID or untrusted diagnostic strings can be encoded.
struct ProvisioningJobRecord: Codable, Equatable, Sendable {
    let jobID: UUID
    let vmID: UUID
    let sessionID: UUID
    let reviewDigest: String
    let planDigest: String
    let inputDigest: String
    let engineDigest: String
    let dependencyDigest: String
    let bindingDigest: String
    let mode: ProvisioningMode
    var sequence: UInt64 = 1
    var state: ProvisioningJobState = .queued
    var outcome: ProvisioningOutcome?
    var failure: ProvisioningJobFailure?
    var engineFailure: SequencingFailure?
    var cleanupFailures: [SequencingFailure] = []
    var cleanupRequired = false
    var workerOutstanding = false
    var payloadID: UUID?
    var commandID: UUID?
    var operation: GuestOperation?
    var attempts = 1
    var snapshot: ProvisioningJobSnapshot {
        .init(jobID: jobID, vmID: vmID, sessionID: sessionID, sequence: sequence, state: state,
              outcome: outcome, failure: failure, engineFailure: engineFailure, cleanupFailures: cleanupFailures,
              cleanupRequired: cleanupRequired, workerOutstanding: workerOutstanding)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case jobID, vmID, sessionID, reviewDigest, planDigest, inputDigest, engineDigest, dependencyDigest, bindingDigest, mode
        case sequence, state, outcome, failure, engineFailure, cleanupFailures, cleanupRequired, workerOutstanding, payloadID, commandID, operation, attempts
    }
    func validate() throws {
        guard sequence > 0, attempts > 0, attempts <= 1000, cleanupFailures.count <= 32,
              [reviewDigest, planDigest, inputDigest, engineDigest, dependencyDigest, bindingDigest].allSatisfy(provisioningDigest),
              !state.unfinished || workerOutstanding || state == .queued,
              !workerOutstanding || cleanupRequired,
              state.unfinished || state == .cleanupRequired || !workerOutstanding,
              ![.succeeded, .checked, .restartRequired, .cleanupConfirmed].contains(state) || (!cleanupRequired && !workerOutstanding),
              state != .cleanupRequired || cleanupRequired,
              (commandID == nil && operation == nil) || (commandID != nil && operation != nil && payloadID != nil)
        else { throw ProvisioningJobFailure.journalUnavailable }
    }
}
func provisioningDigest(_ text: String) -> Bool {
    text.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
protocol ProvisioningJobJournaling: Sendable {
    func load() throws -> [ProvisioningJobRecord]
    func save(_ records: [ProvisioningJobRecord]) throws
}

/// Explicit directory only. The app does not instantiate this foundation yet.
/// Owns a BSD file-description lock, private atomic file and revision detector.
final class ProvisioningJobJournal: ProvisioningJobJournaling, @unchecked Sendable {
    static let maximumJobs = 128
    static let maximumBytes = 1024 * 1024
    let directory: URL
    private let mutex = NSLock()
    private let lockFD: Int32
    private let lockInode: ino_t
    private let directoryInode: ino_t
    private let directoryDevice: dev_t
    private var loaded = false, poisoned = false
    private var fingerprint: String?
    private var revision: UInt64 = 0
    private struct Document: Codable { let schemaVersion: Int; let revision: UInt64; let jobs: [ProvisioningJobRecord] }

    init(directory: URL) throws {
        self.directory = directory
        try PrivateFiles.directory(directory, create: true)
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0 else { throw ProvisioningJobFailure.journalUnavailable }
        directoryInode = directoryInfo.st_ino; directoryDevice = directoryInfo.st_dev
        lockFD = open(directory.appendingPathComponent(".journal.lock").path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var info = stat()
        guard lockFD >= 0, fstat(lockFD, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o600 else {
            if lockFD >= 0 { close(lockFD) }
            throw ProvisioningJobFailure.journalUnavailable
        }
        lockInode = info.st_ino
    }
    deinit { close(lockFD) }
    func load() throws -> [ProvisioningJobRecord] {
        try mutex.withLock {
            do {
                try checkLock()
                let url = directory.appendingPathComponent("jobs.json")
                guard PrivateFiles.exists(url) else {
                    guard !loaded || fingerprint == nil else { throw ProvisioningJobFailure.journalUnavailable }
                    loaded = true; return []
                }
                let data = try PrivateFiles.read(url, maximum: Self.maximumBytes)
                if loaded { guard fingerprint == KitVerifier.sha256(data) else { throw ProvisioningJobFailure.journalUnavailable } }
                let value = try PlainDataParser.parse(data, format: .json)
                guard case .object(let root) = value, Set(root.keys) == ["schemaVersion", "revision", "jobs"],
                      root["schemaVersion"] == .integer(1), case .array(let jobs) = root["jobs"], jobs.count <= Self.maximumJobs
                else { throw ProvisioningJobFailure.journalUnavailable }
                for job in jobs {
                    guard case .object(let fields) = job, Set(fields.keys).isSubset(of: Set(ProvisioningJobRecord.CodingKeys.allCases.map(\.rawValue)))
                    else { throw ProvisioningJobFailure.journalUnavailable }
                }
                let document = try JSONDecoder().decode(Document.self, from: data)
                try validate(document.jobs)
                guard document.revision > 0 else { throw ProvisioningJobFailure.journalUnavailable }
                loaded = true; revision = document.revision; fingerprint = KitVerifier.sha256(data)
                return document.jobs
            } catch { poisoned = true; throw ProvisioningJobFailure.journalUnavailable }
        }
    }
    func save(_ records: [ProvisioningJobRecord]) throws {
        try mutex.withLock {
            do {
                guard loaded, !poisoned, revision < UInt64.max else { throw ProvisioningJobFailure.journalUnavailable }
                try checkLock(); try validate(records)
                let file = directory.appendingPathComponent("jobs.json")
                let current = try PrivateFiles.exists(file) ? KitVerifier.sha256(PrivateFiles.read(file, maximum: Self.maximumBytes)) : nil
                guard current == fingerprint else { throw ProvisioningJobFailure.journalUnavailable }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(Document(schemaVersion: 1, revision: revision + 1, jobs: records.sorted { $0.jobID.uuidString < $1.jobID.uuidString }))
                guard data.count <= Self.maximumBytes else { throw ProvisioningJobFailure.journalUnavailable }
                try PrivateFiles.write(data, name: "jobs.json", in: directory)
                guard try PrivateFiles.read(file, maximum: Self.maximumBytes) == data else { throw ProvisioningJobFailure.journalUnavailable }
                revision += 1; fingerprint = KitVerifier.sha256(data)
            } catch { poisoned = true; throw ProvisioningJobFailure.journalUnavailable }
        }
    }
    private func checkLock() throws {
        try PrivateFiles.directory(directory)
        var info = stat(), folder = stat()
        guard lstat(directory.path, &folder) == 0, folder.st_ino == directoryInode, folder.st_dev == directoryDevice else {
            throw ProvisioningJobFailure.journalUnavailable
        }
        guard !poisoned, lstat(directory.appendingPathComponent(".journal.lock").path, &info) == 0,
              info.st_ino == lockInode, info.st_dev == directoryDevice, info.st_nlink == 1, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o600 else { throw ProvisioningJobFailure.journalUnavailable }
    }
    private func validate(_ records: [ProvisioningJobRecord]) throws {
        guard records.count <= Self.maximumJobs, Set(records.map(\.jobID)).count == records.count else { throw ProvisioningJobFailure.journalUnavailable }
        for record in records { try record.validate() }
    }
}
