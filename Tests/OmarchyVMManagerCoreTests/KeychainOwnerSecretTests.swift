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

@Test("compiled credential policy keeps release modes on the protected store")
func compiledCredentialStoragePolicy() {
    #if DEBUG && !SIGNED_PRERELEASE
    #expect(KeychainOwnerSecretStore.usesDevelopmentKeychain == !KeychainOwnerSecretStore.supportsProtectedStorage)
    #else
    #expect(!KeychainOwnerSecretStore.usesDevelopmentKeychain)
    #endif
}

@Suite("Development Keychain compatibility — synthetic credentials only")
struct DevelopmentOwnerSecretTests {
    private let secret = Data("synthetic-legacy-owner-password".utf8)

    @Test("only unprovisioned debug builds choose the login Keychain")
    func storageSelection() {
        for debugBuild in [false, true] {
            for signedPrerelease in [false, true] {
                for entitlements in [false, true] {
                    let mode = OwnerCredentialStorage.select(debugBuild: debugBuild, signedPrerelease: signedPrerelease, protectedEntitlements: entitlements)
                    #expect((mode == .loginKeychain) == (debugBuild && !signedPrerelease && !entitlements))
                }
            }
        }
    }

    @Test("development reads the original service and UUID once without migrating or replacing it")
    func originalCredential() throws {
        let keychain = FixtureOwnerKeychain(), reference = UUID()
        keychain.replies = [(errSecSuccess, secret as CFData)]
        let store = KeychainOwnerSecretStore(keychain: keychain, storage: .loginKeychain)
        #expect(try store.read(reference: reference) == secret)
        #expect(keychain.copies.count == 1)
        let query = keychain.copies[0]
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
        #expect(query[kSecAttrService as String] as? String == KeychainOwnerSecretStore.legacyService)
        #expect(query[kSecAttrAccount as String] as? String == reference.uuidString)
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(keychain.copyContexts[0].interactionNotAllowed == false)
        #expect(keychain.additions.isEmpty && keychain.deletions.isEmpty)
    }

    @Test("saving development defaults uses legacy protection and snapshot creation reads no credentials")
    func defaultsCompatibility() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let keychain = FixtureOwnerKeychain()
        let store = OwnerDefaultsStore(applicationSupport: f.support, vault: KeychainOwnerSecretStore(keychain: keychain, storage: .loginKeychain))
        let defaults = try store.save(enabled: true, configuration: OwnerConfiguration(), password: secret)
        let metadata = f.storage.directory.appendingPathComponent("guest-defaults.json")
        let before = try PrivateFiles.read(metadata)
        let snapshot = try #require(try store.snapshot(for: UUID()))
        #expect(snapshot.credentialReference == defaults.credentialReference)
        #expect(try PrivateFiles.read(metadata) == before)
        #expect(keychain.copies.isEmpty && keychain.deletions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.storage.vms.path))
        let query = try #require(keychain.additions.first)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
        #expect(query[kSecAttrService as String] as? String == KeychainOwnerSecretStore.legacyService)
        #expect(query[kSecAttrAccount as String] as? String == defaults.credentialReference?.uuidString)
        #expect(query[kSecAttrAccessControl as String] == nil)
        #expect(query[kSecAttrAccessible as String] == nil)
        #expect(query[kSecAttrSynchronizable as String] == nil)
        #expect(keychain.addContexts[0].interactionNotAllowed == false)
    }

    @Test("legacy failures do not probe the protected store or alter either credential")
    func failuresPreserveCredentials() throws {
        for status in [errSecUserCanceled, errSecAuthFailed, errSecItemNotFound, errSecInteractionNotAllowed] {
            let keychain = FixtureOwnerKeychain()
            keychain.replies = [(status, nil)]
            let store = KeychainOwnerSecretStore(keychain: keychain, storage: .loginKeychain)
            do {
                _ = try store.read(reference: UUID())
                Issue.record("A failed legacy read returned a password")
            } catch let failure as VMFailure {
                #expect(failure.code == (status == errSecUserCanceled ? "owner-authentication-cancelled" : "owner-keychain-unavailable"))
            }
            #expect(keychain.copies.count == 1)
            #expect(keychain.copies[0][kSecUseDataProtectionKeychain as String] as? Bool == false)
            #expect(keychain.additions.isEmpty && keychain.deletions.isEmpty)
        }
        let keychain = FixtureOwnerKeychain()
        keychain.addStatus = errSecDuplicateItem
        let store = KeychainOwnerSecretStore(keychain: keychain, storage: .loginKeychain)
        #expect(throws: VMFailure.self) { try store.save(secret, reference: UUID()) }
        #expect(keychain.additions.count == 1)
        #expect(keychain.copies.isEmpty && keychain.deletions.isEmpty)
    }

    @Test("a development build cannot upgrade or create a biometric copy implicitly")
    func noUpgradeInDevelopment() throws {
        let keychain = FixtureOwnerKeychain()
        let store = KeychainOwnerSecretStore(keychain: keychain, storage: .loginKeychain)
        #expect(throws: VMFailure.self) { try store.upgradeLegacyCredential(reference: UUID()) }
        #expect(keychain.copies.isEmpty && keychain.additions.isEmpty && keychain.deletions.isEmpty)
    }
}

@Suite("Biometric guest password policy — no real Keychain or authentication UI")
struct KeychainOwnerSecretTests {
    private let secret = Data("synthetic-owner-password".utf8)

