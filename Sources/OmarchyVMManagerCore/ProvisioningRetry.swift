import DevVMProvisioningCore
import Foundation

/// A guest's most recently accepted setup plan, or its creation plan when none
/// has run since, with that plan's run if it has one.
public struct ProvisioningLatestSetup: Equatable, Sendable {
    public let planID: UUID
    public let workflow: ProvisioningWorkflowSnapshot?
    public init(planID: UUID, workflow: ProvisioningWorkflowSnapshot?) { self.planID = planID; self.workflow = workflow }
}

/// A fresh plan, with a new ID, from the same frozen choices as a finished run.
/// It grants nothing: it goes through the normal apply review and consent.
public struct ProvisioningRetryPreview: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let preview: ProvisioningPlanPreview
    public let previousID: UUID
    /// The pinned dev-vm engine differs from the one the last run used.
    public let engineChanged: Bool
    /// The rebuilt plan differs from the last run's plan.
    public let planChanged: Bool
    /// Feature differences from the last run; nil when its features aren't recorded.
    public let addedFeatures: [String]?, removedFeatures: [String]?
    public init(preview: ProvisioningPlanPreview, previousID: UUID, engineChanged: Bool, planChanged: Bool, addedFeatures: [String]?, removedFeatures: [String]?) {
        self.preview = preview; self.previousID = previousID; self.engineChanged = engineChanged; self.planChanged = planChanged
        self.addedFeatures = addedFeatures; self.removedFeatures = removedFeatures
    }
    public var description: String { "ProvisioningRetryPreview(redacted)" }
    public var debugDescription: String { description }
}

/// Change setup's view of a guest's last run, and Run setup again (issue #14).
public protocol ProvisioningRetrying: ProvisioningReviewing {
    func latestSetup(vmID: UUID) async -> ProvisioningLatestSetup?
    func prepareRetry(id: UUID, of previousID: UUID) async throws -> ProvisioningRetryPreview
}

extension ProvisioningService: ProvisioningRetrying {
    public func latestSetup(vmID: UUID) async -> ProvisioningLatestSetup? {
        if let record = planHistory.latest(vmID: vmID) { return .init(planID: record.id, workflow: rows[record.id]?.snapshot) }
        // Legacy guests and creation plans that haven't run: the creation receipt.
        guard let receipt = await manager.snapshots().first(where: { $0.id == vmID })?.profile.developerSetup, receipt.vmID == vmID else { return nil }
        return .init(planID: receipt.reviewID, workflow: rows[receipt.reviewID]?.snapshot)
    }

    /// Rebuild a finished run's plan from its frozen private inputs with the current
    /// engine, under a new ID. Never rereads the live source folder.
    public func prepareRetry(id: UUID = UUID(), of previousID: UUID) async throws -> ProvisioningRetryPreview {
        try reviewAvailable()
        if let existing = retries[id] {
            guard existing.previousID == previousID, let draft = drafts[id] else { throw ProvisioningJobFailure.jobConflict }
            try draft.storage.verifyRoot(); try draft.plan.verify(in: draft.storage.directory)
            return existing // Lookup after a lost reply; never re-plan.
        }
        guard id != previousID, reviewCount < 16, creations[id] == nil, drafts[id] == nil, !draftCaptures.contains(id),
              status(id) == nil, planHistory.record(id) == nil else { throw ProvisioningReviewFailure.quota }
        guard let row = rows[previousID], row.snapshot.runFinished else { throw ProvisioningReviewFailure.unavailable }
        // A cleanup hold is resolved by recover or release first; a new run would be refused.
        guard !row.cleanupRequired else { throw ProvisioningServiceFailure.busy }
        draftCaptures.insert(id); defer { draftCaptures.remove(id) }
        let snapshots = await manager.snapshots()
        try reviewAvailable(); try environment.admitPackage()
        guard let target = snapshots.first(where: { $0.id == row.vmID }) else { throw ProvisioningReviewFailure.invalid }
        let frozen = try frozenInputs(planID: previousID, inputDigest: row.inputDigest, receipt: target.profile.developerSetup)
        guard try ProvisioningCoordinator.engineIdentity(frozen.plan) == environment.engineDigest else { throw ProvisioningReviewFailure.changed }
        try ProvisioningTrim.admit(frozen.plan, factory: target.profile.factory)
        let preview = try savedPreview(id: id, vmID: row.vmID, plan: frozen.plan)
        // Compare with the last run's plan: its record, or its workflow row.
        let record = planHistory.record(previousID), current = Self.featureNames(frozen.plan)
        let lastPlan = record?.planDigest ?? row.planDigest, lastEngine = record?.engineDigest ?? row.engineDigest
        let previous = record?.features ?? (lastPlan == frozen.plan.identity ? current : nil)
        let value = ProvisioningRetryPreview(preview: preview, previousID: previousID, engineChanged: lastEngine != environment.engineDigest,
            planChanged: lastPlan != frozen.plan.identity, addedFeatures: previous.map { old in current.filter { !old.contains($0) } },
            removedFeatures: previous.map { old in old.filter { !current.contains($0) } })
        try reviewAvailable(); try frozen.storage.verifyRoot(); try frozen.plan.verify(in: frozen.storage.directory)
        guard drafts[id] == nil, retries[id] == nil else { throw ProvisioningJobFailure.jobConflict }
        drafts[id] = .init(selection: .init(directory: frozen.storage.directory.path, manifest: frozen.manifest), preview: preview, storage: frozen.storage, plan: frozen.plan)
        retries[id] = value
        return value
    }

