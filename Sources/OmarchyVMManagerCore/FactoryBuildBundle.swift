import Darwin
import Foundation
import TryOmarchyKitClient

/// Prepares a new flat format-2 bundle from this job's owned output. Existing
/// import/admission independently verifies it; build success grants no approval.
enum FactoryBuildBundle {
    static func prepare(output: URL, destination: URL, name: String, sizeGiB: Int, kit: TryOmarchyKit, lockData: Data, integrationContract contract: VMGuestIntegrationContract = .current) throws -> URL {
        let lock = try JSONDecoder().decode(RuntimeProvenance.self, from: lockData)
        guard lock.files[VMFactorySelection.packagePath] == contract.runtimePackageSHA256 else { throw failure() }
        let image = try JSONDecoder().decode(VMFactoryManifest.Image.self, from: VMFactorySelection.readMetadata(output.appendingPathComponent("factory.json")))
        guard image.format == 1, image.kind == "upstream-shell-factory", image.platform == "aarch64", image.boot == "uefi-limine",
              VMFactoryManifest.safeName(image.compressed.path), image.compressed.path.hasSuffix(".img.zst"),
              image.disk.bytes == Int64(sizeGiB) * 1_073_741_824 else { throw failure() }
        let compatibility = try VMFactorySelection.readMetadata(output.appendingPathComponent("compatibility.json"))
        let build = try VMFactorySelection.readMetadata(output.appendingPathComponent("image-build.json"))
        struct Owner: Decodable { let owner_programs: [String: String]; let packages: [String: String] }
        struct Build: Decodable { let try_commit: String; let guest_boot_tested: Bool; let validation: String }
        let owner = try JSONDecoder().decode(Owner.self, from: compatibility), provenance = try JSONDecoder().decode(Build.self, from: build)
        // The image's evidence selects exactly one reviewed lean owner contract and
        // its reviewed image package; anything else fails closed.
        guard let lean = VMOwnerSetupContract.leanContracts.first(where: { $0.programs == owner.owner_programs }),
              let reviewed = contract.leanContracts.first(where: { $0.ownerSetupContractSHA256 == lean.digest && $0.leanPackageVersion == owner.packages["try-omarchy"] }),
              provenance.try_commit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              !provenance.guest_boot_tested, provenance.validation == "sealed-image-static-checks" else { throw failure() }
        let package = "try-omarchy-" + reviewed.leanPackageVersion + "-aarch64.pkg.tar.zst"
        let sources = ["factory.json": output.appendingPathComponent("factory.json"), image.compressed.path: output.appendingPathComponent(image.compressed.path),
                       "compatibility.json": output.appendingPathComponent("compatibility.json"), "image-build.json": output.appendingPathComponent("image-build.json"), package: output.appendingPathComponent("packages/" + package)]
        guard try VMFactorySelection.digest(sources[image.compressed.path]!) == image.compressed.sha256,
              try VMFactorySelection.digest(sources[package]!) == reviewed.leanPackageSHA256 else { throw failure() }
        // The build floor is checked before starting. Check the actual compressed
        // size again for preparation plus the catalog's independent private copy.
        let bytes = try sources[image.compressed.path]!.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        let available = try destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard bytes < Int.max / 3, available >= Int64(bytes) * 2 + 64 * 1024 * 1024 else { throw VMFailure(code: "factory-build-space", message: "More free space is needed to prepare and import the finished image. The build output was preserved.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw failure() }
        try PrivateFiles.directory(destination, create: true)
        var files: [String: String] = [:]
        for (name, source) in sources {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: target)
            files[name] = try VMFactorySelection.digest(target)
        }
        let value: [String: Any] = ["format": 2, "name": name, "architecture": "aarch64", "boot": "uefi-limine",
            "customFactoryVersion": 1, "managedSSHVersion": 1, "managedSetupVersion": 1, "ownerSetupReportVersion": 1,
            "integrationPackageSHA256": contract.runtimePackageSHA256, "ownerSetupContractSHA256": reviewed.ownerSetupContractSHA256,
            "ownerSetupEvidence": "compatibility.json", "imageBuildEvidence": "image-build.json", "imageIntegrationVersion": reviewed.leanPackageVersion,
            "imageIntegrationSourceCommit": provenance.try_commit, "runtimeFiles": lock.files, "files": files,
            "provisioning": files.filter { $0.key != image.compressed.path && $0.key != "factory.json" },
            "guestIntegration": ["contractVersion": contract.contractVersion, "capabilities": contract.capabilities, "packageFile": package, "packageSHA256": reviewed.leanPackageSHA256]]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let manifest = try JSONDecoder().decode(VMFactoryManifest.self, from: data)
        try manifest.validate()
        try data.write(to: destination.appendingPathComponent("reviewed-factory.json"), options: .withoutOverwriting)
        _ = try VMFactorySelection(bundlePath: destination.path, manifestSHA256: KitVerifier.sha256(data)).verified(runtimeBundle: kit.bundleURL, reviewedIntegrationContract: contract)
        return destination
    }
    private static func failure() -> VMFailure { .init(code: "factory-build-artifact", message: "The built image or its evidence does not satisfy the reviewed factory contract. Output was preserved; no factory was added.") }
}
