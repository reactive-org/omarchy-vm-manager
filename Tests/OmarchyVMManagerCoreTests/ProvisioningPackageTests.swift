import Darwin
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private final class ProvisioningPackageFixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    var contents: URL { root.appendingPathComponent("Fixture.app/Contents") }
    var layout: ProvisioningPackageLayout { .init(contents: contents) }
    var resources: URL { contents.appendingPathComponent("Resources/" + ProvisioningPackagePin.resourceBundle + "/Resources") }
    init(nested: Bool = false) throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let bundle = contents.appendingPathComponent("Resources/" + ProvisioningPackagePin.resourceBundle)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        if nested { try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true) }
        try FileManager.default.copyItem(at: repo.appendingPathComponent("Vendor/dev-vm/Sources/DevVMProvisioningCore/Resources"), to: nested ? bundle.appendingPathComponent("Contents/Resources/Resources") : resources)
        try FileManager.default.copyItem(at: repo.appendingPathComponent("Config/DevVMProvisioning.lock.json"), to: contents.appendingPathComponent("Resources/DevVMProvisioning.lock.json"))
        var executables: [String: String] = [:]
        for name in BundledProvisioning.executableNames {
            let url = contents.appendingPathComponent("MacOS/" + name), data = Data("fake executable, never launched".utf8)
            try data.write(to: url); chmod(url.path, 0o700); executables[name] = KitVerifier.sha256(data)
        }
        let distribution: [String: Any] = ["format": 1, "lockSHA256": ProvisioningPackagePin.lockSHA256,
            "engineSHA256": ProvisioningPackagePin.engineSHA256, "executables": executables]
        try JSONSerialization.data(withJSONObject: distribution).write(to: contents.appendingPathComponent("Resources/ProvisioningDistribution.json"))
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite("Pinned provisioning package admission") struct ProvisioningPackageTests {
    @Test(arguments: [false, true]) func exactResourceLayouts(nested: Bool) throws {
        let fixture = try ProvisioningPackageFixture(nested: nested)
        let status = try BundledProvisioning.inspect(fixture.layout)
        #expect(status.sourceRevision == "bb3fae22be45b38035fac52aefa0eb270a9d0fea")
        #expect(status.setupAPI == 1 && status.offlinePlanningIntegrated && !status.executionEnabled)
        #expect(status.resourceCount == ProvisioningPackagePin.resources.count)
    }
    @Test(arguments: ["resource", "extra", "lock", "launcher", "distribution", "symlink", "ambiguous"])
    func refusesChangedDistribution(kind: String) throws {
        let fixture = try ProvisioningPackageFixture()
        switch kind {
        case "resource": try Data("{}".utf8).write(to: fixture.resources.appendingPathComponent("catalogue.json"))
        case "extra": try Data().write(to: fixture.resources.appendingPathComponent("extra"))
        case "lock": try Data("{}".utf8).write(to: fixture.contents.appendingPathComponent("Resources/DevVMProvisioning.lock.json"))
        case "launcher": try Data("changed".utf8).write(to: fixture.contents.appendingPathComponent("MacOS/dev-vm-process-host"))
        case "distribution": try Data("{\"format\":1,\"format\":1}".utf8).write(to: fixture.contents.appendingPathComponent("Resources/ProvisioningDistribution.json"))
        case "symlink":
            let file = fixture.resources.appendingPathComponent("catalogue.json")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: fixture.resources.appendingPathComponent("selection.schema.json"))
        default:
            let other = fixture.resources.deletingLastPathComponent().appendingPathComponent("Contents/Resources/Resources")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.resources.appendingPathComponent("engine-identity.json"), to: other.appendingPathComponent("engine-identity.json"))
        }
        #expect(throws: VMFailure.self) { _ = try BundledProvisioning.inspect(fixture.layout) }
    }
    @Test func missingPackageCannotUseDeveloperFallback() throws {
        let fixture = try ProvisioningPackageFixture()
        try FileManager.default.removeItem(at: fixture.contents.appendingPathComponent("Resources/" + ProvisioningPackagePin.resourceBundle))
        #expect(throws: VMFailure.self) { _ = try BundledProvisioning.inspect(fixture.layout) }
    }
}