    /// Record where an accepted plan's frozen inputs live, before its run starts.
    func recordPlan(_ draft: ProvisioningDraft) throws {
        let tree = draft.storage.directory
        guard tree.deletingLastPathComponent().path == sourceDirectory.path else { throw ProvisioningReviewFailure.changed }
        try planHistory.append(.init(id: draft.preview.id, vmID: draft.preview.vmID, tree: tree.lastPathComponent, manifest: draft.plan.manifestPath,
            planDigest: draft.plan.identity, inputDigest: draft.plan.snapshot.identity, engineDigest: environment.engineDigest, features: Self.featureNames(draft.plan)))
    }

    /// Find a plan's retained private tree and re-plan it with the current engine.
    /// A recorded plan names its tree and manifest; a creation plan from before
    /// the record existed is found by its frozen input digest, which doesn't
    /// depend on the engine. The live source folder is never consulted.
    func frozenInputs(planID: UUID, inputDigest: String, receipt: ProvisioningSelectionReceipt?) throws -> (storage: ProvisioningPrivateInputTree, plan: SetupPlan, manifest: String) {
        try PrivateFiles.directory(sourceDirectory)
        let trees = try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
        guard trees.count <= 128 else { throw ProvisioningReviewFailure.quota }
        if let record = planHistory.record(planID) {
            guard record.inputDigest == inputDigest, let directory = trees.first(where: { $0.lastPathComponent == record.tree }) else { throw ProvisioningReviewFailure.changed }
            let storage = try ProvisioningPrivateInputTree(retained: directory, parent: sourceDirectory)
            guard let plan = try? SetupPlanner.plan(repository: directory, manifest: record.manifest), plan.snapshot.identity == inputDigest else { throw ProvisioningReviewFailure.changed }
            try storage.verifyRoot()
            return (storage, plan, record.manifest)
        }
        guard let receipt, receipt.reviewID == planID, receipt.inputDigest == inputDigest else { throw ProvisioningReviewFailure.unavailable }
        for directory in trees.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let storage = try? ProvisioningPrivateInputTree(retained: directory, parent: sourceDirectory) else { continue }
            for manifest in try Self.orderedManifests(storage) {
                guard let plan = try? SetupPlanner.plan(repository: directory, manifest: manifest), plan.snapshot.identity == inputDigest else { continue }
                try storage.verifyRoot()
                return (storage, plan, manifest)
            }
        }
        throw ProvisioningReviewFailure.changed
    }
    static func orderedManifests(_ storage: ProvisioningPrivateInputTree) throws -> [String] {
        try storage.manifestPaths().sorted {
            if $0 == $1 { return false }
            if $0 == selectionManifest { return true }
            if $1 == selectionManifest { return false }
            return $0 < $1
        }
    }
    /// The reviewed preview for a plan rebuilt from retained inputs.
    func savedPreview(id: UUID, vmID: UUID, plan: SetupPlan) throws -> ProvisioningPlanPreview {
        guard case .object(let document) = plan.document, case .array(let taskFields) = document["tasks"],
              case .object(let requirements) = document["requirements"] else { throw ProvisioningReviewFailure.changed }
        let tasks = try taskFields.map { value -> ProvisioningTaskReview in
            guard case .object(let fields) = value, case .string(let name) = fields["name"],
                  case .string(let file) = fields["file"], let input = plan.snapshot.receipts.first(where: { $0.path == file }) else { throw ProvisioningReviewFailure.changed }
            return .init(name: name, file: file, sha256: input.sha256)
        }
        let preview = ProvisioningPlanPreview(id: id, vmID: vmID, sessionID: nil, planDigest: plan.identity, inputDigest: plan.snapshot.identity,
            engineDigest: environment.engineDigest, proposal: try helperJSON(plan), tasks: tasks,
            restartRequired: requirements["desktop_restart_required"] == .bool(true) || requirements["system_restart_required"] == .bool(true))
        try preview.validate(); return preview
    }
    static func featureNames(_ plan: SetupPlan) -> [String] {
        guard case .object(let document) = plan.document, case .object(let features) = document["features"],
              case .array(let names) = features["features"] else { return [] }
        return names.compactMap { if case .string(let name) = $0 { name } else { nil } }
    }
}
