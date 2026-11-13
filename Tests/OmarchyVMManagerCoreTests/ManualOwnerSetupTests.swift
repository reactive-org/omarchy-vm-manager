import Foundation
import Testing
@testable import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

extension FactoryFixture {
    /// A lean factory built from Omarchy owner programs nobody has reviewed:
    /// the builder records "owner_setup": "manual" and the manifest names the
    /// manual marker instead of a program contract.
    mutating func manualEvidence(ownerSetup: String? = "manual", contract: String = VMOwnerSetupContract.manual,
                                 programs: [String: String]? = nil, version: String = VMOwnerSetupContract.manualIntegrationVersion) throws {
        try compatibleLeanEvidence(lean: VMOwnerSetupContract.leanA948d8a)
        var unreviewed = VMOwnerSetupContract.leanA948d8a.programs
        unreviewed["/usr/bin/omarchy-provision-owner"] = String(repeating: "c", count: 64)
        var evidence: [String: Any] = ["owner_programs": programs ?? unreviewed, "packages": ["try-omarchy": version]]
        if let ownerSetup { evidence["owner_setup"] = ownerSetup }
        let data = try JSONSerialization.data(withJSONObject: evidence, options: .sortedKeys)
        try data.write(to: source.appendingPathComponent("compatibility.json"))
        var files = manifest["files"] as! [String: String], provisioning = manifest["provisioning"] as! [String: String]
        files["compatibility.json"] = KitVerifier.sha256(data); provisioning["compatibility.json"] = KitVerifier.sha256(data)
        manifest["files"] = files; manifest["provisioning"] = provisioning
        manifest["ownerSetupContractSHA256"] = contract
        manifest["imageIntegrationVersion"] = version
    }
}

@Suite("Manual owner setup factories — no guests")
struct ManualOwnerSetupTests {
    @Test("the marker is a fixed positive digest that no seeded setup accepts")
    func marker() {
        #expect(VMOwnerSetupContract.manual == KitVerifier.sha256(Data("omarchy-vm-manager/manual-owner-setup/v1".utf8)))
        #expect(VMOwnerSetupContract.isManual(VMOwnerSetupContract.manual) && VMOwnerSetupContract.isLeanFactory(VMOwnerSetupContract.manual))
        #expect(!VMOwnerSetupContract.isSupported(VMOwnerSetupContract.manual))
        #expect(!VMOwnerSetupContract.isLean(VMOwnerSetupContract.manual))
        #expect(VMOwnerSetupContract.provenanceContracts.values.contains(VMOwnerSetupContract.manual) == false)
        // Only the reviewed native-rendering package pairs with manual setup.
        let pairings = VMGuestIntegrationContract.current.manualContracts
        #expect(pairings.map(\.leanPackageVersion) == ["0.1.0-48.1"])
        #expect(pairings.first?.leanPackageSHA256 == VMGuestIntegrationContract.runtimeLeanPackageSHA256)
    }

