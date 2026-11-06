import DevVMProvisioningCore
import Foundation
import TryOmarchyKitClient

public struct LocalFactoryBuildEnvironment: FactoryBuildEnvironment {
    private let kit: TryOmarchyKit
    private let lockData: Data
    private let importer: @Sendable (URL) async throws -> FactoryIdentity
    public init(kit: TryOmarchyKit, lockData: Data, importer: @escaping @Sendable (URL) async throws -> FactoryIdentity) {
        self.kit = kit; self.lockData = lockData; self.importer = importer
    }
    private func client() throws -> FactoryDockerClient {
        let home = try ProvisioningDevelopmentAdmission.accountApplicationSupport().deletingLastPathComponent().deletingLastPathComponent()
        let paths = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", home.appendingPathComponent(".docker/bin/docker").path, "/Applications/Docker.app/Contents/Resources/bin/docker"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw FactoryBuildFailure.dockerMissing }
        return try FactoryDockerClient(executable: URL(fileURLWithPath: path), home: home, runner: LocalFactoryBuildProcess())
    }
    public func inspect(root: URL) async throws -> FactoryBuildInspection {
        #if !arch(arm64)
        throw FactoryBuildFailure.wrongArchitecture
        #else
        _ = try KitVerifier.inspect(kit: kit, lockData: lockData, expectedLockSHA256: RuntimePin.lockSHA256, policy: .current, preflight: { nil })
        _ = try FactoryRecipe()
        let admission: FactoryDockerAdmission
        do { admission = try await client().inspect() }
        catch FactoryBuildFailure.commandFailed { throw FactoryBuildFailure.dockerUnavailable }
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        return .init(admission: admission, availableBytes: available)
        #endif
    }
    public func build(plan: FactoryBuildPlan, id: UUID, root: URL, admission: FactoryDockerAdmission, output: FactoryBuildOutput, progress: @escaping @Sendable (FactoryBuildStage) async throws -> Void) async throws -> URL {
        let engine = try FactoryBuildEngine(docker: client(), recipe: FactoryRecipe())
        return try await engine.build(plan, jobID: id, root: root, admission: admission, output: output, stage: progress)
    }
    public func prepareAndImport(output: URL, plan: FactoryBuildPlan, id: UUID, root: URL) async throws -> FactoryIdentity {
        let kit = kit, lockData = lockData
        let bundle = try await Task.detached {
            try FactoryBuildBundle.prepare(output: output, destination: root.appendingPathComponent(id.uuidString).appendingPathComponent("Prepared.factory"), name: plan.name, sizeGiB: plan.sizeGiB, kit: kit, lockData: lockData)
        }.value
        try Task.checkCancellation()
        return try await importer(bundle)
    }
    public func cleanup(id: UUID, admission: FactoryDockerAdmission) async throws {
        try await FactoryBuildEngine(docker: client(), recipe: FactoryRecipe()).cleanup(jobID: id, admission: admission)
    }
}
