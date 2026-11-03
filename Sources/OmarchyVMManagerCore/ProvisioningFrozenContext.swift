import Darwin
import DevVMProvisioningCore
import Foundation

/// Writes only into a freshly allocated private UUID tree. Every archive path
/// is traversed relative to retained descriptors; no link or existing file reuse.
final class ProvisioningPrivateInputTree: @unchecked Sendable {
    let directory: URL
    private let parent: URL
    private var rootFD: Int32 = -1, parentFD: Int32 = -1
    private var rootInode: ino_t = 0, parentInode: ino_t = 0
    private var device: dev_t = 0
    init(archive: FrozenInputsArchive, parent: URL) throws {
        self.parent = parent; directory = parent.appendingPathComponent("inputs-" + UUID().uuidString)
        do {
            try PrivateFiles.directory(parent)
            var dirs = Set(archive.directoryPaths)
            let files = Set(archive.filePaths)
            guard files.count == archive.filePaths.count, files.isDisjoint(with: dirs) else { throw ProvisioningJobFailure.artifactUnavailable }
            for path in archive.filePaths + archive.directoryPaths {
                let parts = try frozenRelativeComponents(path)
                for count in 1..<parts.count { dirs.insert(parts.prefix(count).joined(separator: "/")) }
            }
            guard dirs.count <= 4096, files.count <= 4096, files.isDisjoint(with: dirs) else { throw ProvisioningJobFailure.artifactUnavailable }
            parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var p = stat()
            guard parentFD >= 0, fstat(parentFD, &p) == 0 else { throw ProvisioningJobFailure.artifactUnavailable }
            parentInode = p.st_ino; device = p.st_dev
            guard mkdirat(parentFD, directory.lastPathComponent, 0o700) == 0 else { throw ProvisioningJobFailure.artifactUnavailable }
            rootFD = openat(parentFD, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var r = stat()
            guard rootFD >= 0, fstat(rootFD, &r) == 0, r.st_dev == device else { throw ProvisioningJobFailure.artifactUnavailable }
            rootInode = r.st_ino
            let ordered = dirs.sorted { a, b in
                let first = a.split(separator: "/").count, second = b.split(separator: "/").count
                return first == second ? a < b : first < second
            }
            for path in ordered {
                let parts = try frozenRelativeComponents(path), owner = try openDirectory(Array(parts.dropLast()))
                defer { Darwin.close(owner) }
                guard mkdirat(owner, parts.last!, 0o700) == 0 else { throw ProvisioningJobFailure.artifactUnavailable }
            }
            for path in files.sorted() {
                let parts = try frozenRelativeComponents(path), owner = try openDirectory(Array(parts.dropLast()))
                defer { Darwin.close(owner) }
                let fd = openat(owner, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw ProvisioningJobFailure.artifactUnavailable }
                defer { Darwin.close(fd) }
                guard let bytes = archive.data(for: path), let mode = archive.originalMode(for: path) else { throw ProvisioningJobFailure.artifactUnavailable }
                try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: bytes)
                guard fchmod(fd, mode_t(mode)) == 0, fsync(fd) == 0 else { throw ProvisioningJobFailure.artifactUnavailable }
            }
            for path in ordered.reversed() {
                let fd = try openDirectory(try frozenRelativeComponents(path)); defer { Darwin.close(fd) }
                guard fchmod(fd, mode_t(archive.originalMode(for: path) ?? 0o700)) == 0, fsync(fd) == 0 else { throw ProvisioningJobFailure.artifactUnavailable }
            }
            guard fsync(rootFD) == 0, fsync(parentFD) == 0 else { throw ProvisioningJobFailure.artifactUnavailable }
            try verifyRoot()
        } catch {
            if rootFD >= 0 { Darwin.close(rootFD); rootFD = -1 }; if parentFD >= 0 { Darwin.close(parentFD); parentFD = -1 }
            // Preserve failed private metadata; never recursively delete a tree
            // selected by received paths, and never touch VM storage.
            throw ProvisioningJobFailure.artifactUnavailable
        }
    }
    deinit { if rootFD >= 0 { Darwin.close(rootFD) }; if parentFD >= 0 { Darwin.close(parentFD) } }
    func verifyRoot() throws {
        try PrivateFiles.directory(parent); try PrivateFiles.directory(directory)
        var p = stat(), r = stat(), held = stat()
        guard lstat(parent.path, &p) == 0, p.st_ino == parentInode, p.st_dev == device,
              lstat(directory.path, &r) == 0, r.st_ino == rootInode, r.st_dev == device,
              fstat(rootFD, &held) == 0, held.st_ino == rootInode, held.st_dev == device else { throw ProvisioningJobFailure.artifactUnavailable }
    }
    private func openDirectory(_ parts: [String]) throws -> Int32 {
        var current = fcntl(rootFD, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else { throw ProvisioningJobFailure.artifactUnavailable }
        for part in parts {
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(current)
            guard next >= 0 else { throw ProvisioningJobFailure.artifactUnavailable }; current = next
        }
        return current
    }
}
struct ProvisioningValidatedFrozenContext: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let request: ProvisioningRequest
    let approval: ProvisioningApproval
    let receipt: ProvisioningFrozenDeliveryReceipt
    let storage: ProvisioningPrivateInputTree
    var description: String { "ProvisioningValidatedFrozenContext(redacted)" }
    var debugDescription: String { description }
    static func load(_ data: Data, registration: ProvisioningHelperWorkerRegistration, parent: URL) throws -> Self {
        try registration.validate()
        guard let receipt = registration.delivery else { throw ProvisioningJobFailure.artifactUnavailable }
        let (metadata, archive) = try ProvisioningFrozenDelivery.decode(data, expected: receipt, inputDigest: registration.inputDigest)
        let scope = registration.scope, target = try metadata.target.binding()
        guard metadata.jobID == scope.jobID, target.vmID == scope.vmID, target.sessionID == scope.sessionID,
              metadata.mode == registration.mode, metadata.dependencyDigest == scope.dependencyDigest,
              metadata.approval.reviewIdentity == scope.reviewDigest,
              try ProvisioningCoordinator.bindingIdentity(target) == scope.bindingDigest else { throw ProvisioningJobFailure.invalidRequest }
        let storage = try ProvisioningPrivateInputTree(archive: archive, parent: parent)
        let plan = try SetupPlanner.plan(repository: storage.directory, manifest: metadata.manifestPath)
        try storage.verifyRoot()
        guard plan.identity == registration.planDigest, plan.snapshot.identity == registration.inputDigest,
              try ProvisioningCoordinator.engineIdentity(plan) == scope.engineDigest else { throw ProvisioningJobFailure.invalidRequest }
        let request = try ProvisioningRequest(jobID: metadata.jobID, plan: plan, repository: storage.directory,
            target: target, dependencyDigest: metadata.dependencyDigest, mode: metadata.mode,
            tasks: metadata.selectedTasks, includeTasksInCheck: metadata.includeTasksInCheck,
            conflictPolicy: metadata.conflictPolicy, inputLeaseID: metadata.inputLeaseID)
        guard request.reviewIdentity == scope.reviewDigest else { throw ProvisioningJobFailure.approvalRequired }
        try request.plan.verify(in: storage.directory); try storage.verifyRoot()
        return .init(request: request, approval: metadata.approval.value(), receipt: receipt, storage: storage)
    }
}
/// Backends receive a fully revalidated context, never a manager path or a raw
/// archive. Product code deliberately supplies no backend implementation.
protocol ProvisioningDeliveredBackendPreparing: Sendable {
    func prepare(_ input: ProvisioningValidatedFrozenContext, registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperEngineContext
}
struct ProvisioningDeliveredEngineFactory: ProvisioningHelperEnginePreparing {
    let input: ProvisioningValidatedFrozenContext
    let backend: any ProvisioningDeliveredBackendPreparing
    func prepare(_ registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperEngineContext {
        guard registration.delivery == input.receipt else { throw ProvisioningJobFailure.invalidRequest }
        try input.storage.verifyRoot(); try input.request.plan.verify(in: input.storage.directory)
        var result = try await backend.prepare(input, registration: registration)
        guard result.request.reviewIdentity == input.request.reviewIdentity, result.request.repository == input.storage.directory,
              result.approval.reviewIdentity == input.approval.reviewIdentity else { throw ProvisioningJobFailure.invalidRequest }
        result = .init(request: result.request, approval: .init(reviewIdentity: input.approval.reviewIdentity,
            customTasksReviewed: input.approval.customTasksReviewed && result.approval.customTasksReviewed,
            persistentGrantAcknowledged: input.approval.persistentGrantAcknowledged && result.approval.persistentGrantAcknowledged,
            dockerRootAccessAcknowledged: input.approval.dockerRootAccessAcknowledged && result.approval.dockerRootAccessAcknowledged),
            adapter: result.adapter, authority: result.authority, runner: result.runner, admitPackage: result.admitPackage, frozenContext: input, transportContext: result.transportContext)
        return result
    }
}
