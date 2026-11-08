import DevVMProvisioningCore
import Foundation

/// Run the check only (user direction, 9 November 2026): a run whose apply finished
/// and whose guest restarted, but which stopped before its configuration check
/// (usually because the manager quit), can finish with just that check instead of a
/// full rerun. The check is a new workflow built from that run's own frozen inputs,
/// in Ansible check mode, without custom tasks and without any admin grant: the
/// helper channel refuses every grant or apply operation in check mode. It is never
/// a general check of an arbitrary guest.
public protocol ProvisioningCheckRunning: ProvisioningRetrying {
    /// Whether this finished run can be finished with a check alone.
    func checkOnlyAvailable(_ previousID: UUID) async -> Bool
    /// Prepare and run the check in one step; the click is the owner's consent.
    func runCheckOnly(id: UUID, of previousID: UUID) async throws -> ProvisioningWorkflowSnapshot
}

extension ProvisioningService: ProvisioningCheckRunning {
    public func checkOnlyAvailable(_ previousID: UUID) -> Bool {
        guard executionEnabled, let row = rows[previousID] else { return false }
        return Self.checkOnlyEligible(row.snapshot)
    }
    /// An interrupted run that applied (it has an apply job) and restarted (a restart
    /// is only approved from a clean restart-required apply), with no cleanup hold.
    static func checkOnlyEligible(_ row: ProvisioningWorkflowSnapshot) -> Bool {
        row.stage == .interrupted && row.failure == .processInterrupted && row.applyJobID != nil && row.restartID != nil && !row.cleanupRequired
    }

    public func runCheckOnly(id: UUID = UUID(), of previousID: UUID) async throws -> ProvisioningWorkflowSnapshot {
        try enabled()
        // A lost reply observes the check it started; it never starts another.
        if let row = rows[id] {
            guard row.vmID == rows[previousID]?.vmID else { throw ProvisioningJobFailure.jobConflict }
            return row.snapshot
        }
        guard id != previousID, let previous = rows[previousID], Self.checkOnlyEligible(previous.snapshot), reviewCount < 16,
              drafts[id] == nil, creations[id] == nil, !draftCaptures.contains(id), planHistory.record(id) == nil else { throw ProvisioningReviewFailure.unavailable }
        draftCaptures.insert(id); defer { draftCaptures.remove(id) }
        let snapshots = await manager.snapshots()
        try enabled(); try environment.admitPackage()
        guard let target = snapshots.first(where: { $0.id == previous.vmID }), let sessionID = target.sessionID,
              let resolve = environment.resolveTarget else { throw ProvisioningReviewFailure.unavailable }
        let frozen = try frozenInputs(planID: previousID, inputDigest: previous.inputDigest, receipt: target.profile.developerSetup)
        // Check exactly the plan that ran. After an engine update the same choices make a
        // different plan, which needs a full run instead.
        guard frozen.plan.identity == previous.planDigest, frozen.plan.snapshot.identity == previous.inputDigest,
              try ProvisioningCoordinator.engineIdentity(frozen.plan) == environment.engineDigest else { throw ProvisioningReviewFailure.changed }
        try ProvisioningTrim.admit(frozen.plan, factory: target.profile.factory)
        let preview = try savedPreview(id: id, vmID: previous.vmID, plan: frozen.plan)
        let draft = ProvisioningDraft(selection: .init(directory: frozen.storage.directory.path, manifest: frozen.manifest), preview: preview,
                                      storage: frozen.storage, plan: frozen.plan)
        let binding = try await resolve(target.id, sessionID)
        try enabled()
        guard binding.vmID == target.id, binding.sessionID == sessionID else { throw ProvisioningReviewFailure.changed }
        _ = try await manager.provisioningSSHAdmission(binding)
        try frozen.storage.verifyRoot(); try frozen.plan.verify(in: frozen.storage.directory)
        guard drafts[id] == nil, rows[id] == nil else { throw ProvisioningJobFailure.jobConflict }
        drafts[id] = draft
        _ = try await prepare(id: id, plan: frozen.plan, repository: frozen.storage.directory, target: binding, mode: .check)
        do {
            let prepared = try await prepared(id)
            guard prepared.request.mode == .check, prepared.request.selectedTasks.isEmpty else { throw ProvisioningReviewFailure.invalid }
            try enabled(); try frozen.storage.verifyRoot(); try frozen.plan.verify(in: frozen.storage.directory)
            // The check becomes the guest's latest plan, so Run setup again repeats these choices.
            if rows[id]?.applyJobID == nil { try recordPlan(draft) }
            return try await approve(id, approval: .init(reviewIdentity: prepared.request.reviewIdentity))
        } catch {
            // Never leave a check waiting for an approval nobody will give.
            if rows[id]?.applyJobID == nil, rows[id]?.stage.inProgress == true { try? await cancel(id) }
            throw error
        }
    }
}
