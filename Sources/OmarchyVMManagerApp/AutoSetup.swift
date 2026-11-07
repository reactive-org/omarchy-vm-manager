import OmarchyVMManagerCore
import SwiftUI

/// A one-time approval given by Create, launch & set up for a new guest's first
/// run. The frozen review still runs; the approval only replaces the Setup-tab
/// clicks when the review needs nothing beyond temporary admin access. It lives in
/// this manager's memory, binds to the first session seen after launch, and the
/// apply is a single attempt. After apply it follows that one workflow through the
/// restart and configuration check that finish setup (user direction, 7 November
/// 2026): each is prepared, bound to the approved plan and inputs, and submitted
/// once; recovery is never automatic. Any mismatch blocks with a reason and leaves
/// the manual review in place.
enum AutoSetupState: Equatable {
    case armed(receipt: ProvisioningSelectionReceipt, sessionID: UUID?)
    case applying
    case consumed
    /// Apply was submitted; finishing actions already attempted for this workflow.
    case following(receipt: ProvisioningSelectionReceipt, workflowID: UUID, attempted: Set<ProvisioningWorkflowAction>)
    case blocked(String)

    var blockedReason: String? { if case .blocked(let reason) = self { reason } else { nil } }
    var isActive: Bool {
        switch self {
        case .armed, .applying, .following: true
        case .consumed, .blocked: false
        }
    }
}

extension AppModel {
    /// Called only from the Create, Launch & Set Up path for a just-created guest.
    func armAutoSetup(_ vmID: UUID) {
        guard let profile = snapshots.first(where: { $0.id == vmID })?.profile, profile.ssh != nil,
              let receipt = profile.developerSetup, receipt.vmID == vmID, autoSetup[vmID] == nil else { return }
        autoSetup[vmID] = .armed(receipt: receipt, sessionID: nil)
    }

    /// Runs after each refresh. State leaves `.armed` synchronously before any
    /// await, so an overlapping refresh can never start a second attempt.
    func advanceAutoSetup() {
        for (vmID, state) in autoSetup {
            if case .following(let receipt, let workflowID, let attempted) = state {
                followAutoSetup(vmID: vmID, receipt: receipt, workflowID: workflowID, attempted: attempted)
                continue
            }
            guard case .armed(let receipt, let bound) = state else { continue }
            guard let snapshot = snapshots.first(where: { $0.id == vmID }), snapshot.profile.developerSetup == receipt else {
                autoSetup[vmID] = .blocked("This guest’s saved setup changed. Review it on the Setup tab.")
                continue
            }
            guard let session = snapshot.sessionID else {
                if bound != nil { autoSetup[vmID] = .blocked("The guest stopped before setup began. Launch it, then review setup to continue.") }
                continue
            }
            guard let bound else { autoSetup[vmID] = .armed(receipt: receipt, sessionID: session); continue }
            guard bound == session else {
                autoSetup[vmID] = .blocked("The guest restarted before setup began. Review setup to continue.")
                continue
            }
            guard case .ready = snapshot.sshReadiness, !setupWorkflows.contains(where: { $0.vmID == vmID }) else { continue }
            guard let service = setupService as? any ProvisioningReviewing else {
                autoSetup[vmID] = .blocked("Setup coordination is unavailable. Review setup on the Setup tab.")
                continue
            }
            autoSetup[vmID] = .applying
            Task { await self.applyAutoSetup(vmID: vmID, receipt: receipt, session: session, service: service) }
        }
    }

