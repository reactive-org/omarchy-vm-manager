import Darwin
import DevVMProvisioningCore
import Foundation

/// Trusted, reviewed values for a NEW disposable root, never decoded from IPC,
/// manifests, environment, registry, a journal or a tool report. Construction is
/// not user consent or proof that an arbitrary existing VM is disposable.
struct ProvisioningApprovedDisposableRoot: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let vmID: UUID
    let root: URL
    let device: Int64
    let inode: UInt64
    let markerSHA256: String
    var description: String { "ProvisioningApprovedDisposableRoot(redacted)" }
    var debugDescription: String { description }
}

/// Holds directory descriptors so an unlinked approved inode cannot be reused
/// while this process owns the approval. Only path/identity/markers are read.
final class ProvisioningDisposableAdmission: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let approvalID: UUID
    private let roots: [UUID: Root]
    private final class Root: @unchecked Sendable {
        let approved: ProvisioningApprovedDisposableRoot
        private var descriptor: Int32
        init(_ approved: ProvisioningApprovedDisposableRoot) throws {
            self.approved = approved
            descriptor = open(approved.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ProvisioningJobFailure.targetChanged }
            do { try verify() } catch { close(descriptor); descriptor = -1; throw error }
        }
        deinit { if descriptor >= 0 { close(descriptor) } }
        func verify() throws {
            let url = approved.root
            try PrivateFiles.directory(url.deletingLastPathComponent().deletingLastPathComponent())
            try PrivateFiles.directory(url.deletingLastPathComponent()); try PrivateFiles.directory(url)
            func identity() throws {
                var held = stat(), path = stat()
                guard fstat(descriptor, &held) == 0, lstat(url.path, &path) == 0,
                      held.st_mode & S_IFMT == S_IFDIR, held.st_uid == getuid(), held.st_mode & 0o7777 == 0o700,
                      Int64(held.st_dev) == approved.device, UInt64(held.st_ino) == approved.inode,
                      held.st_dev == path.st_dev, held.st_ino == path.st_ino else { throw ProvisioningJobFailure.targetChanged }
            }
            try identity()
            let bytes = try PrivateFiles.read(url.appendingPathComponent(".omarchy-vm-manager.json"))
            let fields = try transportFields(PlainDataParser.parse(bytes, format: .json), required: ["schemaVersion", "id"])
            guard KitVerifier.sha256(bytes) == approved.markerSHA256,
                  fields["schemaVersion"] == .integer(1), fields["id"] == .string(approved.vmID.uuidString),
                  try PrivateFiles.read(url.appendingPathComponent(".omarchy-qemu-storage")) == Data("omarchy-qemu-storage-root-v1\n".utf8) else { throw ProvisioningJobFailure.targetChanged }
            try identity()
        }
    }
    init(approvalID: UUID, roots: [ProvisioningApprovedDisposableRoot]) throws {
        guard (1...8).contains(roots.count), Set(roots.map(\.vmID)).count == roots.count,
              Set(roots.map { $0.root.path }).count == roots.count else { throw ProvisioningJobFailure.invalidRequest }
        for value in roots {
            let url = value.root
            guard !POCProfiles.ids.contains(value.vmID), url.isFileURL, url.host == nil || url.host == "localhost",
                  url.path.hasPrefix("/"), url.path.utf8.count <= 4096,
                  !url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  url.path == url.standardizedFileURL.path, url.path == url.resolvingSymlinksInPath().path,
                  url.lastPathComponent == value.vmID.uuidString,
                  url.deletingLastPathComponent().lastPathComponent == "VMs",
                  url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Omarchy VM Manager",
                  value.inode > 0, provisioningDigest(value.markerSHA256) else { throw ProvisioningJobFailure.invalidRequest }
        }
        self.approvalID = approvalID
        self.roots = try Dictionary(uniqueKeysWithValues: roots.map { ($0.vmID, try Root($0)) })
    }
    func verify(vmID: UUID, root: URL) throws {
        guard let entry = roots[vmID], root.isFileURL, root.lastPathComponent == vmID.uuidString,
              root.path == root.standardizedFileURL.path else { throw ProvisioningJobFailure.targetChanged }
        try PrivateFiles.directory(root)
        // Foundation can retain either /tmp or /private/tmp for the SAME owned
        // tree depending on which ancestor existed when its URL was formed.
        // Use filesystem identity, while PrivateFiles still rejects symlinks.
        guard let actual = realpath(root.path, nil) else { throw ProvisioningJobFailure.targetChanged }
        defer { free(actual) }
        guard let expected = realpath(entry.approved.root.path, nil) else { throw ProvisioningJobFailure.targetChanged }
        defer { free(expected) }
        guard strcmp(actual, expected) == 0 else { throw ProvisioningJobFailure.targetChanged }
        try entry.verify()
    }
    var description: String { "ProvisioningDisposableAdmission(redacted)" }
    var debugDescription: String { description }
}

/// Fixture admission is trusted test composition only, never a product choice.
/// A product build can select disabled or its reviewed disposable scope only.
enum ProvisioningExecutionAdmission: Sendable {
    case disabled
    case disposable(ProvisioningDisposableAdmission)
    case fixture
    func verify(vmID: UUID, root: URL) throws {
        switch self {
        case .disabled: throw ProvisioningServiceFailure.disabled
        case .disposable(let approval): try approval.verify(vmID: vmID, root: root)
        case .fixture: break
        }
    }
    func helperCheck(input: ProvisioningValidatedFrozenContext, transport: ProvisioningValidatedTransport?) throws -> @Sendable () throws -> Void {
        switch self {
        case .disabled: return { throw ProvisioningServiceFailure.disabled }
        case .fixture: return {}
        case .disposable:
            guard let transport, transport.target == input.request.target else { throw ProvisioningJobFailure.targetChanged }
            let vmID = input.request.target.vmID, root = URL(fileURLWithPath: transport.selection.endpoint.root)
            let check: @Sendable () throws -> Void = { try self.verify(vmID: vmID, root: root) }
            try check(); return check
        }
    }
}
