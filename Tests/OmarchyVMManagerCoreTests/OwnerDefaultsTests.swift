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
