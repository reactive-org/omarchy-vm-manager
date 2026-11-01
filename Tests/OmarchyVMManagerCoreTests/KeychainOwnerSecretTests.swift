import Foundation
import LocalAuthentication
import Security
import Testing
@testable import OmarchyVMManagerCore

private final class FixtureOwnerKeychain: OwnerKeychainAccessing, @unchecked Sendable {
    struct ContextSnapshot {
        let context: LAContext?
        let interactionNotAllowed: Bool?
        let reuseDuration: TimeInterval?
        let fallback: String?
        init(_ query: [String: Any]) {
            context = query[kSecUseAuthenticationContext as String] as? LAContext
            interactionNotAllowed = context?.interactionNotAllowed
            reuseDuration = context?.touchIDAuthenticationAllowableReuseDuration
            fallback = context?.localizedFallbackTitle
        }
    }
    var additions: [[String: Any]] = []
    var addContexts: [ContextSnapshot] = []
    var copies: [[String: Any]] = []
    var copyContexts: [ContextSnapshot] = []
    var deletions: [[String: Any]] = []
    var replies: [(OSStatus, CFTypeRef?)] = []
    var addStatus: OSStatus = errSecSuccess
    func add(_ query: [String: Any]) -> OSStatus { additions.append(query); addContexts.append(ContextSnapshot(query)); return addStatus }
    func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        copies.append(query)
        copyContexts.append(ContextSnapshot(query))
        return replies.isEmpty ? (errSecItemNotFound, nil) : replies.removeFirst()
    }
    func delete(_ query: [String: Any]) -> OSStatus { deletions.append(query); return errSecSuccess }
}

@Suite("Biometric guest password policy — no real Keychain or authentication UI")
struct KeychainOwnerSecretTests {
    private let secret = Data("synthetic-owner-password".utf8)

    @Test("new secrets require user presence in the local data protection Keychain")
    func protectedSave() throws {
        let keychain = FixtureOwnerKeychain(), reference = UUID()
        try KeychainOwnerSecretStore(keychain: keychain).save(secret, reference: reference)
        let query = try #require(keychain.additions.first)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrAccount as String] as? String == reference.uuidString)
        #expect(query[kSecAttrService as String] as? String == KeychainOwnerSecretStore.service)
        let expected = try #require(SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil))
        let actual = try #require(query[kSecAttrAccessControl as String])
        #expect(CFEqual(actual as CFTypeRef, expected))
        #expect(keychain.addContexts[0].interactionNotAllowed == true)
        #expect(keychain.copies.isEmpty)
    }

    @Test("each read has exactly one interactive retrieval and a fresh context without unlock reuse")
    func singleApproval() throws {
        let keychain = FixtureOwnerKeychain(), reference = UUID()
        keychain.replies = [(errSecSuccess, secret as CFData), (errSecSuccess, secret as CFData)]
        let store = KeychainOwnerSecretStore(keychain: keychain)
        #expect(try store.read(reference: reference) == secret)
        #expect(try store.read(reference: reference) == secret)
        #expect(keychain.copies.count == 2)
        let contexts = keychain.copyContexts
        #expect(contexts[0].context !== contexts[1].context)
        for (query, context) in zip(keychain.copies, contexts) {
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(query[kSecReturnData as String] as? Bool == true)
            #expect(context.interactionNotAllowed == false)
            #expect(context.reuseDuration == 0)
            #expect(context.fallback == "Use Mac Login Password")
        }
    }

    @Test("cancellation, missing credentials and missing entitlements never retry or fall back to legacy access")
    func failedReads() throws {
        for (status, code) in [(errSecUserCanceled, "owner-authentication-cancelled"),
                               (errSecAuthFailed, "owner-keychain-unavailable"),
                               (errSecMissingEntitlement, "owner-keychain-provisioning-required"),
                               (errSecItemNotFound, "owner-keychain-upgrade-required")] {
            let keychain = FixtureOwnerKeychain()
            keychain.replies = [(status, nil)]
            do {
                _ = try KeychainOwnerSecretStore(keychain: keychain).read(reference: UUID())
                Issue.record("A failed authorization returned a credential")
            } catch let failure as VMFailure { #expect(failure.code == code) }
            #expect(keychain.copies.count == 1)
            #expect(keychain.additions.isEmpty && keychain.deletions.isEmpty)
        }
    }

    @Test("new profile validation reads only metadata and never upgrades implicitly")
    func creationAdmission() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let keychain = FixtureOwnerKeychain()
        let store = OwnerDefaultsStore(applicationSupport: f.support, vault: KeychainOwnerSecretStore(keychain: keychain))
        _ = try store.save(enabled: true, configuration: OwnerConfiguration(), password: secret)
        keychain.replies = [(errSecSuccess, nil), (errSecItemNotFound, nil)]
        #expect(try store.snapshot(for: UUID()) != nil)
        #expect(throws: VMFailure.self) { _ = try store.snapshot(for: UUID()) }
        #expect(keychain.copies.count == 2)
        for (query, context) in zip(keychain.copies, keychain.copyContexts) {
            #expect(query[kSecReturnData as String] == nil)
            #expect(query[kSecReturnAttributes as String] as? Bool == true)
            #expect(context.interactionNotAllowed == true)
        }
        #expect(!FileManager.default.fileExists(atPath: f.storage.vms.path))
    }

