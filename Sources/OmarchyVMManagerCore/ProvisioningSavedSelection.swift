import DevVMProvisioningCore
import Foundation

extension ProvisioningService {
    /// Recover the saved plan, not its old consent/session/worker authority. Only
    /// manager-owned retained bytes with all three receipt hashes can be used.
    func restoreSavedSelection(_ id: UUID) async throws {
        try reviewAvailable()
        let targets = await manager.snapshots().filter { $0.profile.developerSetup?.reviewID == id }
        guard targets.count == 1, let receipt = targets.first?.profile.developerSetup else { throw ProvisioningReviewFailure.unavailable }
        try receipt.validate(vmID: targets[0].id)
        guard receipt.engineDigest == environment.engineDigest else { throw ProvisioningReviewFailure.changed }
        try PrivateFiles.directory(sourceDirectory)
        let trees = try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
        guard trees.count <= 128 else { throw ProvisioningReviewFailure.quota }
        for directory in trees.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let storage = try? ProvisioningPrivateInputTree(retained: directory, parent: sourceDirectory) else { continue }
            let manifests = try storage.manifestPaths().sorted {
                if $0 == $1 { return false }
                if $0 == Self.selectionManifest { return true }
                if $1 == Self.selectionManifest { return false }
                return $0 < $1
            }
            for manifest in manifests {
                guard let plan = try? SetupPlanner.plan(repository: directory, manifest: manifest),
                      plan.identity == receipt.planDigest, plan.snapshot.identity == receipt.inputDigest,
                      try ProvisioningCoordinator.engineIdentity(plan) == receipt.engineDigest else { continue }
                try storage.verifyRoot(); try plan.verify(in: directory)
                try ProvisioningTrim.admit(plan, factory: targets[0].profile.factory)
                guard case .object(let document) = plan.document,
                      case .array(let taskFields) = document["tasks"],
                      case .object(let requirements) = document["requirements"] else { throw ProvisioningReviewFailure.changed }
                let tasks = try taskFields.map { value -> ProvisioningTaskReview in
                    guard case .object(let fields) = value, case .string(let name) = fields["name"],
                          case .string(let file) = fields["file"], let input = plan.snapshot.receipts.first(where: { $0.path == file }) else { throw ProvisioningReviewFailure.changed }
                    return .init(name: name, file: file, sha256: input.sha256)
                }
                let preview = ProvisioningPlanPreview(id: id, vmID: receipt.vmID, sessionID: nil,
                    planDigest: receipt.planDigest, inputDigest: receipt.inputDigest, engineDigest: receipt.engineDigest,
                    proposal: try helperJSON(plan), tasks: tasks,
                    restartRequired: requirements["desktop_restart_required"] == .bool(true))
                try preview.validate(); try reviewAvailable(); try storage.verifyRoot(); try plan.verify(in: directory)
                drafts[id] = .init(selection: .init(directory: directory.path, manifest: manifest), preview: preview, storage: storage, plan: plan)
                return
            }
        }
        throw ProvisioningReviewFailure.changed
    }
}
