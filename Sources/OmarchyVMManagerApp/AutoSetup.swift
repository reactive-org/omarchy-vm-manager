import OmarchyVMManagerCore
import SwiftUI

/// The exact plan a person approved for one run: Create, launch & set up for a new
/// guest's first run, or the main button in Change setup. The frozen review still
/// runs; the approval stands in for the separate approve, restart and check clicks.
struct ApprovedSetupPlan: Equatable {
    enum Origin: Equatable { case creation, change }
    let previewID: UUID
    let vmID: UUID
    let planDigest: String
    let inputDigest: String
    let origin: Origin
    /// Change setup asks for Docker without sudo separately; creation never carries it.
    let dockerAcknowledged: Bool

    init(receipt: ProvisioningSelectionReceipt) {
        previewID = receipt.reviewID; vmID = receipt.vmID; planDigest = receipt.planDigest; inputDigest = receipt.inputDigest
        origin = .creation; dockerAcknowledged = false
    }
    init(preview: ProvisioningPlanPreview, dockerAcknowledged: Bool) {
        previewID = preview.id; vmID = preview.vmID; planDigest = preview.planDigest; inputDigest = preview.inputDigest
        origin = .change; self.dockerAcknowledged = dockerAcknowledged
    }
    /// A run already applied, finished from Change setup: bound to the plan its
    /// own restart review names.
    init(finishing review: ProvisioningWorkflowActionReview) {
        previewID = review.workflowID; vmID = review.vmID; planDigest = review.planDigest; inputDigest = review.inputDigest
        origin = .change; dockerAcknowledged = false
    }
}

/// A one-time approval for one setup run. It lives in this manager's memory, binds
/// to one guest session, and the apply is a single attempt. The review must need
/// nothing beyond what was approved: temporary admin access, plus Docker without
/// sudo when Change setup asked for it; custom-task trust always stops for review.
/// After apply it follows that one workflow through the restart and configuration
/// check that finish setup (user direction, 7 November 2026; extended to Change
/// setup, 9 November 2026): each is prepared, bound to the approved plan and
/// inputs, and submitted once; recovery is never automatic. Any mismatch blocks
/// with a reason and leaves the manual review in place.
enum AutoSetupState: Equatable {
    case armed(plan: ApprovedSetupPlan, sessionID: UUID?)
    case applying
    case consumed
    /// Apply was submitted; finishing actions already attempted for this workflow.
    case following(plan: ApprovedSetupPlan, workflowID: UUID, attempted: Set<ProvisioningWorkflowAction>)
    case blocked(String)

    var blockedReason: String? { if case .blocked(let reason) = self { reason } else { nil } }
    var isActive: Bool {
        switch self {
        case .armed, .applying, .following: true
        case .consumed, .blocked: false
        }
    }
    /// The approved plan while one is armed or being followed.
    var plan: ApprovedSetupPlan? {
        switch self {
        case .armed(let plan, _), .following(let plan, _, _): plan
        default: nil
        }
    }
}

extension SetupAutoApproval {
    /// What the shared Core attention state needs from the in-memory approval.
    init(_ state: AutoSetupState?) {
        guard let state else { self.init(); return }
        let finishing: Bool = { if case .following = state { return true }; return false }()
        self.init(approved: state.blockedReason == nil, finishing: finishing, blocked: state.blockedReason != nil)
    }
}

extension AppModel {
    /// Called only from the Create, Launch & Set Up path for a just-created guest.
    func armAutoSetup(_ vmID: UUID) {
        guard let profile = snapshots.first(where: { $0.id == vmID })?.profile, profile.ssh != nil,
              let receipt = profile.developerSetup, receipt.vmID == vmID, autoSetup[vmID] == nil else { return }
        autoSetup[vmID] = .armed(plan: .init(receipt: receipt), sessionID: nil)
    }

    /// Change setup's main button: run this plan once, with its restart and check.
    /// A running guest binds to its current session; Start & set up binds to the
    /// first session seen after launch. Replaces any earlier approval for the guest.
    func approveSetup(_ plan: ApprovedSetupPlan) {
        guard plan.origin == .change, let snapshot = snapshots.first(where: { $0.id == plan.vmID }), snapshot.profile.ssh != nil,
              autoSetup[plan.vmID]?.isActive != true || autoSetup[plan.vmID]?.plan?.previewID == plan.previewID else { return }
        autoSetup[plan.vmID] = .armed(plan: plan, sessionID: snapshot.sessionID)
        advanceAutoSetup()
    }

