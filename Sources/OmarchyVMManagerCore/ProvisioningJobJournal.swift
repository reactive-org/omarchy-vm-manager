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
    case artifactUnavailable, ownershipUnverified
    case helperUnavailable
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
    var inputArchiveSHA256: String?
    var cleanupCheckpointSHA256: String?
    var workerToken: UUID?
    var helperIdentity: ProvisioningHelperIdentity?
    var helperRegistrationDigest: String?
    var helperRegistered: Bool?
    var helperActivationID: UUID?
    var helperActivationDigest: String?
    var helperDelivery: ProvisioningFrozenDeliveryReceipt?
    var snapshot: ProvisioningJobSnapshot {
        .init(jobID: jobID, vmID: vmID, sessionID: sessionID, sequence: sequence, state: state,
              outcome: outcome, failure: failure, engineFailure: engineFailure, cleanupFailures: cleanupFailures,
              cleanupRequired: cleanupRequired, workerOutstanding: workerOutstanding)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case jobID, vmID, sessionID, reviewDigest, planDigest, inputDigest, engineDigest, dependencyDigest, bindingDigest, mode
        case sequence, state, outcome, failure, engineFailure, cleanupFailures, cleanupRequired, workerOutstanding, payloadID, commandID, operation, attempts
        case inputArchiveSHA256, cleanupCheckpointSHA256, workerToken
        case helperIdentity, helperRegistrationDigest, helperRegistered
        case helperActivationID, helperActivationDigest
        case helperDelivery
    }
    func validate() throws {
        let durable = inputArchiveSHA256 != nil || cleanupCheckpointSHA256 != nil || workerToken != nil
        let helper = helperIdentity != nil || helperRegistrationDigest != nil || helperRegistered != nil
        guard !helper || (helperIdentity != nil && helperRegistrationDigest.map(provisioningDigest) == true && helperRegistered != nil && durable) else { throw ProvisioningJobFailure.journalUnavailable }
        if let helperIdentity { do { try helperIdentity.validate() } catch { throw ProvisioningJobFailure.journalUnavailable } }
        if let helperDelivery {
            guard helperIdentity != nil, helperDelivery.archiveSHA256 == inputArchiveSHA256 else { throw ProvisioningJobFailure.journalUnavailable }
            do { try helperDelivery.validate() } catch { throw ProvisioningJobFailure.journalUnavailable }
        }
        guard (helperActivationID == nil && helperActivationDigest == nil) ||
                (helperActivationID != nil && helperActivationDigest.map(provisioningDigest) == true && helperRegistered == true && helperIdentity != nil) else { throw ProvisioningJobFailure.journalUnavailable }
        guard !durable || (inputArchiveSHA256.map(provisioningDigest) == true && cleanupCheckpointSHA256.map(provisioningDigest) == true && workerToken != nil && payloadID != nil),
              sequence > 0, sequence <= UInt64(Int64.max), attempts > 0, attempts <= 1000, cleanupFailures.count <= 32,
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
    func close()
}
extension ProvisioningJobJournaling { func close() {} }

/// Explicit directory only. The app does not instantiate this foundation yet.
/// Owns a BSD file-description lock, private atomic file and revision detector.
final class ProvisioningJobJournal: ProvisioningJobJournaling, @unchecked Sendable {
    static let maximumJobs = 128
    static let maximumBytes = PlainDataParser.maximumBytes
    let directory: URL
    private let mutex = NSLock()
    private var lockFD: Int32
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
            if lockFD >= 0 { Darwin.close(lockFD) }
            throw ProvisioningJobFailure.journalUnavailable
        }
        lockInode = info.st_ino
    }
    deinit { if lockFD >= 0 { Darwin.close(lockFD) } }
    func close() { mutex.withLock { if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }; poisoned = true } }
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
                      [ManifestValue.integer(1), .integer(2), .integer(3), .integer(4), .integer(5)].contains(root["schemaVersion"] ?? .null),
                      case .array(let jobs) = root["jobs"], jobs.count <= Self.maximumJobs
                else { throw ProvisioningJobFailure.journalUnavailable }
                for job in jobs {
                    guard case .object(let fields) = job, Set(fields.keys).isSubset(of: Set(ProvisioningJobRecord.CodingKeys.allCases.map(\.rawValue)))
                    else { throw ProvisioningJobFailure.journalUnavailable }
                    if root["schemaVersion"] == .integer(1) {
                        guard Set(fields.keys).isDisjoint(with: ["inputArchiveSHA256", "cleanupCheckpointSHA256", "workerToken"]) else { throw ProvisioningJobFailure.journalUnavailable }
                    }
                    if [.integer(1), .integer(2)].contains(root["schemaVersion"] ?? .null) {
                        guard Set(fields.keys).isDisjoint(with: ["helperIdentity", "helperRegistrationDigest", "helperRegistered"]) else { throw ProvisioningJobFailure.journalUnavailable }
                    }
                    if ![ManifestValue.integer(4), .integer(5)].contains(root["schemaVersion"] ?? .null) {
                        guard Set(fields.keys).isDisjoint(with: ["helperActivationID", "helperActivationDigest"]) else { throw ProvisioningJobFailure.journalUnavailable }
                    }
                    if let receipt = fields["helperDelivery"] {
                        guard root["schemaVersion"] == .integer(5) else { throw ProvisioningJobFailure.journalUnavailable }
                        try ProvisioningFrozenDeliveryReceipt.validateDocument(receipt)
                    }
                    let activationKeys: Set<String> = ["helperActivationID", "helperActivationDigest"]
                    if !activationKeys.isDisjoint(with: Set(fields.keys)) {
                        guard activationKeys.isSubset(of: Set(fields.keys)), case .string = fields["helperActivationID"], case .string = fields["helperActivationDigest"] else { throw ProvisioningJobFailure.journalUnavailable }
                    }
                    let helperKeys: Set<String> = ["helperIdentity", "helperRegistrationDigest", "helperRegistered"]
                    guard helperKeys.isDisjoint(with: Set(fields.keys)) || helperKeys.isSubset(of: Set(fields.keys)) else { throw ProvisioningJobFailure.journalUnavailable }
                    if let identity = fields["helperIdentity"] { try ProvisioningHelperCredentials.validateIdentity(identity) }
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
                guard loaded, !poisoned, revision < UInt64(Int64.max) else { throw ProvisioningJobFailure.journalUnavailable }
                try checkLock(); try validate(records)
                let file = directory.appendingPathComponent("jobs.json")
                let current = try PrivateFiles.exists(file) ? KitVerifier.sha256(PrivateFiles.read(file, maximum: Self.maximumBytes)) : nil
                guard current == fingerprint else { throw ProvisioningJobFailure.journalUnavailable }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(Document(schemaVersion: 5, revision: revision + 1, jobs: records.sorted { $0.jobID.uuidString < $1.jobID.uuidString }))
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