    @Test("explicit upgrade keeps the reference and legacy item, and does not authenticate a modern read")
    func legacyUpgrade() throws {
        let keychain = FixtureOwnerKeychain(), reference = UUID()
        keychain.replies = [(errSecItemNotFound, nil), (errSecSuccess, secret as CFData)]
        try KeychainOwnerSecretStore(keychain: keychain).upgradeLegacyCredential(reference: reference)
        #expect(keychain.copies.count == 2)
        let legacy = keychain.copies[1]
        #expect(legacy[kSecUseDataProtectionKeychain as String] as? Bool == false)
        #expect(legacy[kSecAttrService as String] as? String == KeychainOwnerSecretStore.legacyService)
        #expect(legacy[kSecAttrAccount as String] as? String == reference.uuidString)
        #expect(keychain.additions.count == 1)
        #expect(keychain.additions[0][kSecAttrAccount as String] as? String == reference.uuidString)
        #expect(keychain.deletions.isEmpty)
    }

    @Test("upgrade is idempotent and entitlement or legacy authorization failures preserve originals")
    func failedUpgrade() throws {
        for replies: [(OSStatus, CFTypeRef?)] in [[(errSecSuccess, nil)],
                                                 [(errSecMissingEntitlement, nil)],
                                                 [(errSecItemNotFound, nil), (errSecUserCanceled, nil)]] {
            let keychain = FixtureOwnerKeychain(); keychain.replies = replies
            let store = KeychainOwnerSecretStore(keychain: keychain)
            if replies[0].0 == errSecSuccess { try store.upgradeLegacyCredential(reference: UUID()) }
            else { #expect(throws: VMFailure.self) { try store.upgradeLegacyCredential(reference: UUID()) } }
            #expect(keychain.additions.isEmpty && keychain.deletions.isEmpty)
            #expect(keychain.copies.count == replies.count)
        }
        let keychain = FixtureOwnerKeychain()
        keychain.replies = [(errSecItemNotFound, nil), (errSecSuccess, secret as CFData)]
        keychain.addStatus = errSecNotAvailable
        #expect(throws: VMFailure.self) { try KeychainOwnerSecretStore(keychain: keychain).upgradeLegacyCredential(reference: UUID()) }
        #expect(keychain.deletions.isEmpty)
    }

    @Test("upgrading saved defaults preserves metadata and refuses external changes before legacy access")
    func defaultsUpgrade() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let keychain = FixtureOwnerKeychain()
        let store = OwnerDefaultsStore(applicationSupport: f.support, vault: KeychainOwnerSecretStore(keychain: keychain))
        let defaults = try store.save(enabled: true, configuration: OwnerConfiguration(), password: secret)
        let file = f.storage.directory.appendingPathComponent("guest-defaults.json")
        let original = try PrivateFiles.read(file)
        keychain.replies = [(errSecItemNotFound, nil), (errSecSuccess, secret as CFData)]
        try store.upgradeSavedPassword()
        #expect(try PrivateFiles.read(file) == original)
        #expect(try store.load() == defaults)
        #expect(keychain.additions.count == 2)
        #expect(keychain.additions[1][kSecAttrAccount as String] as? String == defaults.credentialReference?.uuidString)
        #expect(keychain.deletions.isEmpty)
        let copies = keychain.copies.count
        try PrivateFiles.write(Data("external synthetic change".utf8), name: file.lastPathComponent, in: f.storage.directory)
        #expect(throws: VMFailure.self) { try store.upgradeSavedPassword() }
        #expect(keychain.copies.count == copies)
    }

    @Test("manual and completed guests skip credentials; pending setup reads once before any storage mutation")
    func launchBoundary() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let keychain = FixtureOwnerKeychain(), store = KeychainOwnerSecretStore(keychain: keychain)
        var profile = f.profile(name: "Synthetic biometric setup")
        let root = f.storage.root(for: profile), owner = ManagedOwnerStorage(root: root)
        #expect(try owner.passwordForLaunch(profile, secrets: store) == nil)
        profile.ownerSetup = try OwnerDefaults(enabled: true, credentialReference: UUID()).snapshot(for: profile.id)
        keychain.replies = [(errSecUserCanceled, nil)]
        #expect(throws: VMFailure.self) { _ = try owner.passwordForLaunch(profile, secrets: store) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        keychain.replies = [(errSecSuccess, secret as CFData)]
        #expect(try owner.passwordForLaunch(profile, secrets: store) == secret)
        #expect(keychain.copies.count == 2)
        _ = try f.storage.prepare(profile, ownerPassword: secret)
        try owner.finish(profile)
        #expect(try owner.passwordForLaunch(profile, secrets: store) == nil)
        #expect(keychain.copies.count == 2)
    }
}
