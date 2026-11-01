import Foundation

public protocol OwnerSecretStoring: Sendable {
    func save(_ value: Data, reference: UUID) throws
    func read(reference: UUID) throws -> Data
    func remove(reference: UUID) throws
    func requireProtectedCredential(reference: UUID) throws
    func upgradeLegacyCredential(reference: UUID) throws
}

public extension OwnerSecretStoring {
    func upgradeLegacyCredential(reference: UUID) throws {
        throw VMFailure(code: "owner-keychain-upgrade-unavailable", message: "This credential store does not support upgrading saved passwords.")
    }
}

public final class OwnerDefaultsStore: @unchecked Sendable {
    private let directory: URL
    private let vault: any OwnerSecretStoring
    private let access = NSRecursiveLock()
    private var revision: Data?
    private var cached: OwnerDefaults?
    public init(applicationSupport: URL, vault: any OwnerSecretStoring = KeychainOwnerSecretStore()) {
        directory = applicationSupport.resolvingSymlinksInPath().appendingPathComponent("Omarchy VM Manager")
        self.vault = vault
    }
    private var file: URL { directory.appendingPathComponent("guest-defaults.json") }
    public func load() throws -> OwnerDefaults {
        try access.withLock {
            if let cached { return cached }
            try PrivateFiles.directory(directory, create: true)
            if PrivateFiles.exists(file) {
                let data = try PrivateFiles.read(file)
                let value: OwnerDefaults
                do { value = try JSONDecoder().decode(OwnerDefaults.self, from: data); try value.validate() }
                catch { throw OwnerConfiguration.invalid("Guest Defaults is damaged or from an unsupported version. Its file was preserved; existing guests are unchanged.") }
                revision = data; cached = value; return value
            }
            let value = OwnerDefaults(); cached = value; return value
        }
    }
    public func snapshot(for id: UUID) throws -> OwnerSetupOptions? {
        try access.withLock {
            let value = try load()
            if let revision {
                guard try PrivateFiles.read(file) == revision else { throw OwnerConfiguration.invalid("Guest Defaults changed outside the manager. Reopen it before creating a guest.") }
            } else if PrivateFiles.exists(file) { throw OwnerConfiguration.invalid("Guest Defaults appeared outside the manager. Reopen it before creating a guest.") }
            let snapshot = try value.snapshot(for: id)
            if let snapshot { try vault.requireProtectedCredential(reference: snapshot.credentialReference) }
            return snapshot
        }
    }
    public func upgradeSavedPassword() throws {
        let reference = try access.withLock {
            let value = try load()
            if let revision {
                guard try PrivateFiles.read(file) == revision else { throw OwnerConfiguration.invalid("Guest Defaults changed outside the manager. Reopen it before upgrading the saved password.") }
            } else if PrivateFiles.exists(file) { throw OwnerConfiguration.invalid("Guest Defaults appeared outside the manager. Reopen it before upgrading the saved password.") }
            guard let reference = value.credentialReference else { throw OwnerConfiguration.invalid("Save a guest password first.") }
            return reference
        }
        // Authentication may wait for the user. Hold no defaults lock while it does.
        try vault.upgradeLegacyCredential(reference: reference)
    }
    public func save(enabled: Bool, configuration: OwnerConfiguration, password: Data?, sshPublicKey: String? = nil) throws -> OwnerDefaults {
        try access.withLock {
            let before = try load()
            try configuration.validate()
            try PrivateFiles.directory(directory)
            if let revision {
                guard try PrivateFiles.read(file) == revision else { throw OwnerConfiguration.invalid("Guest Defaults changed in another process. Reopen the manager to review it; the file was preserved.") }
            } else if PrivateFiles.exists(file) { throw OwnerConfiguration.invalid("Guest Defaults appeared in another process. Reopen the manager to review it.") }
            if let password { try OwnerConfiguration.validatePassword(password) }
            let publicKey = try sshPublicKey.map { try SSHPublicKey.canonical($0) }
            var reference = before.credentialReference
            guard !enabled || password != nil || reference != nil else { throw OwnerConfiguration.invalid("Enter a password before enabling unattended setup.") }
            if let password { let fresh = UUID(); try vault.save(password, reference: fresh); reference = fresh }
            let value = OwnerDefaults(enabled: enabled, configuration: configuration, credentialReference: reference, sshPublicKey: publicKey)
            try value.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try PrivateFiles.write(data, name: file.lastPathComponent, in: directory, exclusively: revision == nil)
            revision = data; cached = value; return value
        }
    }
}