    private func applyAutoSetup(vmID: UUID, receipt: ProvisioningSelectionReceipt, session: UUID, service: any ProvisioningReviewing) async {
        let review: ProvisioningApplyReview
        do { review = try await service.prepareApply(receipt.reviewID) }
        catch { autoSetup[vmID] = .blocked("Setup could not be prepared automatically. Review it on the Setup tab."); return }
        guard review.vmID == vmID, review.sessionID == session, review.previewID == receipt.reviewID,
              review.planDigest == receipt.planDigest, review.inputDigest == receipt.inputDigest else {
            autoSetup[vmID] = .blocked("The prepared setup doesn’t match what you approved. Review it on the Setup tab.")
            return
        }
        if review.dockerRootAccessRequired {
            autoSetup[vmID] = .blocked("This setup also needs Docker access without sudo. Review it on the Setup tab.")
            return
        }
        if review.taskTrustIdentity != nil {
            autoSetup[vmID] = .blocked("This setup includes custom tasks to inspect. Review them on the Setup tab.")
            return
        }
        // Exactly the disclosed permission: temporary admin access. No Docker or task trust.
        let consent = ProvisioningApplyConsent(reviewIdentity: review.reviewIdentity, persistentGrantAcknowledged: review.persistentGrantRequired)
        autoSetup[vmID] = .consumed
        do {
            let workflow = try await service.apply(receipt.reviewID, consent: consent)
            if autoSetup[vmID] == .consumed { autoSetup[vmID] = .following(receipt: receipt, workflowID: workflow.id, attempted: []) }
        }
        catch {
            if !setupWorkflows.contains(where: { $0.vmID == vmID && $0.stage != .readyForReview }) {
                autoSetup[vmID] = .blocked("Setup could not start automatically and was not retried. Review it on the Setup tab.")
            }
        }
    }

    /// One finishing action per stage, once: restart when restart is required, the
    /// check once the replacement session is ready. Ends on any other outcome.
    private func followAutoSetup(vmID: UUID, receipt: ProvisioningSelectionReceipt, workflowID: UUID, attempted: Set<ProvisioningWorkflowAction>) {
        guard let row = setupWorkflows.first(where: { $0.id == workflowID }) else { return }
        // A live run is marked cleanup-required until its admin access is removed, so
        // only an ended stage stops following; recovery is never automatic.
        if [.succeeded, .checked, .failed, .cancelled, .interrupted, .cleanupRequired].contains(row.stage) {
            autoSetup[vmID] = .consumed; return
        }
        let action: ProvisioningWorkflowAction
        switch row.stage {
        case .restartRequired: action = .restart
        case .readyForCheck: action = .check
        default: return
        }
        guard row.availableActions.contains(action), !attempted.contains(action) else { return }
        guard let service = setupService as? any ProvisioningWorkflowActing else {
            autoSetup[vmID] = .blocked("Setup coordination is unavailable. Review the restart on the Setup tab.")
            return
        }
        autoSetup[vmID] = .following(receipt: receipt, workflowID: workflowID, attempted: attempted.union([action]))
        Task { await self.performAutoAction(action, vmID: vmID, receipt: receipt, workflowID: workflowID, service: service) }
    }

    private func performAutoAction(_ action: ProvisioningWorkflowAction, vmID: UUID, receipt: ProvisioningSelectionReceipt, workflowID: UUID,
                                   service: any ProvisioningWorkflowActing) async {
        let what = action == .restart ? "restart" : "configuration check"
        do {
            let review = try await service.prepareAction(workflowID, action: action, reviewID: UUID())
            guard review.workflowID == workflowID, review.vmID == vmID, review.action == action,
                  review.planDigest == receipt.planDigest, review.inputDigest == receipt.inputDigest else {
                autoSetup[vmID] = .blocked("The prepared \(what) doesn’t match the setup you approved. Review it on the Setup tab.")
                return
            }
            _ = try await service.performAction(workflowID, consent: .init(reviewID: review.id, action: action, reviewIdentity: review.reviewIdentity, acknowledged: true))
        } catch {
            let stage: ProvisioningWorkflowStage = action == .restart ? .restartRequired : .readyForCheck
            if setupWorkflows.first(where: { $0.id == workflowID })?.stage == stage {
                autoSetup[vmID] = .blocked("The \(what) couldn’t start automatically and was not retried. Review it on the Setup tab.")
            }
        }
    }
}
