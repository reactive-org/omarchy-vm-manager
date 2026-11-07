import DevVMProvisioningCore
import Foundation

extension ProvisioningService: ProvisioningWorkflowActing {
    public func prepareAction(_ workflowID: UUID, action: ProvisioningWorkflowAction, reviewID: UUID) async throws -> ProvisioningWorkflowActionReview {
        try enabled()
        if let prior = actionPreparations[reviewID] {
            guard prior.workflowID == workflowID, prior.action == action else { throw ProvisioningJobFailure.jobConflict }
            return try await prior.task.value
        }
        guard actionPreparations.count < 128, !actionWorkflowsInFlight.contains(workflowID) else { throw ProvisioningReviewFailure.quota }
        actionWorkflowsInFlight.insert(workflowID); defer { actionWorkflowsInFlight.remove(workflowID) }
        let task = Task { try await self.prepareWorkflowAction(workflowID, action: action, reviewID: reviewID) }
        actionPreparations[reviewID] = .init(workflowID: workflowID, action: action, task: task)
        return try await task.value
    }
    private func prepareWorkflowAction(_ id: UUID, action: ProvisioningWorkflowAction, reviewID: UUID) async throws -> ProvisioningWorkflowActionReview {
        try enabled(); try environment.admitPackage()
        guard let row = rows[id], row.snapshot.availableActions.contains(action) else { throw ProvisioningServiceFailure.reviewRequired }
        let detail: ProvisioningActionContext.Detail
        let jobID: UUID, sessionID: UUID, dependencyDigest: String, scope: String
        switch action {
        case .restart:
            guard let prepared = original[id] else { throw ProvisioningReviewFailure.unavailable }
            let review = try restartReview(id)
            try await manager.validateProvisioningTransport(prepared.transport)
            detail = .restart(review, prepared.transport); jobID = prepared.request.jobID
            sessionID = prepared.request.target.sessionID; dependencyDigest = prepared.request.dependencyDigest; scope = try review.identity
        case .check:
            guard let session = row.newSessionID else { throw ProvisioningServiceFailure.reviewRequired }
            let binding = try await resolveActionTarget(vmID: row.vmID, sessionID: session)
            let prepared = try await prepareRebind(id, target: binding)
            let review = try rebindReview(id)
            detail = .check(review, prepared); jobID = prepared.request.jobID
            sessionID = session; dependencyDigest = prepared.request.dependencyDigest; scope = try review.identity
        case .recover:
            guard environment.makeRecoveryAdapter != nil else { throw ProvisioningReviewFailure.unavailable }
            let record = try await cleanupRecord(id)
            let binding = try await resolveActionTarget(vmID: record.vmID, sessionID: record.sessionID)
            guard try ProvisioningCoordinator.bindingIdentity(binding) == record.bindingDigest else { throw ProvisioningReviewFailure.changed }
            let report = try await environment.dependencies.inspect()
            try enabled()
            let admission = try await manager.admitProvisioningTransport(target: binding, report: report, policy: environment.transportPolicy)
            guard admission.dependencyDigest == record.dependencyDigest, record == (try await cleanupRecord(id)) else { throw ProvisioningReviewFailure.changed }
            detail = .recover(record, admission); jobID = record.jobID; sessionID = record.sessionID
            dependencyDigest = record.dependencyDigest; scope = KitVerifier.sha256(try helperJSON(record))
        case .release:
            // Stopped guests only; the review binds the exact cleanup-bound jobs and rows.
            try await manager.requireProvisioningHoldReleasable(row.vmID)
            let held = try jobs.load().filter { $0.vmID == row.vmID && $0.cleanupRequired }.sorted { $0.jobID.uuidString < $1.jobID.uuidString }
            let heldRows = rows.values.filter { $0.vmID == row.vmID && $0.cleanupRequired }.map { $0.id.uuidString + ":" + String($0.sequence) }.sorted()
            detail = .release(vmID: row.vmID); jobID = row.checkJobID ?? row.applyJobID ?? row.id; sessionID = row.originalSessionID
            dependencyDigest = held.first?.dependencyDigest ?? row.engineDigest
            scope = KitVerifier.sha256(try helperJSON(held.map { $0.jobID.uuidString + ":" + String($0.sequence) } + heldRows))
        }
        try enabled(); try environment.admitPackage()
        guard let current = rows[id], current.snapshot.availableActions.contains(action),
              current.vmID == row.vmID, current.planDigest == row.planDigest, current.inputDigest == row.inputDigest,
              action == .check || current.sequence == row.sequence else { throw ProvisioningReviewFailure.changed }
        let identity = KitVerifier.sha256(try helperJSON(["workflow-action-v1", reviewID.uuidString, id.uuidString, action.rawValue,
            current.vmID.uuidString, sessionID.uuidString, jobID.uuidString, String(current.sequence), current.planDigest, current.inputDigest, dependencyDigest, scope]))
        let review = ProvisioningWorkflowActionReview(id: reviewID, workflowID: id, vmID: current.vmID, sessionID: sessionID, jobID: jobID,
            action: action, workflowSequence: current.sequence, planDigest: current.planDigest, inputDigest: current.inputDigest,
            dependencyDigest: dependencyDigest, reviewIdentity: identity)
        try review.validate(); actionContexts[reviewID] = .init(review: review, detail: detail); return review
    }
    private func resolveActionTarget(vmID: UUID, sessionID: UUID) async throws -> GuestBinding {
        guard let resolve = environment.resolveTarget,
              await manager.snapshots().contains(where: { $0.id == vmID && $0.sessionID == sessionID }) else { throw ProvisioningReviewFailure.unavailable }
        let binding = try await resolve(vmID, sessionID)
        try enabled()
        guard binding.vmID == vmID, binding.sessionID == sessionID else { throw ProvisioningReviewFailure.changed }
        _ = try await manager.provisioningSSHAdmission(binding)
        return binding
    }
    private func cleanupRecord(_ id: UUID) async throws -> ProvisioningJobRecord {
        guard let row = rows[id], row.cleanupRequired else { throw ProvisioningServiceFailure.reviewRequired }
        let records = try jobs.load()
        for child in [row.checkJobID, row.applyJobID].compactMap({ $0 }) {
            if let record = records.first(where: { $0.jobID == child }), record.cleanupRequired,
               await coordinator.status(child)?.cleanupRequired == true { return record }
        }
        throw ProvisioningReviewFailure.unavailable // An unproved exit cannot be cleared by UI state.
    }
    public func performAction(_ id: UUID, consent: ProvisioningWorkflowActionConsent) async throws -> ProvisioningWorkflowSnapshot {
        try enabled(); try consent.validate()
        guard let context = actionContexts[consent.reviewID], context.review.workflowID == id,
              context.review.action == consent.action, context.review.reviewIdentity == consent.reviewIdentity, consent.acknowledged else { throw ProvisioningReviewFailure.consentRequired }
        if let (previous, task) = actionSubmissions[consent.reviewID] {
            guard previous == consent else { throw ProvisioningReviewFailure.conflictingConsent }; return try await task.value
        }
        guard !actionWorkflowsInFlight.contains(id) else { throw ProvisioningServiceFailure.busy }
        actionWorkflowsInFlight.insert(id); defer { actionWorkflowsInFlight.remove(id) }
        let task = Task { try await self.submitWorkflowAction(context) }
        actionSubmissions[consent.reviewID] = (consent, task)
        return try await task.value
    }
    private func submitWorkflowAction(_ context: ProvisioningActionContext) async throws -> ProvisioningWorkflowSnapshot {
        try enabled(); try environment.admitPackage()
        let review = context.review, id = review.workflowID
        try validateActionState(review)
        switch context.detail {
        case .restart(let original, let admission):
            try await manager.validateProvisioningTransport(admission)
            try enabled(); try validateActionState(review)
            return try await approveRestart(original, identity: original.identity)
        case .check(let original, let prepared):
            try await manager.validateProvisioningTransport(prepared.transport)
            let report = try await environment.dependencies.inspect()
            try enabled(); try validateActionState(review)
            let fresh = try await manager.admitProvisioningTransport(target: prepared.request.target, report: report, policy: environment.transportPolicy)
            try await manager.validateProvisioningTransport(prepared.transport)
            guard fresh.dependencyDigest == review.dependencyDigest else { throw ProvisioningReviewFailure.changed }
            try enabled(); try validateActionState(review); try environment.admitPackage()
            return try await approveRebind(original, identity: original.identity)
        case .recover(let record, let admission):
            guard let make = environment.makeRecoveryAdapter, record == (try await cleanupRecord(id)) else { throw ProvisioningReviewFailure.changed }
            try await manager.validateProvisioningTransport(admission)
            let report = try await environment.dependencies.inspect()
            try enabled(); try validateActionState(review)
            let fresh = try await manager.admitProvisioningTransport(target: admission.target, report: report, policy: environment.transportPolicy)
            try await manager.validateProvisioningTransport(admission)
            guard fresh.dependencyDigest == review.dependencyDigest, record == (try await cleanupRecord(id)) else { throw ProvisioningReviewFailure.changed }
            try enabled(); try validateActionState(review); try environment.admitPackage()
            let deferred = ProvisioningDeferredCleanupAdapter(jobID: record.jobID, target: admission.target, dependencyDigest: admission.dependencyDigest, make: { try make(admission) })
            return try await recover(id, admission: admission, adapter: deferred)
        case .release(let vmID):
            guard rows[id]?.vmID == vmID else { throw ProvisioningReviewFailure.changed }
            return try await releaseCleanupHold(id)
        }
    }
    private func validateActionState(_ review: ProvisioningWorkflowActionReview) throws {
        guard let row = rows[review.workflowID], row.sequence == review.workflowSequence, row.vmID == review.vmID,
              row.planDigest == review.planDigest, row.inputDigest == review.inputDigest,
              row.snapshot.availableActions.contains(review.action) else { throw ProvisioningReviewFailure.changed }
    }
}
