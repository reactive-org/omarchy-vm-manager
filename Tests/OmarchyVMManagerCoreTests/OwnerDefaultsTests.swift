import Foundation
import Testing
@testable import OmarchyVMManagerCore

final class MemoryOwnerVault: OwnerSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Data] = [:]
    var count: Int { lock.withLock { values.count } }
    func save(_ value: Data, reference: UUID) throws { try lock.withLock { guard values[reference] == nil else { throw VMFailure(code: "duplicate-fixture", message: "Duplicate fixture") }; values[reference] = value } }
    func read(reference: UUID) throws -> Data { try lock.withLock { guard let value = values[reference] else { throw VMFailure(code: "missing-fixture", message: "Missing fixture") }; return value } }
    func remove(reference: UUID) throws { lock.withLock { values[reference] = nil } }
}

@Suite("Unattended guest defaults")
struct OwnerDefaultsTests {
    @Test("unconfigured defaults are off and do not read credentials or create VM storage")
    func disabled() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let vault = MemoryOwnerVault(), id = UUID()
        let store = OwnerDefaultsStore(applicationSupport: f.support, vault: vault)
        #expect(try !store.load().enabled)
        #expect(try store.snapshot(for: id) == nil)
        #expect(vault.count == 0)
        #expect(!FileManager.default.fileExists(atPath: f.storage.vms.path))
    }
    @Test("passwords stay in the credential store; defaults and per-guest snapshots are non-secret")
    func protectedCredentials() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let vault = MemoryOwnerVault(), store = OwnerDefaultsStore(applicationSupport: f.support, vault: vault)
        let secret = Data("synthetic-password-no-real-access".utf8)
        let value = try store.save(enabled: true, configuration: OwnerConfiguration(username: "owner", fullName: "Test Owner", email: "owner@example.invalid"), password: secret)
        let reference = try #require(value.credentialReference)
        #expect(try vault.read(reference: reference) == secret)
        let data = try PrivateFiles.read(f.storage.directory.appendingPathComponent("guest-defaults.json"))
        #expect(!String(decoding: data, as: UTF8.self).contains(String(decoding: secret, as: UTF8.self)))
        let snapshot = try #require(try store.snapshot(for: UUID()))
        #expect(!String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains(String(decoding: secret, as: UTF8.self)))
        #expect(snapshot.credentialReference == reference)
    }
    @Test("later edits affect only future snapshots and preserve older credential references")
    func snapshots() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let vault = MemoryOwnerVault(), store = OwnerDefaultsStore(applicationSupport: f.support, vault: vault)
        let firstSecret = Data("first-synthetic-password".utf8), nextSecret = Data("second-synthetic-password".utf8)
        _ = try store.save(enabled: true, configuration: OwnerConfiguration(username: "first", hostnamePrefix: "work"), password: firstSecret)
        let id = UUID(), first = try #require(try store.snapshot(for: id))
        _ = try store.save(enabled: true, configuration: OwnerConfiguration(username: "second", hostnamePrefix: "next"), password: nextSecret)
        let next = try #require(try store.snapshot(for: UUID()))
        #expect(first.configuration.username == "first")
        #expect(first.hostname == "work-" + id.uuidString.prefix(8).lowercased())
        #expect(first.defaultsRevision != next.defaultsRevision)
        #expect(first.credentialReference != next.credentialReference)
        #expect(try vault.read(reference: first.credentialReference) == firstSecret)
        #expect(try vault.read(reference: next.credentialReference) == nextSecret)
        try first.validate(for: id)
        #expect(throws: VMFailure.self) { try first.validate(for: UUID()) }
    }
    @Test("editing non-secret defaults can keep the password without reading it into the form")
    func retainPassword() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let vault = MemoryOwnerVault(), store = OwnerDefaultsStore(applicationSupport: f.support, vault: vault)
        let first = try store.save(enabled: true, configuration: OwnerConfiguration(), password: Data("synthetic-password".utf8))
        let second = try store.save(enabled: true, configuration: OwnerConfiguration(timezone: "UTC", keyboardID: "English (UK)"), password: nil)
        #expect(first.credentialReference == second.credentialReference)
        #expect(vault.count == 1)
    }
    @Test("unknown or externally edited metadata is preserved and cannot silently seed a guest")
    func damagedDefaults() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let vault = MemoryOwnerVault(), store = OwnerDefaultsStore(applicationSupport: f.support, vault: vault)
        _ = try store.save(enabled: true, configuration: OwnerConfiguration(), password: Data("synthetic-password".utf8))
        let file = f.storage.directory.appendingPathComponent("guest-defaults.json")
        let changed = Data("{\"schemaVersion\":2}".utf8)
        try PrivateFiles.write(changed, name: file.lastPathComponent, in: f.storage.directory)
        #expect(throws: (any Error).self) { _ = try store.snapshot(for: UUID()) }
        #expect(throws: (any Error).self) { _ = try store.save(enabled: true, configuration: OwnerConfiguration(), password: Data("replacement-password".utf8)) }
        #expect(vault.count == 1)
        let reopened = OwnerDefaultsStore(applicationSupport: f.support, vault: vault)
        #expect(throws: (any Error).self) { _ = try reopened.load() }
        #expect(try PrivateFiles.read(file) == changed)
    }
    @Test("owner validation blocks reserved users, command/path injection and invalid settings")
    func validation() throws {
        for name in ["root", "daemon", "systemd-network", "bad\nroot", "-option", "space name"] {
            #expect(throws: VMFailure.self) { try OwnerConfiguration(username: name).validate() }
        }
        #expect(throws: VMFailure.self) { try OwnerConfiguration(hostnamePrefix: "../../other").validate() }
        #expect(throws: VMFailure.self) { try OwnerConfiguration(timezone: "../../other").validate() }
        #expect(throws: VMFailure.self) { try OwnerConfiguration(keyboardID: "unsupported").validate() }
        for value in ["", "short", "newline\npassword", "nul\0password"] {
            #expect(throws: VMFailure.self) { try OwnerConfiguration.validatePassword(Data(value.utf8)) }
        }
        #expect(OwnerSetupContract.current.keyboards.contains(where: { $0.id == "English (US)" && $0.keymap == "us" }))
        #expect(OwnerSetupContract.current.programs.count == 3)
    }
}

