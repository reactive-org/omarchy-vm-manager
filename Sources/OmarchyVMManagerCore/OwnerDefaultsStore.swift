import Foundation
import LocalAuthentication
import Security

public protocol OwnerSecretStoring: Sendable {
    func save(_ value: Data, reference: UUID) throws
    func read(reference: UUID) throws -> Data
    func remove(reference: UUID) throws
}

public struct KeychainOwnerSecretStore: OwnerSecretStoring {
    public init() {}
    private func query(_ reference: UUID) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.omarchy.vm-manager.unattended",
         kSecAttrAccount as String: reference.uuidString,
         kSecUseAuthenticationContext as String: context]
    }
    public func save(_ value: Data, reference: UUID) throws {
        try OwnerConfiguration.validatePassword(value)
        var values = query(reference)
        values[kSecValueData as String] = value
        values[kSecAttrLabel as String] = "Omarchy VM Manager guest setup"
        let result = SecItemAdd(values as CFDictionary, nil)
        guard result == errSecSuccess else { throw unavailable() }
    }
    public func read(reference: UUID) throws -> Data {
        var values = query(reference)
        values[kSecReturnData as String] = true; values[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(values as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { throw unavailable() }
        try OwnerConfiguration.validatePassword(data)
        return data
    }
    public func remove(reference: UUID) throws {
        let result = SecItemDelete(query(reference) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw unavailable() }
    }
    private func unavailable() -> VMFailure { VMFailure(code: "owner-keychain-unavailable", message: "The saved guest password is unavailable in Keychain. Unlock your login keychain or save a new password in Guest Defaults. No credential was replaced.") }
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
            return try value.snapshot(for: id)
        }
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
