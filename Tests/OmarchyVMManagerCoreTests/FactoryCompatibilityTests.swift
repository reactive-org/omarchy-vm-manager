import Foundation
import Testing
@testable import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

extension FactoryFixture {
    mutating func compatibleLeanEvidence(mode: String = "valid") throws {
        try leanEvidence(mode: mode)
        let package = "fixture.pkg.tar.zst"
        let bytes = Data("synthetic complete integration package; no guest executable".utf8)
        try bytes.write(to: source.appendingPathComponent(package))
        var policy = try JSONSerialization.jsonObject(with: Data(VMGuestIntegrationContract.reviewedJSON.utf8)) as! [String: Any]
        policy["leanPackageSHA256"] = KitVerifier.sha256(bytes)
        policy["runtimePackageSHA256"] = lock.files[VMFactorySelection.packagePath]!
        integrationContract = try JSONDecoder().decode(VMGuestIntegrationContract.self, from: JSONSerialization.data(withJSONObject: policy))
        var files = manifest["files"] as! [String: String], provisioning = manifest["provisioning"] as! [String: String]
        files[package] = KitVerifier.sha256(bytes); provisioning[package] = KitVerifier.sha256(bytes)
        manifest["files"] = files; manifest["provisioning"] = provisioning; manifest["format"] = 2
        manifest["guestIntegration"] = ["contractVersion": 1, "capabilities": integrationContract.capabilities,
                                        "packageFile": package, "packageSHA256": KitVerifier.sha256(bytes)] as [String: Any]
        lock.factoryCompatibilityVersion = 1
    }
}