@Suite("Owner defaults at guest creation")
struct OwnerDefaultsCreationTests {
    @Test("new profiles inherit snapshots; existing and opted-out guests stay unchanged")
    func createsSnapshots() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let registry = try RegistryStore(applicationSupport: f.support); _ = try registry.load()
        let legacy = f.profile(name: "Existing"); try registry.save([legacy])
        let vault = MemoryOwnerVault(), defaults = OwnerDefaultsStore(applicationSupport: f.support, vault: vault)
        _ = try defaults.save(enabled: true, configuration: OwnerConfiguration(username: "first"), password: Data("synthetic-password".utf8))
        let manager = VMManager(runtime: FakeRuntime(), profiles: [legacy], applicationSupport: f.support, hostMemoryMiB: 32768, logicalCPUs: 8, registry: registry, ownerDefaults: defaults)
        let id = try await manager.create(name: "New", memoryMiB: 4096, cpus: 4, clipboardEnabled: true, immersiveMode: false, sshEnabled: false)
        _ = try await manager.create(name: "Manual", memoryMiB: 4096, cpus: 4, clipboardEnabled: true, immersiveMode: false, sshEnabled: false, useOwnerDefaults: false)
        _ = try await manager.saveGuestDefaults(enabled: true, configuration: OwnerConfiguration(username: "second"), password: nil, sshPublicKey: nil)
        _ = try await manager.create(name: "Later", memoryMiB: 4096, cpus: 4, clipboardEnabled: true, immersiveMode: false, sshEnabled: false)
        let rows = await manager.snapshots()
        #expect(rows[0].profile.ownerSetup == nil)
        #expect(rows[1].profile.ownerSetup?.configuration.username == "first")
        #expect(rows[2].profile.ownerSetup == nil)
        #expect(rows[3].profile.ownerSetup?.configuration.username == "second")
        #expect(rows[1].ownerSetupReadiness == .pending)
        #expect(!FileManager.default.fileExists(atPath: f.storage.vms.path))
        let data = try PrivateFiles.read(f.storage.directory.appendingPathComponent("registry.json"))
        let document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(document["schemaVersion"] as? Int == 4)
        #expect(!String(decoding: data, as: UTF8.self).contains("synthetic-password"))
        var changed = try #require(rows.first(where: { $0.id == id })?.profile)
        changed.ownerSetup = rows[3].profile.ownerSetup
        await #expect(throws: VMFailure.self) { try await manager.configure(changed) }
    }
}

