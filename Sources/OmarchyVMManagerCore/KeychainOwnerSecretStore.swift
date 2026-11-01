import Foundation
import LocalAuthentication
import Security

// The adapter permits policy/error tests without touching the user's Keychain or UI.
protocol OwnerKeychainAccessing: Sendable {
    func add(_ query: [String: Any]) -> OSStatus
    func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemOwnerKeychain: OwnerKeychainAccessing {
    func add(_ query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
    func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

public struct KeychainOwnerSecretStore: OwnerSecretStoring {
    static let service = "dev.omarchy.vm-manager.unattended.biometric.v1"
    static let legacyService = "dev.omarchy.vm-manager.unattended"
    private let keychain: any OwnerKeychainAccessing

    public init() { keychain = SystemOwnerKeychain() }
    init(keychain: any OwnerKeychainAccessing) { self.keychain = keychain }

    public static var supportsProtectedStorage: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let team = SecTaskCopyValueForEntitlement(task, "com.apple.developer.team-identifier" as CFString, nil) as? String,
              let appID = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) as? String else { return false }
        return appID == team + ".dev.omarchy.vm-manager"
    }

    private func query(_ reference: UUID, context: LAContext) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: reference.uuidString,
         kSecUseAuthenticationContext as String: context]
    }

    private func context(interactive: Bool) -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = !interactive
        // Every setup attempt must authenticate independently, even just after Mac unlock.
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedReason = "Use the saved guest password to set up this virtual machine."
        context.localizedFallbackTitle = "Use Mac Login Password"
        context.localizedCancelTitle = "Cancel VM Setup"
        return context
    }

    public func save(_ value: Data, reference: UUID) throws {
        try OwnerConfiguration.validatePassword(value)
        let context = context(interactive: false)
        defer { context.invalidate() }
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil) else {
            throw Self.failure(errSecNotAvailable)
        }
        var values = query(reference, context: context)
        values[kSecAttrAccessControl as String] = access
        values[kSecAttrSynchronizable as String] = false
        values[kSecAttrLabel as String] = "Omarchy VM Manager guest setup (Touch ID)"
        values[kSecValueData as String] = value
        let status = keychain.add(values)
        guard status == errSecSuccess else { throw Self.failure(status) }
    }

    public func read(reference: UUID) throws -> Data {
        let context = context(interactive: true)
        defer { context.invalidate() }
        var values = query(reference, context: context)
        values[kSecReturnData as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitOne
        // Keychain performs user-presence authentication itself: no preliminary
        // evaluatePolicy prompt and no second context or legacy retry on failure.
        let (status, item) = keychain.copy(values)
        guard status == errSecSuccess, let data = item as? Data else { throw Self.failure(status) }
        try OwnerConfiguration.validatePassword(data)
        return data
    }

    public func requireProtectedCredential(reference: UUID) throws {
        let status = protectedCredentialStatus(reference)
        guard status == errSecSuccess else { throw Self.failure(status) }
    }

    private func protectedCredentialStatus(_ reference: UUID) -> OSStatus {
        let context = context(interactive: false)
        defer { context.invalidate() }
        var values = query(reference, context: context)
        values[kSecReturnAttributes as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitOne
        return keychain.copy(values).0
    }

    /// Only an explicit Guest Defaults action may read an old login-Keychain item.
    /// Keep its reference and original item so pending guest snapshots remain valid.
    public func upgradeLegacyCredential(reference: UUID) throws {
        let status = protectedCredentialStatus(reference)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Self.failure(status) }
        let context = context(interactive: true)
        defer { context.invalidate() }
        let values: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: false,
            kSecAttrService as String: Self.legacyService,
            kSecAttrAccount as String: reference.uuidString,
            kSecUseAuthenticationContext as String: context,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let (legacyStatus, item) = keychain.copy(values)
        guard legacyStatus == errSecSuccess, let data = item as? Data else { throw Self.failure(legacyStatus) }
        try save(data, reference: reference)
    }

    public func remove(reference: UUID) throws {
        let context = context(interactive: false)
        defer { context.invalidate() }
        let status = keychain.delete(query(reference, context: context))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
    }

    static func failure(_ status: OSStatus) -> VMFailure {
        switch status {
        case errSecUserCanceled:
            VMFailure(code: "owner-authentication-cancelled", message: "Guest setup authentication was cancelled. The VM was not launched. Retry when ready.")
        case errSecMissingEntitlement:
            VMFailure(code: "owner-keychain-provisioning-required", message: "Touch ID password storage requires a signed app with a valid Keychain provisioning profile. This development build cannot access it. Existing credentials were preserved.")
        case errSecItemNotFound:
            VMFailure(code: "owner-keychain-upgrade-required", message: "The protected guest password is unavailable. In Guest Defaults, upgrade the saved password to Touch ID or save it again. Older pending guests need their original credential upgraded; no credential was replaced.")
        default:
            VMFailure(code: "owner-keychain-unavailable", message: "The saved guest password could not be authorized. Retry using Touch ID or your Mac login password. No credential was replaced.")
        }
    }
}