    /// Change setup approved a pending run itself (for example after inspecting custom
    /// tasks): follow it through its restart and check.
    func followApprovedSetup(_ plan: ApprovedSetupPlan, workflowID: UUID) {
        guard plan.origin == .change, plan.previewID == workflowID else { return }
        autoSetup[plan.vmID] = .following(plan: plan, workflowID: workflowID, attempted: [])
        advanceAutoSetup()
    }

    /// Change setup's Restart & check, or Run the check, for a run nobody is
    /// following (approved before this manager started, or blocked): one click
    /// performs the reviewed action, then the check follows as part of the same
    /// approval. Returns a reason when nothing was done.
    func finishSetup(_ workflow: ProvisioningWorkflowSnapshot) async -> String? {
        guard let service = setupService as? any ProvisioningWorkflowActing else { return "Setup coordination is unavailable." }
        let action: ProvisioningWorkflowAction = workflow.availableActions.contains(.restart) ? .restart : .check
        guard workflow.availableActions.contains(action) else { return "This run has nothing left to finish." }
        do {
            let review = try await service.prepareAction(workflow.id, action: action, reviewID: UUID())
            guard review.workflowID == workflow.id, review.vmID == workflow.vmID, review.action == action else { return "The prepared step doesn’t match this run. Nothing was changed." }
            if action == .restart { autoSetup[workflow.vmID] = .following(plan: .init(finishing: review), workflowID: workflow.id, attempted: [.restart]) }
            _ = try await service.performAction(workflow.id, consent: .init(reviewID: review.id, action: action, reviewIdentity: review.reviewIdentity, acknowledged: true))
            return nil
        } catch {
            if action == .restart, case .following(_, let id, _)? = autoSetup[workflow.vmID], id == workflow.id { autoSetup[workflow.vmID] = nil }
            return (action == .restart ? "The restart" : "The check") + " couldn’t start. Check the guest’s current state; it wasn’t retried automatically."
        }
    }

    /// Runs after each refresh. State leaves `.armed` synchronously before any
    /// await, so an overlapping refresh can never start a second attempt.
    func advanceAutoSetup() {
        for (vmID, state) in autoSetup {
            if case .following(let plan, let workflowID, let attempted) = state {
                followAutoSetup(vmID: vmID, plan: plan, workflowID: workflowID, attempted: attempted)
                continue
            }
            guard case .armed(let plan, let bound) = state else { continue }
            guard let snapshot = snapshots.first(where: { $0.id == vmID }) else {
                autoSetup[vmID] = .blocked("This guest is no longer available.")
                continue
            }
            if plan.origin == .creation {
                guard let receipt = snapshot.profile.developerSetup, ApprovedSetupPlan(receipt: receipt) == plan else {
                    autoSetup[vmID] = .blocked("This guest’s saved setup changed. Review it in Change setup.")
                    continue
                }
            }
            guard let session = snapshot.sessionID else {
                if bound != nil { autoSetup[vmID] = .blocked("The guest stopped before setup began. Start it, then review setup to continue.") }
                continue
            }
            guard let bound else { autoSetup[vmID] = .armed(plan: plan, sessionID: session); continue }
            guard bound == session else {
                autoSetup[vmID] = .blocked("The guest restarted before setup began. Review setup to continue.")
                continue
            }
            // Earlier finished runs don't matter; another run in progress, or a cleanup hold, does.
            let busy = setupWorkflows.contains { $0.vmID == vmID && $0.id != plan.previewID && ($0.stage.inProgress || $0.cleanupRequired) }
            guard case .ready = snapshot.sshReadiness, !busy else { continue }
            guard let service = setupService as? any ProvisioningReviewing else {
                autoSetup[vmID] = .blocked("Setup coordination is unavailable. Review it in Change setup.")
                continue
            }
            autoSetup[vmID] = .applying
            Task { await self.applyAutoSetup(vmID: vmID, plan: plan, session: session, service: service) }
        }
    }

