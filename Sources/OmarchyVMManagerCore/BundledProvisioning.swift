import Darwin
import DevVMProvisioningCore
import Foundation

public struct ProvisioningPackageLayout: Sendable {
    public let contents: URL
    public init(contents: URL) { self.contents = contents.standardizedFileURL }
    var resources: URL { contents.appendingPathComponent("Resources") }
    var binaries: URL { contents.appendingPathComponent("MacOS") }
}
public struct ProvisioningPackageStatus: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceRevision: String
    public let sourceSnapshotSHA256: String
    public let setupAPI: Int
    public let resourceCount: Int
    public let offlinePlanningIntegrated: Bool
    public let executionEnabled: Bool
}

/// Package admission/offline API only. Does not create a runner, probe tools,
/// connect to the manager socket, read a registry/credential or operate a VM.
public enum BundledProvisioning {
    public static let executableNames = ["OmarchyVMProvisioningHelper", "dev-vm-process-host"]
    static func helperExecutableSHA256(_ layout: ProvisioningPackageLayout) throws -> String {
        KitVerifier.sha256(try read(layout.binaries.appendingPathComponent("OmarchyVMProvisioningHelper"), maximum: 32 * 1024 * 1024))
    }
    public static func inspect(_ layout: ProvisioningPackageLayout) throws -> ProvisioningPackageStatus {
        do {
            // A debug SwiftPM override must never substitute another package.
            guard ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"] == nil,
                  ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] == nil else { throw invalid() }
            let lock = try read(layout.resources.appendingPathComponent("DevVMProvisioning.lock.json"), maximum: 65_536)
            guard KitVerifier.sha256(lock) == ProvisioningPackagePin.lockSHA256 else { throw invalid() }
            let resources = try resourceRoot(layout)
            guard try inventory(resources) == ProvisioningPackagePin.resources else { throw invalid() }
            let distribution = try PlainDataParser.parse(read(layout.resources.appendingPathComponent("ProvisioningDistribution.json"), maximum: 65_536), format: .json)
            guard case .object(let distribution) = distribution, Set(distribution.keys) == ["format", "lockSHA256", "engineSHA256", "executables"],
                  distribution["format"] == .integer(1),
                  distribution["lockSHA256"] == .string(ProvisioningPackagePin.lockSHA256),
                  distribution["engineSHA256"] == .string(ProvisioningPackagePin.engineSHA256),
                  case .object(let executables) = distribution["executables"], Set(executables.keys) == Set(executableNames)
            else { throw invalid() }
            for name in executableNames {
                let url = layout.binaries.appendingPathComponent(name)
                guard executables[name] == .string(KitVerifier.sha256(try read(url, maximum: 32 * 1024 * 1024))),
                      access(url.path, X_OK) == 0 else { throw invalid() }
            }
            return ProvisioningPackageStatus(schemaVersion: 1, sourceRevision: ProvisioningPackagePin.revision,
                sourceSnapshotSHA256: ProvisioningPackagePin.sourceSnapshotSHA256,
                setupAPI: 1, resourceCount: ProvisioningPackagePin.resources.count,
                offlinePlanningIntegrated: true, executionEnabled: false)
        } catch { throw invalid() }
    }
    public static func validateManifest(_ url: URL, layout: ProvisioningPackageLayout) throws -> Data {
        _ = try inspect(layout)
        do {
            let manifest = try SetupManifest.read(url)
            _ = try inspect(layout)
            return try JSONSerialization.data(withJSONObject: ["api_version": 1, "schema_version": 1,
                "structure_valid": true, "resolved": false, "execution_available": false,
                "dotfiles": manifest.dotfiles.count, "tasks": manifest.tasks.count, "assets": manifest.assets.count], options: [.sortedKeys])
        } catch let error as VMFailure { throw error }
        catch { throw manifestFailure(error) }
    }
    public static func plan(repository: URL, manifest: String = "vm.yml", layout: ProvisioningPackageLayout) throws -> Data {
        _ = try inspect(layout)
        do {
            let plan = try SetupPlanner.plan(repository: repository, manifest: manifest)
            guard case .object(let document) = plan.document,
                  document["engine"] == (try PlainDataParser.read(resourceRoot(layout).appendingPathComponent("engine-identity.json"))) else { throw invalid() }
            // The library independently checks all bundled resource hashes.
            // Embedded admission is repeated after resolution, with no fallback
            // to a separate source checkout or alternate dependency instance.
            _ = try inspect(layout)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(plan)
        } catch let error as VMFailure { throw error }
        catch { throw manifestFailure(error) }
    }
    private static func manifestFailure(_ error: any Error) -> VMFailure {
        VMFailure(code: (error as? ManifestError)?.description ?? "manifest.file", message: "The offline setup input was refused.")
    }
    private static func invalid() -> VMFailure {
        VMFailure(code: "provisioning-package-invalid", message: "The bundled provisioning package is missing, changed or incompatible.")
    }
    static func resourceRoot(_ layout: ProvisioningPackageLayout) throws -> URL {
        let bundle = layout.resources.appendingPathComponent(ProvisioningPackagePin.resourceBundle)
        let candidates = [bundle.appendingPathComponent("Resources"), bundle.appendingPathComponent("Contents/Resources/Resources")]
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("engine-identity.json").path) }
        guard candidates.count == 1, let value = candidates.first else { throw invalid() }
        return value
    }
    private static func read(_ url: URL, maximum: Int) throws -> Data {
        guard url.path == url.resolvingSymlinksInPath().path else { throw invalid() }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw invalid() }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_mode & 0o022 == 0, before.st_size <= maximum else { throw invalid() }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximum + 1) ?? Data()
        guard data.count == before.st_size, fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw invalid() }
        return data
    }
    private static func inventory(_ root: URL) throws -> [String: String] {
        guard root.path == root.resolvingSymlinksInPath().path else { throw invalid() }
        var files: [String: String] = [:], pending = [(root, "")], total = 0, entries = 0
        while let (directory, prefix) = pending.popLast() {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                entries += 1
                guard entries <= 512, prefix.split(separator: "/").count < 32 else { throw invalid() }
                let url = directory.appendingPathComponent(name), relative = prefix + name
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & 0o022 == 0 else { throw invalid() }
                if info.st_mode & S_IFMT == S_IFDIR { pending.append((url, relative + "/")) }
                else {
                    let bytes = try read(url, maximum: 1024 * 1024); total += bytes.count
                    guard total <= 4 * 1024 * 1024 else { throw invalid() }
                    files[relative] = KitVerifier.sha256(bytes)
                }
            }
        }
        return files
    }
}
