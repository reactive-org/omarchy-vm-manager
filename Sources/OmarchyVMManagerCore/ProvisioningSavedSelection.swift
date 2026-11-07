import DevVMProvisioningCore
import Foundation

extension ProvisioningService {
    /// Recover a saved plan, not its old consent/session/worker authority. Only
    /// manager-owned retained bytes matching the recorded hashes can be used: a
    /// plan recorded when its run was accepted, or the creation receipt's plan.
    func restoreSavedSelection(_ id: UUID) async throws {
        try reviewAvailable()
        if let record = planHistory.record(id) {
            let targets = await manager.snapshots().filter { $0.id == record.vmID }
            try reviewAvailable()
            guard targets.count == 1 else { throw ProvisioningReviewFailure.unavailable }
            guard record.engineDigest == environment.engineDigest else { throw ProvisioningReviewFailure.changed }
            let frozen = try frozenInputs(planID: id, inputDigest: record.inputDigest, receipt: nil)
            guard frozen.plan.identity == record.planDigest, try ProvisioningCoordinator.engineIdentity(frozen.plan) == record.engineDigest else { throw ProvisioningReviewFailure.changed }
            try store(id, vmID: record.vmID, frozen: frozen, factory: targets[0].profile.factory)
            return
        }
        let targets = await manager.snapshots().filter { $0.profile.developerSetup?.reviewID == id }
        guard targets.count == 1, let receipt = targets.first?.profile.developerSetup else { throw ProvisioningReviewFailure.unavailable }
        try receipt.validate(vmID: targets[0].id)
        guard receipt.engineDigest == environment.engineDigest else { throw ProvisioningReviewFailure.changed }
        try PrivateFiles.directory(sourceDirectory)
        let trees = try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
        guard trees.count <= 128 else { throw ProvisioningReviewFailure.quota }
        for directory in trees.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let storage = try? ProvisioningPrivateInputTree(retained: directory, parent: sourceDirectory) else { continue }
            for manifest in try Self.orderedManifests(storage) {
                guard let plan = try? SetupPlanner.plan(repository: directory, manifest: manifest),
                      plan.identity == receipt.planDigest, plan.snapshot.identity == receipt.inputDigest,
                      try ProvisioningCoordinator.engineIdentity(plan) == receipt.engineDigest else { continue }
                try store(id, vmID: receipt.vmID, frozen: (storage, plan, manifest), factory: targets[0].profile.factory)
                return
            }
        }
        throw ProvisioningReviewFailure.changed
    }
    private func store(_ id: UUID, vmID: UUID, frozen: (storage: ProvisioningPrivateInputTree, plan: SetupPlan, manifest: String), factory: FactoryIdentity?) throws {
        try frozen.storage.verifyRoot(); try frozen.plan.verify(in: frozen.storage.directory)
        try ProvisioningTrim.admit(frozen.plan, factory: factory)
        let preview = try savedPreview(id: id, vmID: vmID, plan: frozen.plan)
        try reviewAvailable(); try frozen.storage.verifyRoot(); try frozen.plan.verify(in: frozen.storage.directory)
        drafts[id] = .init(selection: .init(directory: frozen.storage.directory.path, manifest: frozen.manifest), preview: preview, storage: frozen.storage, plan: frozen.plan)
    }
}