    private func applyAutoSetup(vmID: UUID, plan: ApprovedSetupPlan, session: UUID, service: any ProvisioningReviewing) async {
        let review: ProvisioningApplyReview
        do { review = try await service.prepareApply(plan.previewID) }
        catch { autoSetup[vmID] = .blocked("Setup could not be prepared automatically. Review it in Change setup."); return }
        guard review.vmID == vmID, review.sessionID == session, review.previewID == plan.previewID,
              review.planDigest == plan.planDigest, review.inputDigest == plan.inputDigest else {
            autoSetup[vmID] = .blocked("The prepared setup doesn’t match what you approved. Review it in Change setup.")
            return
        }
        if review.dockerRootAccessRequired && !plan.dockerAcknowledged {
            autoSetup[vmID] = .blocked("This setup also needs Docker access without sudo. Review it in Change setup.")
            return
        }
        if review.taskTrustIdentity != nil {
            autoSetup[vmID] = .blocked("This setup includes custom tasks to inspect. Review them in Change setup.")
            return
        }
        // Exactly the disclosed permissions: temporary admin access, and Docker only when asked for.
        let consent = ProvisioningApplyConsent(reviewIdentity: review.reviewIdentity, persistentGrantAcknowledged: review.persistentGrantRequired,
                                               dockerRootAccessAcknowledged: review.dockerRootAccessRequired && plan.dockerAcknowledged)
        autoSetup[vmID] = .consumed
        do {
            let workflow = try await service.apply(plan.previewID, consent: consent)
            if autoSetup[vmID] == .consumed { autoSetup[vmID] = .following(plan: plan, workflowID: workflow.id, attempted: []) }
        }
        catch {
            // Block unless the run started anyway (its row has an apply job).
            if setupWorkflows.first(where: { $0.id == plan.previewID })?.applyJobID == nil {
                autoSetup[vmID] = .blocked("Setup could not start automatically and was not retried. Review it in Change setup.")
            }
        }
    }

    /// One finishing action per stage, once: restart when restart is required, the
    /// check once the replacement session is ready. Ends on any other outcome.
    private func followAutoSetup(vmID: UUID, plan: ApprovedSetupPlan, workflowID: UUID, attempted: Set<ProvisioningWorkflowAction>) {
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
        case .waitingForRebind:
            // Preparing the check is what re-binds to the restarted session, so start it
            // here, once that session is the workflow's new one and its SSH is ready.
            guard let snapshot = snapshots.first(where: { $0.id == vmID }), let session = row.newSessionID,
                  snapshot.sessionID == session, case .ready = snapshot.sshReadiness else { return }
            action = .check
        default: return
        }
        guard row.availableActions.contains(action), !attempted.contains(action) else { return }
        guard let service = setupService as? any ProvisioningWorkflowActing else {
            autoSetup[vmID] = .blocked("Setup coordination is unavailable. Review the restart in Change setup.")
            return
        }
        autoSetup[vmID] = .following(plan: plan, workflowID: workflowID, attempted: attempted.union([action]))
        Task { await self.performAutoAction(action, vmID: vmID, plan: plan, workflowID: workflowID, service: service) }
    }

    private func performAutoAction(_ action: ProvisioningWorkflowAction, vmID: UUID, plan: ApprovedSetupPlan, workflowID: UUID,
                                   service: any ProvisioningWorkflowActing) async {
        let what = action == .restart ? "restart" : "configuration check"
        do {
            let review = try await service.prepareAction(workflowID, action: action, reviewID: UUID())
            guard review.workflowID == workflowID, review.vmID == vmID, review.action == action,
                  review.planDigest == plan.planDigest, review.inputDigest == plan.inputDigest else {
                autoSetup[vmID] = .blocked("The prepared \(what) doesn’t match the setup you approved. Review it in Change setup.")
                return
            }
            _ = try await service.performAction(workflowID, consent: .init(reviewID: review.id, action: action, reviewIdentity: review.reviewIdentity, acknowledged: true))
        } catch {
            let stages: [ProvisioningWorkflowStage] = action == .restart ? [.restartRequired] : [.waitingForRebind, .readyForCheck]
            if let stage = setupWorkflows.first(where: { $0.id == workflowID })?.stage, stages.contains(stage) {
                autoSetup[vmID] = .blocked("The \(what) couldn’t start automatically and was not retried. Review it in Change setup.")
            }
        }
    }
}
