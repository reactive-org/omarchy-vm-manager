import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

extension FactoryFixture {
    mutating func leanEvidence(mode: String = "valid", lean: VMOwnerSetupContract.Lean = VMOwnerSetupContract.leanE4fffc6) throws {
        var programs = lean.programs
        if mode == "mixed" { programs["/usr/bin/omarchy-provision-owner"] = OwnerSetupContract.current.programs["/usr/bin/omarchy-provision-owner"] }
        let evidence: [String: Any] = ["owner_programs": programs, "packages": ["try-omarchy": mode == "old-package" ? "0.1.0-36.1" : lean.integrationVersion]]
        let build: [String: String] = ["try_commit": mode == "source" ? String(repeating: "f", count: 40) : lock.patchCommit]
        var files = manifest["files"] as! [String: String], provisioning = manifest["provisioning"] as! [String: String]
        for (name, object) in [("compatibility.json", evidence), ("image-build.json", build as [String: Any])] {
            let data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            try data.write(to: source.appendingPathComponent(name))
            files[name] = KitVerifier.sha256(data); provisioning[name] = KitVerifier.sha256(data)
        }
        manifest["files"] = files; manifest["provisioning"] = provisioning
        manifest["ownerSetupContractSHA256"] = mode == "unknown" ? String(repeating: "a", count: 64) : lean.digest
        manifest["ownerSetupEvidence"] = "compatibility.json"; manifest["imageBuildEvidence"] = "image-build.json"
        manifest["imageIntegrationVersion"] = lean.integrationVersion
        manifest["imageIntegrationSourceCommit"] = lock.patchCommit
        if mode == "missing" { manifest.removeValue(forKey: "ownerSetupEvidence") }
    }
}

@Suite("Reviewed owner contract selection — no guests")
struct OwnerContractTests {
    @Test("official defaults remain unchanged and lean selection binds verified factory and runtime provenance")
    func selection() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (name, digest) in [("OwnerSetupContract", VMOwnerSetupContract.official), ("LeanOwnerSetupContract", VMOwnerSetupContract.lean),
                               ("LeanOwnerSetupContract-a948d8a", VMOwnerSetupContract.leanA948d8a.digest)] {
            #expect(try VMFactorySelection.digest(repository.appendingPathComponent("Sources/OmarchyVMManagerCore/Resources/" + name + ".json")) == digest)
        }
        var fixture = try FactoryFixture(); defer { fixture.cleanup() }
        try fixture.compatibleLeanEvidence()
        let catalog = try fixture.catalog(reviewed: [])
        #expect(try catalog.ownerSetupContract(for: nil) == VMOwnerSetupContract.official)
        #expect(try catalog.ownerSetupContract(for: .official) == VMOwnerSetupContract.official)
        _ = try fixture.write()
        let identity = try catalog.importBundle(fixture.source)
        #expect(try catalog.ownerSetupContract(for: identity) == VMOwnerSetupContract.lean)
        #expect(try catalog.selection(for: identity)?.verified(runtimeBundle: fixture.kit.kit.bundleURL, reviewedIntegrationContract: fixture.integrationContract).ownerSetupContractSHA256 == VMOwnerSetupContract.lean)
        try Data("changed evidence".utf8).write(to: catalog.root(identity.manifestSHA256).appendingPathComponent("compatibility.json"))
        #expect(throws: (any Error).self) { try catalog.selection(for: identity) }
    }

    @Test("each reviewed lean contract is admitted with its own programs and image package", arguments: VMOwnerSetupContract.leanContracts.map(\.name))
    func eachLeanContract(_ name: String) throws {
        let lean = try #require(VMOwnerSetupContract.leanContracts.first { $0.name == name })
        var fixture = try FactoryFixture(); defer { fixture.cleanup() }
        try fixture.compatibleLeanEvidence(lean: lean); _ = try fixture.write()
        let catalog = try fixture.catalog(reviewed: [])
        let identity = try catalog.importBundle(fixture.source)
        #expect(try catalog.ownerSetupContract(for: identity) == lean.digest)
    }

    @Test("a lean contract with another contract's programs or package version is refused")
    func crossedLeanContracts() throws {
        var fixture = try FactoryFixture(); defer { fixture.cleanup() }
        try fixture.compatibleLeanEvidence(lean: VMOwnerSetupContract.leanA948d8a)
        var evidence = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.source.appendingPathComponent("compatibility.json"))) as! [String: Any]
        evidence["owner_programs"] = VMOwnerSetupContract.leanE4fffc6.programs
        let data = try JSONSerialization.data(withJSONObject: evidence, options: .sortedKeys)
        try data.write(to: fixture.source.appendingPathComponent("compatibility.json"))
        var files = fixture.manifest["files"] as! [String: String], provisioning = fixture.manifest["provisioning"] as! [String: String]
        files["compatibility.json"] = KitVerifier.sha256(data); provisioning["compatibility.json"] = KitVerifier.sha256(data)
        fixture.manifest["files"] = files; fixture.manifest["provisioning"] = provisioning
        _ = try fixture.write()
        #expect(throws: (any Error).self) { try fixture.catalog(reviewed: []).importBundle(fixture.source) }
    }

    @Test("unknown, mixed, missing or incompatible lean evidence is refused", arguments: ["unknown", "mixed", "missing", "source", "old-package"])
    func invalidEvidence(_ mode: String) throws {
        var fixture = try FactoryFixture(); defer { fixture.cleanup() }
        try fixture.compatibleLeanEvidence(mode: mode); _ = try fixture.write()
        #expect(throws: (any Error).self) { try fixture.catalog(reviewed: []).importBundle(fixture.source) }
        #expect(!FileManager.default.fileExists(atPath: fixture.files.storage.vms.path))
    }

    @Test("contract capability and seed selection fail closed while retaining per-guest defaults and SSH")
    func seed() throws {
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        var profile = fixture.profile()
        profile.ssh = SSHOptions(hostPort: 2223)
        profile.ownerSetup = try OwnerDefaults(enabled: true, configuration: OwnerConfiguration(username: "owner"), credentialReference: UUID()).snapshot(for: profile.id)
        let identity = profile.id, snapshot = profile.ownerSetup
        let root = try fixture.storage.prepare(profile, ownerPassword: Data("synthetic-password".utf8), ownerContract: VMOwnerSetupContract.lean)
        let owner = ManagedOwnerStorage(root: root)
        let manifest = try JSONDecoder().decode(ManagedOwnerStorage.Manifest.self, from: PrivateFiles.read(root.appendingPathComponent(ManagedOwnerStorage.launchName)))
        #expect(manifest.ownerSetupContractSHA256 == VMOwnerSetupContract.lean)
        #expect(profile.id == identity && profile.ownerSetup == snapshot)
        #expect(manifest.fingerprint == (try snapshot?.fingerprint()))
        #expect(FileManager.default.fileExists(atPath: ManagedSSHStorage(root: root).directory.path))
        #expect(throws: VMFailure.self) { try owner.prepare(profile, sessionID: UUID(), password: Data("synthetic-password".utf8), newRoot: false, contract: String(repeating: "a", count: 64)) }
        var kit = try KitFixture(); defer { kit.cleanup() }
        kit.lock.ownerSetupContractsVersion = 2
        #expect(throws: VMFailure.self) { try KitVerifier.validate(kit.lock, policy: .debugPOC) }
        kit.lock.ownerSetupContractsVersion = 1
        #expect(throws: VMFailure.self) { try KitVerifier.validate(kit.lock, policy: .debugPOC) }
    }
}