@Suite("Independent factory guest compatibility — no guests")
struct FactoryCompatibilityTests {
    @Test("different source and host runtime inventories retain compatible imports without rewriting receipts")
    func sourceAndRuntimeIndependence() throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        try f.compatibleLeanEvidence()
        let sourceCommit = String(repeating: "f", count: 40)
        let build = try JSONSerialization.data(withJSONObject: ["try_commit": sourceCommit])
        try build.write(to: f.source.appendingPathComponent("image-build.json"))
        var files = f.manifest["files"] as! [String: String], provisioning = f.manifest["provisioning"] as! [String: String]
        files["image-build.json"] = KitVerifier.sha256(build); provisioning["image-build.json"] = KitVerifier.sha256(build)
        f.manifest["files"] = files; f.manifest["provisioning"] = provisioning; f.manifest["imageIntegrationSourceCommit"] = sourceCommit
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        let identity = try catalog.importBundle(f.source)
        let receiptData = try PrivateFiles.read(catalog.receiptURL(digest))
        let receipt = try JSONDecoder().decode(FactoryImportReceipt.self, from: receiptData)
        #expect(receipt.schemaVersion == 2 && receipt.guestIntegrationContractSHA256 == catalog.integrationContractSHA256)
        let lockData = try JSONEncoder().encode(f.lock)
        _ = try KitVerifier.inspect(kit: f.kit.kit, lockData: lockData, expectedLockSHA256: KitVerifier.sha256(lockData), policy: .debugPOC, preflight: { nil })
        let helper = f.kit.kit.bundleURL.appendingPathComponent(TryOmarchyKit.helperPath)
        try Data("#!/bin/sh\nexit 0\n# unrelated host helper change\n".utf8).write(to: helper)
        #expect(throws: VMFailure.self) { try KitVerifier.inspect(kit: f.kit.kit, lockData: lockData, expectedLockSHA256: KitVerifier.sha256(lockData), policy: .debugPOC, preflight: { nil }) }
        var object = try JSONSerialization.jsonObject(with: lockData) as! [String: Any]
        object["patchCommit"] = String(repeating: "e", count: 40)
        object["files"] = try KitVerifier.inventory(at: f.kit.kit.bundleURL)
        let changedLock = try JSONSerialization.data(withJSONObject: object)
        _ = try KitVerifier.inspect(kit: f.kit.kit, lockData: changedLock, expectedLockSHA256: KitVerifier.sha256(changedLock), policy: .debugPOC, preflight: { nil })
        let reopened = FactoryCatalog(applicationSupport: f.files.support, kit: f.kit.kit, lockData: changedLock, reviewed: [], integrationContract: f.integrationContract)
        #expect(try reopened.identity(for: digest) == identity)
        #expect(try reopened.importBundle(f.source) == identity)
        #expect(try PrivateFiles.read(reopened.receiptURL(digest)) == receiptData)
        let selection = try #require(try reopened.selection(for: identity))
        let verified = try selection.verified(runtimeBundle: f.kit.kit.bundleURL, reviewedIntegrationContract: f.integrationContract)
        #expect(verified.imageIntegrationSourceCommit == sourceCommit)
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
    }

    @Test("tampered or unreviewed components and unsupported or malformed evidence fail closed", arguments: ["archive", "unreviewed", "protocol", "extra-capability", "contract", "missing", "malformed", "source", "owner", "version", "runtime-package", "runtime-capability"])
    func invalidEvidence(_ mode: String) throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        try f.compatibleLeanEvidence()
        var evidence = f.manifest["guestIntegration"] as! [String: Any]
        if mode == "archive" { try Data("tampered service or script".utf8).write(to: f.source.appendingPathComponent("fixture.pkg.tar.zst")) }
        if mode == "unreviewed" {
            let bytes = Data("different complete package with same version string".utf8)
            try bytes.write(to: f.source.appendingPathComponent("fixture.pkg.tar.zst"))
            var files = f.manifest["files"] as! [String: String], provisioning = f.manifest["provisioning"] as! [String: String]
            files["fixture.pkg.tar.zst"] = KitVerifier.sha256(bytes); provisioning["fixture.pkg.tar.zst"] = KitVerifier.sha256(bytes)
            f.manifest["files"] = files; f.manifest["provisioning"] = provisioning; evidence["packageSHA256"] = KitVerifier.sha256(bytes)
        }
        if mode == "protocol" { var caps = f.integrationContract.capabilities; caps["guestStatus"] = 2; evidence["capabilities"] = caps }
        if mode == "extra-capability" { var caps = f.integrationContract.capabilities; caps["future"] = 1; evidence["capabilities"] = caps }
        if mode == "contract" { evidence["contractVersion"] = 2 }
        if mode == "malformed" { evidence["capabilities"] = ["guestStatus": "one"] }
        if mode == "source" { f.manifest["imageIntegrationSourceCommit"] = "bad" }
        if mode == "owner" { f.manifest["ownerSetupContractSHA256"] = VMOwnerSetupContract.official }
        if mode == "version" { f.manifest["format"] = 99 }
        if mode == "runtime-package" { try Data("tampered runtime package".utf8).write(to: f.kit.kit.bundleURL.appendingPathComponent(VMFactorySelection.packagePath)) }
        if mode == "runtime-capability" { f.lock.factoryCompatibilityVersion = nil }
        f.manifest["guestIntegration"] = mode == "missing" ? nil : evidence
        _ = try f.write()
        do { _ = try f.catalog(reviewed: []).importBundle(f.source); Issue.record("Unsupported integration evidence was accepted") }
        catch let failure as VMFailure {
            let specific = ["archive": "checksum", "unreviewed": "unreviewed SHA-256", "protocol": "protocol", "contract": "contract version", "malformed": "Malformed", "source": "source provenance", "runtime-capability": "runtime lacks"]
            if let fragment = specific[mode] { #expect(failure.message.localizedCaseInsensitiveContains(fragment)) }
        }
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
    }

    @Test("new archive identities require a trusted policy review, never just changed factory metadata")
    func explicitReview() throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        try f.compatibleLeanEvidence(); _ = try f.write()
        let unreviewed = FactoryCatalog(applicationSupport: f.files.support, kit: f.kit.kit, lockData: try JSONEncoder().encode(f.lock), reviewed: [])
        #expect(throws: VMFailure.self) { try unreviewed.importBundle(f.source) }
        let reviewed = try f.catalog(reviewed: [])
        #expect(try reviewed.importBundle(f.source).kind == .custom)
    }

    @Test("legacy receipts retain exact runtime binding and actionable migration without changing their bytes")
    func legacyMigration() throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        _ = try catalog.importBundle(f.source)
        let original = try PrivateFiles.read(catalog.receiptURL(digest))
        var lock = f.lock; lock.launchIntentVersion = 1
        let changed = FactoryCatalog(applicationSupport: f.files.support, kit: f.kit.kit, lockData: try JSONEncoder().encode(lock), reviewed: [])
        do { _ = try changed.identity(for: digest); Issue.record("Legacy receipt was migrated implicitly") }
        catch let failure as VMFailure { #expect(failure.message.contains("separate bundle")) }
        #expect(try PrivateFiles.read(catalog.receiptURL(digest)) == original)
    }

    @Test("legacy lean manifests cannot substitute source and version strings for package evidence")
    func legacyLeanEvidence() throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        try f.leanEvidence(); _ = try f.write()
        do { _ = try f.catalog(reviewed: []).importBundle(f.source); Issue.record("Insufficient legacy lean evidence was accepted") }
        catch let failure as VMFailure { #expect(failure.message.contains("package evidence")) }
    }

    @Test("format-2 receipts reject missing contract bindings, unsupported versions and policy downgrade", arguments: ["missing", "contract", "version", "downgrade"])
    func receiptEvidence(_ mode: String) throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        try f.compatibleLeanEvidence()
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        _ = try catalog.importBundle(f.source)
        let url = catalog.receiptURL(digest)
        var object = try JSONSerialization.jsonObject(with: PrivateFiles.read(url)) as! [String: Any]
        if mode == "missing" { object.removeValue(forKey: "guestIntegrationContractSHA256") }
        if mode == "contract" { object["guestIntegrationContractSHA256"] = String(repeating: "a", count: 64) }
        if mode == "version" { object["schemaVersion"] = 99 }
        if mode == "downgrade" { object["schemaVersion"] = 1; object.removeValue(forKey: "guestIntegrationContractSHA256") }
        let damaged = try JSONSerialization.data(withJSONObject: object)
        try PrivateFiles.write(damaged, name: url.lastPathComponent, in: catalog.receipts)
        #expect(throws: VMFailure.self) { try catalog.identity(for: digest) }
        #expect(throws: VMFailure.self) { try catalog.importBundle(f.source) }
        #expect(try PrivateFiles.read(url) == damaged)
    }

    @Test("compiled helper and preparation helper share the exact reviewed policy")
    func reviewedPolicy() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("Config/GuestIntegrationCompatibility.json"))
        #expect(data == Data(VMGuestIntegrationContract.reviewedJSON.utf8))
        #expect(VMGuestIntegrationContract.current.ownerSetupContractSHA256 == VMOwnerSetupContract.lean)
    }
}
