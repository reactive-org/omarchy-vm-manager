#if DEBUG
import DevVMProvisioningCore
import Foundation
@testable import OmarchyVMManagerCore

/// Runs in a separate process after its predecessor deliberately exited without
/// closing the admitted worker. Disk metadata never recreates its capability.
enum RecoveryFixture {
    static func reopen(layout: ProvisioningPackageLayout, root: URL) async throws {
        let index = try ProvisioningJobJournal(directory: root.appendingPathComponent("journal"))
        let row = try index.load().first; index.close()
        guard let row else { throw ProvisioningJobFailure.unknownJob }
        let runtime = FakeRuntime()
        let profile = VMProfile(id: row.vmID, name: "Recovery fixture", clipboardEnabled: false)
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: root,
            hostMemoryMiB: 32768, logicalCPUs: 8)
        let launcher = try ProvisioningHelperLauncher(layout: layout, directory: root.appendingPathComponent("new-control"), policy: .adHocFixture)
        // Service and old fixture use the same named jobs directory.
        let state = root.appendingPathComponent("reopen-state")
        try PrivateFiles.directory(state, create: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("journal"), to: state.appendingPathComponent("jobs"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("workflows"), to: state.appendingPathComponent("workflows"))
        let service = try await ProvisioningService.open(manager: manager, directory: state,
            environment: .init(executionEnabled: true, engineDigest: row.engineDigest, dependencies: HomebrewProvisioningDependencies(),
                launcher: launcher, transportPolicy: .fixture(root.appendingPathComponent("admitted-tools")),
                admitPackage: { _ = try BundledProvisioning.inspect(layout) }))
        guard await service.status(row.jobID)?.cleanupRequired == true else { throw ProvisioningJobFailure.invalidRequest }
        let target = try GuestBinding(vmID: row.vmID, sessionID: row.sessionID, owner: "fixture", ownerUID: 1000,
            hostKeyDigest: KitVerifier.sha256(FixtureTransportProvider.hostKey))
        let adapter = DispatchFixtureGuest()
        do {
            _ = try await service.coordinator.recover(row.jobID, target: target, adapter: adapter)
            throw ProvisioningJobFailure.invalidRequest
        } catch ProvisioningJobFailure.ownershipUnverified {}
        do { try await manager.start(profile.id); throw ProvisioningJobFailure.invalidRequest }
        catch is VMFailure {}
        guard await adapter.calls == 0, runtime.startRequests.isEmpty else { throw ProvisioningJobFailure.invalidRequest }
        try await service.closeForReopen()
        print("{\"interrupted\":true,\"cleanupRequired\":true,\"ownershipRejected\":true,\"noReplay\":true,\"executionEnabled\":false}")
    }
}
#endif
