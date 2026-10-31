import Darwin
import Foundation
import TryOmarchyKitClient

struct ManagedOwnerStorage: Sendable {
    let root: URL
    var directory: URL { root.appendingPathComponent(".manager-setup") }
    var bootstrap: URL { directory.appendingPathComponent("bootstrap") }
    static let launchName = ".omarchy-managed-setup.json"
    struct Manifest: Codable, Equatable {
        let schemaVersion: Int
        let vmID: UUID
        let sessionToken: UUID
        var ownerSetupContractSHA256: String? = nil
        let fingerprint: String
        let configuration: OwnerConfiguration
        let hostname: String
    }
    private struct Identity: Codable, Equatable { let vmID: UUID; let fingerprint: String }
    private struct Seed: Encodable { let password: String }
    func completed(_ profile: VMProfile) throws -> Bool {
        guard let setup = profile.ownerSetup else { return false }
        let path = directory.appendingPathComponent("completed.json")
        guard PrivateFiles.exists(path) else { return false }
        try PrivateFiles.directory(directory)
        let value = try JSONDecoder().decode(Identity.self, from: PrivateFiles.read(path))
        guard value == Identity(vmID: profile.id, fingerprint: try setup.fingerprint()) else { throw PrivateFiles.failure("Owner setup completion belongs to another configuration.") }
        return true
    }
    func prepare(_ profile: VMProfile, sessionID: UUID, password: Data?, newRoot: Bool, contract: String = VMOwnerSetupContract.official) throws {
        guard let setup = profile.ownerSetup else { return }
        guard VMOwnerSetupContract.isSupported(contract) else { throw FactoryCatalog.invalid("Unknown owner setup contract.") }
        try setup.validate(for: profile.id)
        let expected = Identity(vmID: profile.id, fingerprint: try setup.fingerprint())
        if !PrivateFiles.exists(directory) {
            guard newRoot else { throw PrivateFiles.failure("Unattended setup cannot be added to an existing disk.") }
            try PrivateFiles.directory(directory, create: true)
            try PrivateFiles.write(JSONEncoder().encode(expected), name: "identity.json", in: directory, exclusively: true)
        }
        try PrivateFiles.directory(directory)
        guard try JSONDecoder().decode(Identity.self, from: PrivateFiles.read(directory.appendingPathComponent("identity.json"))) == expected else { throw PrivateFiles.failure("Owner setup identity changed. Existing storage was preserved.") }
        if try completed(profile) { try clearSeed(); return }
        guard let password else { throw OwnerConfiguration.invalid("The saved setup password is unavailable. Unlock the login Keychain and retry.") }
        try OwnerConfiguration.validatePassword(password)
        try PrivateFiles.directory(bootstrap, create: true)
        let value = Manifest(schemaVersion: 1, vmID: profile.id, sessionToken: sessionID, ownerSetupContractSHA256: contract == VMOwnerSetupContract.official ? nil : contract, fingerprint: expected.fingerprint, configuration: setup.configuration, hostname: setup.hostname)
        let encoded = try JSONEncoder().encode(value)
        try PrivateFiles.write(encoded, name: "manifest.json", in: bootstrap)
        try PrivateFiles.write(JSONEncoder().encode(Seed(password: String(decoding: password, as: UTF8.self))), name: "owner-setup.json", in: bootstrap)
        try PrivateFiles.write(encoded, name: Self.launchName, in: root)
    }
    func finish(_ profile: VMProfile) throws {
        guard let setup = profile.ownerSetup else { return }
        try PrivateFiles.directory(root); try PrivateFiles.directory(directory)
        guard try JSONDecoder().decode(Identity.self, from: PrivateFiles.read(directory.appendingPathComponent("identity.json"))) == Identity(vmID: profile.id, fingerprint: try setup.fingerprint()) else { throw PrivateFiles.failure("Owner setup identity changed before completion.") }
        try PrivateFiles.write(JSONEncoder().encode(Identity(vmID: profile.id, fingerprint: try setup.fingerprint())), name: "completed.json", in: directory)
        try clearSeed()
    }
    func clearSeed() throws {
        try PrivateFiles.directory(root)
        if PrivateFiles.exists(directory) { try PrivateFiles.directory(directory) }
        if PrivateFiles.exists(bootstrap) { try PrivateFiles.directory(bootstrap) }
        for path in [bootstrap.appendingPathComponent("owner-setup.json"), bootstrap.appendingPathComponent("manifest.json"), root.appendingPathComponent(Self.launchName)] {
            if PrivateFiles.exists(path) {
                _ = try PrivateFiles.read(path)
                guard unlink(path.path) == 0 else { throw PrivateFiles.failure("Cannot remove the temporary owner setup seed.") }
            }
        }
    }
}

struct OwnerSetupGuestReport: Decodable {
    let schemaVersion: Int
    let vmID: UUID
    let sessionToken: UUID
    let fingerprint: String
    let state: String
    let owner: String
    let failureCode: String?
    static func read(_ request: VMStartRequest) throws -> Self? {
        struct Record: Decodable { struct Report: Decodable { let managedSetup: OwnerSetupGuestReport? }; let receivedAt: Date; let report: Report }
        let path = request.storageRoot.appendingPathComponent("shell/guest-status.json")
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o022 == 0, info.st_size <= 8192 else { throw PrivateFiles.failure("Unsafe owner setup status.") }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 8193) ?? Data()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(Record.self, from: data)
        guard let value = record.report.managedSetup, let setup = request.profile.ownerSetup,
              record.receivedAt >= request.startedAt.addingTimeInterval(-1), value.schemaVersion == 1,
              value.vmID == request.profile.id, value.sessionToken == request.sessionID,
              value.fingerprint == (try setup.fingerprint()), value.owner == setup.configuration.username,
              ["provisioning", "configured", "error"].contains(value.state),
              value.failureCode == nil || ["contract-mismatch", "invalid-seed", "provisioning-failed", "encrypted-image", "existing-owner", "unsafe-share"].contains(value.failureCode!) else { return nil }
        return value
    }
}
