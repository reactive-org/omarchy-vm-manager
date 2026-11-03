import Darwin
import DevVMProvisioningCore
import Foundation

struct ProvisioningFrozenDeliveryReceipt: Codable, Equatable, Sendable {
    let format: Int
    let sha256: String
    let byteCount: Int
    let metadataSHA256: String
    let archiveSHA256: String
    func validate() throws {
        guard format == 1, byteCount > 12, byteCount <= ProvisioningFrozenDelivery.maximumBytes,
              [sha256, metadataSHA256, archiveSHA256].allSatisfy(provisioningDigest) else { throw ProvisioningJobFailure.artifactUnavailable }
    }
    static func validateDocument(_ value: ManifestValue) throws {
        guard case .object(let fields) = value, Set(fields.keys) == ["format", "sha256", "byteCount", "metadataSHA256", "archiveSHA256"] else { throw ProvisioningJobFailure.artifactUnavailable }
    }
}
struct ProvisioningFrozenRequestMetadata: Codable, Sendable {
    struct Target: Codable, Sendable {
        let vmID: UUID, sessionID: UUID
        let owner: String
        let ownerUID: UInt32
        let hostKeyDigest: String
        func binding() throws -> GuestBinding { try .init(vmID: vmID, sessionID: sessionID, owner: owner, ownerUID: ownerUID, hostKeyDigest: hostKeyDigest) }
    }
    struct Approval: Codable, Sendable {
        let reviewIdentity: String
        let customTasksReviewed: Bool, persistentGrantAcknowledged: Bool, dockerRootAccessAcknowledged: Bool
        func value() -> ProvisioningApproval { .init(reviewIdentity: reviewIdentity, customTasksReviewed: customTasksReviewed, persistentGrantAcknowledged: persistentGrantAcknowledged, dockerRootAccessAcknowledged: dockerRootAccessAcknowledged) }
    }
    let format: Int
    let jobID: UUID
    let manifestPath: String
    let target: Target
    let dependencyDigest: String
    let mode: ProvisioningMode
    let selectedTasks: [String]
    let includeTasksInCheck: Bool
    let conflictPolicy: DotfileConflictPolicy
    let inputLeaseID: UUID?
    let approval: Approval
    init(request: ProvisioningRequest, approval: ProvisioningApproval) {
        format = 1; jobID = request.jobID; manifestPath = request.plan.manifestPath
        target = .init(vmID: request.target.vmID, sessionID: request.target.sessionID, owner: request.target.owner, ownerUID: request.target.ownerUID, hostKeyDigest: request.target.hostKeyDigest)
        dependencyDigest = request.dependencyDigest; mode = request.mode; selectedTasks = request.selectedTasks
        includeTasksInCheck = request.includeTasksInCheck; conflictPolicy = request.conflictPolicy; inputLeaseID = request.inputLeaseID
        self.approval = .init(reviewIdentity: approval.reviewIdentity, customTasksReviewed: approval.customTasksReviewed,
            persistentGrantAcknowledged: approval.persistentGrantAcknowledged, dockerRootAccessAcknowledged: approval.dockerRootAccessAcknowledged)
    }
    static func decode(_ data: Data) throws -> Self {
        let required: Set<String> = ["format", "jobID", "manifestPath", "target", "dependencyDigest", "mode", "selectedTasks", "includeTasksInCheck", "conflictPolicy", "approval"]
        guard data.count <= PlainDataParser.maximumBytes, case .object(let fields) = try PlainDataParser.parse(data, format: .json),
              required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(["inputLeaseID"])),
              case .object(let target) = fields["target"], Set(target.keys) == ["vmID", "sessionID", "owner", "ownerUID", "hostKeyDigest"],
              case .object(let approval) = fields["approval"], Set(approval.keys) == ["reviewIdentity", "customTasksReviewed", "persistentGrantAcknowledged", "dockerRootAccessAcknowledged"] else { throw ProvisioningJobFailure.artifactUnavailable }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.format == 1, value.selectedTasks.count <= 512, Set(value.selectedTasks).count == value.selectedTasks.count,
              value.selectedTasks.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              provisioningDigest(value.dependencyDigest), provisioningDigest(value.approval.reviewIdentity) else { throw ProvisioningJobFailure.artifactUnavailable }
        if let lease = fields["inputLeaseID"] { guard case .string = lease else { throw ProvisioningJobFailure.artifactUnavailable } }
        _ = try frozenRelativeComponents(value.manifestPath); _ = try value.target.binding(); return value
    }
}
/// Private selected bytes and request metadata, never a report or control frame.
struct ProvisioningFrozenDelivery: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumBytes = FrozenInputsArchive.maximumArchiveBytes + PlainDataParser.maximumBytes + 12
    let bytes: Data
    let receipt: ProvisioningFrozenDeliveryReceipt
    var description: String { "ProvisioningFrozenDelivery(redacted)" }
    var debugDescription: String { description }
    init(request: ProvisioningRequest, approval: ProvisioningApproval, archive: Data) throws {
        guard request.reviewIdentity == approval.reviewIdentity else { throw ProvisioningJobFailure.approvalRequired }
        _ = try FrozenInputsArchive(privateArchive: archive, expectedIdentity: request.plan.snapshot.identity)
        let metadata = try helperJSON(ProvisioningFrozenRequestMetadata(request: request, approval: approval))
        _ = try ProvisioningFrozenRequestMetadata.decode(metadata)
        let size = UInt32(metadata.count)
        bytes = Data("DVMCNTX1".utf8) + Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + metadata + archive
        receipt = .init(format: 1, sha256: KitVerifier.sha256(bytes), byteCount: bytes.count,
            metadataSHA256: KitVerifier.sha256(metadata), archiveSHA256: KitVerifier.sha256(archive))
        try receipt.validate()
    }
    static func decode(_ data: Data, expected: ProvisioningFrozenDeliveryReceipt, inputDigest: String) throws -> (ProvisioningFrozenRequestMetadata, FrozenInputsArchive) {
        try expected.validate()
        guard data.count == expected.byteCount, data.count <= maximumBytes, data.prefix(8) == Data("DVMCNTX1".utf8),
              KitVerifier.sha256(data) == expected.sha256 else { throw ProvisioningJobFailure.artifactUnavailable }
        let count = data[8..<12].reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= PlainDataParser.maximumBytes, count <= data.count - 12 else { throw ProvisioningJobFailure.artifactUnavailable }
        let metadata = Data(data[12..<12+count]), archive = Data(data[(12+count)...])
        guard KitVerifier.sha256(metadata) == expected.metadataSHA256, KitVerifier.sha256(archive) == expected.archiveSHA256 else { throw ProvisioningJobFailure.artifactUnavailable }
        return (try ProvisioningFrozenRequestMetadata.decode(metadata), try FrozenInputsArchive(privateArchive: archive, expectedIdentity: inputDigest))
    }
}
func frozenRelativeComponents(_ path: String) throws -> [String] {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !path.isEmpty, path.utf8.count <= 16_384, parts.count <= 64, !path.contains("\\"),
          !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          parts.allSatisfy({ !["", ".", "..", ".git"].contains($0) }) else { throw ProvisioningJobFailure.artifactUnavailable }
    return parts
}
/// A retained, private, read-only source. Never passes its path to the helper.
final class ProvisioningFrozenDeliverySource: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let receipt: ProvisioningFrozenDeliveryReceipt
    private let url: URL
    private var fd: Int32 = -1
    private var original: Stamp?
    private let lock = NSLock()
    private struct Stamp: Equatable {
        let device: dev_t, inode: ino_t, size: off_t, mode: mode_t, owner: uid_t, links: nlink_t
        let modified: Int, nanos: Int, changed: Int, changedNanos: Int
        init(_ s: stat) { device = s.st_dev; inode = s.st_ino; size = s.st_size; mode = s.st_mode; owner = s.st_uid; links = s.st_nlink
            modified = s.st_mtimespec.tv_sec; nanos = s.st_mtimespec.tv_nsec; changed = s.st_ctimespec.tv_sec; changedNanos = s.st_ctimespec.tv_nsec }
    }
    var description: String { "ProvisioningFrozenDeliverySource(redacted)" }
    var debugDescription: String { description }
    init(url: URL, receipt: ProvisioningFrozenDeliveryReceipt) throws {
        self.url = url; self.receipt = receipt
        do {
            try receipt.validate(); try PrivateFiles.directory(url.deletingLastPathComponent())
            guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw ProvisioningJobFailure.artifactUnavailable }
            fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            var info = stat()
            guard fd >= 0, fstat(fd, &info) == 0 else { throw ProvisioningJobFailure.artifactUnavailable }
            original = Stamp(info); _ = try read()
        } catch { if fd >= 0 { Darwin.close(fd); fd = -1 }; throw ProvisioningJobFailure.artifactUnavailable }
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    func read() throws -> Data {
        try lock.withLock {
            try PrivateFiles.directory(url.deletingLastPathComponent())
            var info = stat(), path = stat()
            guard fstat(fd, &info) == 0, lstat(url.path, &path) == 0, Stamp(info) == original, Stamp(path) == original,
                  info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o600, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_size == receipt.byteCount else { throw ProvisioningJobFailure.artifactUnavailable }
            var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while result.count < receipt.byteCount {
                let count = pread(fd, &buffer, min(buffer.count, receipt.byteCount - result.count), off_t(result.count))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ProvisioningJobFailure.artifactUnavailable }
                result.append(contentsOf: buffer.prefix(count))
            }
            guard fstat(fd, &info) == 0, lstat(url.path, &path) == 0, Stamp(info) == original, Stamp(path) == original,
                  KitVerifier.sha256(result) == receipt.sha256 else { throw ProvisioningJobFailure.artifactUnavailable }
            return result
        }
    }
}
