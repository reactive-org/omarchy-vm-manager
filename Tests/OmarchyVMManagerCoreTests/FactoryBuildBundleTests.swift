import Foundation
import DevVMProvisioningCore
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

@Suite("Factory build output admission — disposable files only")
struct FactoryBuildBundleTests {
    @Test func bundledRecipeExtractsAndMatchesEveryPinnedStagedInput() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let stage = f.support.appendingPathComponent("ExtractedRecipe")
        try PrivateFiles.directory(stage, create: true)
        let recipe = try FactoryRecipe()
        let result = try await LocalFactoryBuildProcess().run(.init(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", recipe.archive.path, "-C", stage.path], directory: stage, environment: ["PATH": "/usr/bin:/bin"], timeoutSeconds: 30), output: { _ in })
        #expect(result.status == 0)
        try recipe.verifyStaged(stage)
        #expect(!FileManager.default.fileExists(atPath: f.storage.vms.path))
    }
    @Test(arguments: ["valid", "compressed", "archive", "owner", "boot-claim", "size", "runtime"])
    func independentlyAdmitsOnlyCompatibleOutput(_ mode: String) throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        try f.compatibleLeanEvidence()
        let package = "try-omarchy-" + f.integrationContract.leanPackageVersion + "-aarch64.pkg.tar.zst"
        let packages = f.source.appendingPathComponent("packages")
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: f.source.appendingPathComponent("fixture.pkg.tar.zst"), to: packages.appendingPathComponent(package))
        let provenance: [String: Any] = ["try_commit": f.lock.patchCommit, "guest_boot_tested": mode == "boot-claim", "validation": "sealed-image-static-checks"]
        try JSONSerialization.data(withJSONObject: provenance).write(to: f.source.appendingPathComponent("image-build.json"))
        if mode == "compressed" { try Data("corrupt".utf8).write(to: f.source.appendingPathComponent("test.img.zst")) }
        if mode == "archive" { try Data("corrupt".utf8).write(to: packages.appendingPathComponent(package)) }
        if mode == "owner" { try JSONSerialization.data(withJSONObject: ["owner_programs": [:], "packages": ["try-omarchy": f.integrationContract.leanPackageVersion]]).write(to: f.source.appendingPathComponent("compatibility.json")) }
        var lockObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.lock)) as! [String: Any]
        if mode == "runtime" { var files = f.lock.files; files[VMFactorySelection.packagePath] = String(repeating: "f", count: 64); lockObject["files"] = files }
        let lockData = try JSONSerialization.data(withJSONObject: lockObject)
        let destination = f.files.support.appendingPathComponent("Built.factory")
        let prepare = { try FactoryBuildBundle.prepare(output: f.source, destination: destination, name: "Built fixture", sizeGiB: mode == "size" ? 32 : 20, kit: f.kit.kit, lockData: lockData, integrationContract: f.integrationContract) }
        if mode == "valid" {
            let result = try prepare()
            let identity = try f.catalog(reviewed: []).importBundle(result)
            #expect(identity.name == "Built fixture" && identity.kind == .custom)
            let selection = try #require(try f.catalog(reviewed: []).selection(for: identity))
            _ = try selection.verified(runtimeBundle: f.kit.kit.bundleURL, reviewedIntegrationContract: f.integrationContract)
            let names = try FileManager.default.contentsOfDirectory(atPath: result.path)
            #expect(names.count == 6 && !names.contains("provisioning.json"))
        } else {
            #expect(throws: (any Error).self) { _ = try prepare() }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
    }
}