@Suite("One-shot owner setup seeds")
struct OwnerSeedTests {
    @Test("a setup snapshot is creation-only; seeds are private, session-bound and removed after completion")
    func seedLifecycle() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var profile = VMProfile(id: UUID(), name: "Synthetic setup", memoryMiB: 4096, cpus: 4)
        let defaults = OwnerDefaults(enabled: true, configuration: OwnerConfiguration(username: "owner"), credentialReference: UUID())
        profile.ownerSetup = try defaults.snapshot(for: profile.id)
        let session = UUID(), secret = Data("synthetic'quote:$() password".utf8)
        let root = try f.storage.prepare(profile, sessionID: session, ownerPassword: secret)
        let owner = ManagedOwnerStorage(root: root)
        let manifest = try JSONDecoder().decode(ManagedOwnerStorage.Manifest.self, from: PrivateFiles.read(root.appendingPathComponent(ManagedOwnerStorage.launchName)))
        #expect(manifest.sessionToken == session)
        #expect(manifest.fingerprint == (try profile.ownerSetup?.fingerprint()))
        #expect(!String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self).contains(String(decoding: secret, as: UTF8.self)))
        #expect(try String(decoding: PrivateFiles.read(owner.bootstrap.appendingPathComponent("owner-setup.json")), as: UTF8.self).contains("synthetic"))
        try owner.clearSeed()
        #expect(!FileManager.default.fileExists(atPath: owner.bootstrap.appendingPathComponent("owner-setup.json").path))
        let second = UUID()
        _ = try f.storage.prepare(profile, sessionID: second, ownerPassword: secret)
        #expect(try JSONDecoder().decode(ManagedOwnerStorage.Manifest.self, from: PrivateFiles.read(root.appendingPathComponent(ManagedOwnerStorage.launchName))).sessionToken == second)
        var missingSnapshot = profile; missingSnapshot.ownerSetup = nil
        #expect(throws: VMFailure.self) { try f.storage.prepare(missingSnapshot) }
        try owner.finish(profile)
        #expect(try owner.completed(profile))
        _ = try f.storage.prepare(profile, ownerPassword: nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(ManagedOwnerStorage.launchName).path))
        var other = VMProfile(id: UUID(), name: "Manual", memoryMiB: 4096, cpus: 4)
        _ = try f.storage.prepare(other)
        other.ownerSetup = try defaults.snapshot(for: other.id)
        #expect(throws: VMFailure.self) { try f.storage.prepare(other, ownerPassword: secret) }
    }
    @Test("cleanup refuses a redirected seed directory and preserves its target")
    func redirectedSeed() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var profile = VMProfile(id: UUID(), name: "Setup", memoryMiB: 4096, cpus: 4)
        profile.ownerSetup = try OwnerDefaults(enabled: true, credentialReference: UUID()).snapshot(for: profile.id)
        let root = try f.storage.prepare(profile, ownerPassword: Data("synthetic-password".utf8))
        let owner = ManagedOwnerStorage(root: root)
        let held = owner.directory.appendingPathComponent("held")
        try FileManager.default.moveItem(at: owner.bootstrap, to: held)
        try FileManager.default.createSymbolicLink(at: owner.bootstrap, withDestinationURL: held)
        #expect(throws: VMFailure.self) { try owner.clearSeed() }
        #expect(FileManager.default.fileExists(atPath: held.appendingPathComponent("owner-setup.json").path))
    }

    @Test("stale and mismatched guest reports cannot complete owner setup")
    func reportIdentity() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var profile = VMProfile(id: UUID(), name: "Setup", memoryMiB: 4096, cpus: 4)
        profile.ownerSetup = try OwnerDefaults(enabled: true, credentialReference: UUID()).snapshot(for: profile.id)
        let root = try f.storage.prepare(profile, ownerPassword: Data("synthetic-password".utf8))
        let shell = root.appendingPathComponent("shell"); try PrivateFiles.directory(shell, create: true)
        let request = VMStartRequest(profile: profile, storageRoot: root)
        var value: [String: Any] = ["schemaVersion": 1, "vmID": profile.id.uuidString, "sessionToken": request.sessionID.uuidString, "fingerprint": try profile.ownerSetup!.fingerprint(), "state": "configured", "owner": "omarchy"]
        func write(_ date: Date = Date()) throws {
            try PrivateFiles.write(JSONSerialization.data(withJSONObject: ["receivedAt": ISO8601DateFormatter().string(from: date), "report": ["managedSetup": value]]), name: "guest-status.json", in: shell)
        }
        try write(); #expect(try OwnerSetupGuestReport.read(request)?.state == "configured")
        value["sessionToken"] = UUID().uuidString; try write()
        #expect(try OwnerSetupGuestReport.read(request) == nil)
        value["sessionToken"] = request.sessionID.uuidString; value["owner"] = "root"; try write()
        #expect(try OwnerSetupGuestReport.read(request) == nil)
        value["owner"] = "omarchy"; try write(.distantPast)
        #expect(try OwnerSetupGuestReport.read(request) == nil)
    }
}