    @Test("a manual factory imports, lists and verifies, and never yields a seedable contract")
    func importsAsManual() throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        try f.manualEvidence()
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        let identity = try catalog.importBundle(f.source)
        #expect(identity.manifestSHA256 == digest)
        #expect(try catalog.ownerSetupContract(for: identity) == VMOwnerSetupContract.manual)
        #expect(try catalog.requiresManualOwnerSetup(identity))
        #expect(try !catalog.requiresManualOwnerSetup(.official) && !catalog.requiresManualOwnerSetup(nil))
        let reopened = try f.catalog(reviewed: [])
        let listing = try reopened.listing()
        #expect(listing.factories == [.official, identity] && listing.manualOwnerSetup == [digest])
        let manifest = try #require(try reopened.selection(for: identity)).verified(runtimeBundle: f.kit.kit.bundleURL, reviewedIntegrationContract: f.integrationContract)
        #expect(manifest.ownerSetupContractSHA256 == VMOwnerSetupContract.manual)
        #expect(f.integrationContract.leanContract(ownerSetupContractSHA256: VMOwnerSetupContract.manual, packageSHA256: manifest.guestIntegration?.packageSHA256) != nil)
        #expect(reopened.integrationContractSHA256s.contains(try reopened.receiptContractSHA256(for: manifest)))
    }

    @Test("a reviewed lean factory is not listed as manual")
    func leanIsNotManual() throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        try f.compatibleLeanEvidence(lean: VMOwnerSetupContract.leanA948d8a); _ = try f.write()
        let catalog = try f.catalog(reviewed: [])
        let identity = try catalog.importBundle(f.source)
        #expect(try !catalog.requiresManualOwnerSetup(identity))
        #expect(try catalog.listing().manualOwnerSetup.isEmpty)
    }

    @Test("manual and reviewed evidence can't stand in for each other, and a manual factory needs the reviewed package version",
          arguments: ["managed-evidence", "missing-verdict", "unknown-verdict", "manual-verdict-lean-contract", "old-package", "legacy-format"])
    func crossedEvidence(_ mode: String) throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        switch mode {
        case "managed-evidence": try f.manualEvidence(ownerSetup: "managed")
        case "missing-verdict": try f.manualEvidence(ownerSetup: nil)
        case "unknown-verdict": try f.manualEvidence(ownerSetup: "automatic")
        case "manual-verdict-lean-contract":
            // Even with the reviewed programs, the builder's manual verdict
            // (perhaps for progress-icon.sh, which this evidence omits) wins.
            try f.manualEvidence(contract: VMOwnerSetupContract.leanA948d8a.digest, programs: VMOwnerSetupContract.leanA948d8a.programs)
        case "old-package": try f.manualEvidence(version: "0.1.0-43.1")
        default: try f.manualEvidence(); f.manifest["format"] = 1
        }
        _ = try f.write()
        #expect(throws: (any Error).self) { try f.catalog(reviewed: []).importBundle(f.source) }
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
    }

    @Test("an owner seed is refused for a manual factory before any seed file is written")
    func seedRefused() throws {
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        var profile = fixture.profile()
        profile.ownerSetup = try OwnerDefaults(enabled: true, configuration: OwnerConfiguration(username: "owner"), credentialReference: UUID()).snapshot(for: profile.id)
        #expect(throws: VMFailure.self) { try ManagedOwnerStorage.admit(profile, contract: VMOwnerSetupContract.manual) }
        try ManagedOwnerStorage.admit(profile, contract: VMOwnerSetupContract.leanA948d8a.digest)
        #expect(throws: VMFailure.self) { try fixture.storage.prepare(profile, ownerPassword: Data("synthetic-password".utf8), ownerContract: VMOwnerSetupContract.manual) }
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.root(for: profile).appendingPathComponent(ManagedOwnerStorage.launchName).path))
        // Without a seed a manual factory prepares normally: Omarchy's own setup runs.
        profile.ownerSetup = nil
        try ManagedOwnerStorage.admit(profile, contract: VMOwnerSetupContract.manual)
        let root = try fixture.storage.prepare(profile, ownerContract: VMOwnerSetupContract.manual)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(ManagedOwnerStorage.launchName).path))
    }

    @Test("creating from a manual factory never applies Guest Defaults and refuses an explicit request")
    func creationRefusesSeed() async throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        try f.manualEvidence()
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        _ = try catalog.importBundle(f.source)
        let registry = try RegistryStore(applicationSupport: f.files.support); _ = try registry.load()
        let defaults = OwnerDefaultsStore(applicationSupport: f.files.support, vault: MemoryOwnerVault())
        _ = try defaults.save(configuration: .init(username: "saved", timezone: "UTC", keyboardID: "English (UK)"), password: Data("synthetic-password".utf8))
        let manager = VMManager(runtime: FakeRuntime(), profiles: [], applicationSupport: f.files.support,
            hostMemoryMiB: 65536, logicalCPUs: 64, registry: registry, ownerDefaults: defaults)
        await manager.installFactoryCatalog(catalog)
        await #expect(throws: VMFailure.self) {
            _ = try await manager.create(name: "Seeded", memoryMiB: 4096, cpus: 4, clipboardEnabled: false, immersiveMode: false, sshEnabled: false, useOwnerDefaults: true, factory: digest)
        }
        let id = try await manager.create(name: "Omarchy setup", memoryMiB: 4096, cpus: 4, clipboardEnabled: false, immersiveMode: false, sshEnabled: false, factory: digest)
        let profile = try #require(await manager.snapshots().first(where: { $0.id == id })?.profile)
        #expect(profile.ownerSetup == nil && profile.factory?.manifestSHA256 == digest)
        // The same defaults still apply to the official factory.
        let official = try await manager.create(name: "Official", memoryMiB: 4096, cpus: 4, clipboardEnabled: false, immersiveMode: false, sshEnabled: false)
        #expect(try #require(await manager.snapshots().first(where: { $0.id == official })?.profile).ownerSetup != nil)
        let response = await GuestCommandService(manager: manager, applicationSupport: f.files.support).execute(GuestCommandRequest(command: .factories))
        #expect(response.manualOwnerSetupFactories == [digest])
    }
}