    @Test("both credential modes and explicit upgrades stay inside their app channel")
    func channelIsolation() throws {
        let reference = UUID()
        for channel in AppChannel.allCases {
            for mode in [OwnerCredentialStorage.loginKeychain, .protectedKeychain] {
                let keychain = FixtureOwnerKeychain()
                let store = KeychainOwnerSecretStore(keychain: keychain, storage: mode, channel: channel)
                try store.save(secret, reference: reference)
                keychain.replies = [(errSecSuccess, secret as CFData)]
                _ = try store.read(reference: reference)
                try store.remove(reference: reference)
                let expected = mode == .protectedKeychain ? channel.credentialService : channel.legacyCredentialService
                for query in keychain.additions + keychain.copies + keychain.deletions {
                    #expect(query[kSecAttrService as String] as? String == expected)
                    #expect(query[kSecAttrAccount as String] as? String == reference.uuidString)
                }
            }
            let keychain = FixtureOwnerKeychain()
            keychain.replies = [(errSecItemNotFound, nil), (errSecSuccess, secret as CFData)]
            let store = KeychainOwnerSecretStore(keychain: keychain, channel: channel)
            #expect(try store.upgradeLegacyCredential(reference: reference) == .upgraded)
            #expect(keychain.copies[0][kSecAttrService as String] as? String == channel.credentialService)
            #expect(keychain.copies[1][kSecAttrService as String] as? String == channel.legacyCredentialService)
            #expect(keychain.additions[0][kSecAttrService as String] as? String == channel.credentialService)
            #expect(keychain.deletions.isEmpty)
        }
    }

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
                               (errSecInteractionNotAllowed, "owner-authentication-ui-unavailable"),
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
            #expect(query[kSecReturnData as String] as? Bool == false)
            #expect(query[kSecReturnAttributes as String] as? Bool == true)
            #expect(context.interactionNotAllowed == true)
        }
        #expect(!FileManager.default.fileExists(atPath: f.storage.vms.path))
    }

    @Test("blocked metadata defers only admission; first-launch password reads still fail closed")
    func blockedMetadataAdmission() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let keychain = FixtureOwnerKeychain()
        let vault = KeychainOwnerSecretStore(keychain: keychain)
        let store = OwnerDefaultsStore(applicationSupport: f.support, vault: vault)
        let defaults = try store.save(enabled: true, configuration: OwnerConfiguration(), password: secret)
        let reference = try #require(defaults.credentialReference)
        let original = try PrivateFiles.read(f.storage.directory.appendingPathComponent("guest-defaults.json"))
        keychain.replies = [(errSecInteractionNotAllowed, nil), (errSecInteractionNotAllowed, nil),
                            (errSecInteractionNotAllowed, nil)]
        #expect(try store.snapshot(for: UUID()) != nil)
        #expect(try store.upgradeSavedPassword() == .authenticationPending)
        #expect(keychain.copies.count == 2)
        for (query, context) in zip(keychain.copies, keychain.copyContexts) {
            #expect(query[kSecReturnAttributes as String] as? Bool == true)
            #expect(query[kSecReturnData as String] as? Bool == false)
            #expect(query[kSecAttrAccount as String] as? String == reference.uuidString)
            #expect(context.interactionNotAllowed == true)
        }
        do {
            _ = try vault.read(reference: reference)
            Issue.record("A blocked protected read returned a password")
        } catch let failure as VMFailure {
            #expect(failure.code == "owner-authentication-ui-unavailable")
            #expect(failure.message.contains(String(errSecInteractionNotAllowed)))
        }
        #expect(keychain.copies.count == 3)
        #expect(keychain.copies[2][kSecReturnData as String] as? Bool == true)
        #expect(keychain.copyContexts[2].interactionNotAllowed == false)
        #expect(keychain.additions.count == 1 && keychain.deletions.isEmpty)
        #expect(try PrivateFiles.read(f.storage.directory.appendingPathComponent("guest-defaults.json")) == original)
        #expect(!FileManager.default.fileExists(atPath: f.storage.vms.path))
    }

    @Test("metadata authentication/provisioning failures stay distinct from deferred approval")
    func metadataFailures() throws {
        for status in [errSecAuthFailed, errSecMissingEntitlement, errSecItemNotFound, errSecParam] {
            let keychain = FixtureOwnerKeychain()
            keychain.replies = [(status, nil)]
            #expect(throws: VMFailure.self) {
                try KeychainOwnerSecretStore(keychain: keychain).requireProtectedCredential(reference: UUID())
            }
            #expect(keychain.copies.count == 1)
            #expect(keychain.additions.isEmpty && keychain.deletions.isEmpty)
        }
        let failure = KeychainOwnerSecretStore.failure(errSecParam)
        #expect(failure.message.contains(String(errSecParam)))
        #expect(!failure.message.contains(String(decoding: secret, as: UTF8.self)))
    }

    @Test("explicit upgrade keeps the reference and legacy item, and does not authenticate a modern read")
    func legacyUpgrade() throws {
        let keychain = FixtureOwnerKeychain(), reference = UUID()
        keychain.replies = [(errSecItemNotFound, nil), (errSecSuccess, secret as CFData)]
        #expect(try KeychainOwnerSecretStore(keychain: keychain).upgradeLegacyCredential(reference: reference) == .upgraded)
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
            if replies[0].0 == errSecSuccess { #expect(try store.upgradeLegacyCredential(reference: UUID()) == .alreadyProtected) }
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
        for status in [errSecUserCanceled, errSecInteractionNotAllowed] {
            keychain.replies = [(status, nil)]
            #expect(throws: VMFailure.self) { _ = try owner.passwordForLaunch(profile, secrets: store) }
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
        keychain.replies = [(errSecSuccess, secret as CFData)]
        #expect(try owner.passwordForLaunch(profile, secrets: store) == secret)
        #expect(keychain.copies.count == 3)
        _ = try f.storage.prepare(profile, ownerPassword: secret)
        try owner.finish(profile)
        #expect(try owner.passwordForLaunch(profile, secrets: store) == nil)
        #expect(keychain.copies.count == 3)
    }
}
