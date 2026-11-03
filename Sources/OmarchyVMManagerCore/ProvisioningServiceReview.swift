import DevVMProvisioningCore
import Foundation

extension ProvisioningService: ProvisioningReviewing {
    public func preview(id: UUID = UUID(), vmID: UUID, source: ProvisioningSetupSource) async throws -> ProvisioningPlanPreview {
        try reviewAvailable(); try source.validate()
        if let draft = drafts[id] {
            guard draft.preview.vmID == vmID, draft.selection == source else { throw ProvisioningJobFailure.jobConflict }
            return try preview(id) // Lookup, never recapture after a lost reply.
        }
        guard drafts.count + draftCaptures.count < 16, !draftCaptures.contains(id), status(id) == nil else { throw ProvisioningReviewFailure.quota }
        draftCaptures.insert(id); defer { draftCaptures.remove(id) }
        let snapshots = await manager.snapshots()
        try reviewAvailable()
        guard let target = snapshots.first(where: { $0.id == vmID }) else { throw ProvisioningReviewFailure.invalid }
        try environment.admitPackage()
        let directory: URL, manifest: String
        if let preset = source.preset {
            let url = try BundledProvisioning.presetSource(preset); directory = url.deletingLastPathComponent(); manifest = url.lastPathComponent
        } else { directory = URL(fileURLWithPath: source.directory!); manifest = "vm.yml" }
        let proposed = try SetupPlanner.plan(repository: directory, manifest: manifest)
        guard try ProvisioningCoordinator.engineIdentity(proposed) == environment.engineDigest else { throw ProvisioningReviewFailure.changed }
        let archive = try FrozenInputsArchive(privateArchive: proposed.snapshot.privateArchive(), expectedIdentity: proposed.snapshot.identity)
        try ProvisioningSourceRetention.admit(archive, into: sourceDirectory)
        let storage = try ProvisioningPrivateInputTree(archive: archive, parent: sourceDirectory)
        let plan = try SetupPlanner.plan(repository: storage.directory, manifest: manifest)
        guard plan.identity == proposed.identity, plan.snapshot.identity == archive.identity,
              case .object(let document) = plan.document, case .array(let taskFields) = document["tasks"],
              case .object(let requirements) = document["requirements"] else { throw ProvisioningReviewFailure.changed }
        let tasks = try taskFields.map { value -> ProvisioningTaskReview in
            guard case .object(let fields) = value, case .string(let name) = fields["name"], case .string(let file) = fields["file"],
                  let receipt = plan.snapshot.receipts.first(where: { $0.path == file }) else { throw ProvisioningReviewFailure.invalid }
            return .init(name: name, file: file, sha256: receipt.sha256)
        }
        let result = ProvisioningPlanPreview(id: id, vmID: vmID, sessionID: target.sessionID, planDigest: plan.identity, inputDigest: plan.snapshot.identity,
            engineDigest: environment.engineDigest, proposal: try helperJSON(plan), tasks: tasks,
            restartRequired: requirements["desktop_restart_required"] == .bool(true))
        try result.validate(); try environment.admitPackage()
        drafts[id] = .init(selection: source, preview: result, storage: storage, plan: plan)
        return result
    }
    public func preview(_ id: UUID) throws -> ProvisioningPlanPreview {
        try reviewAvailable(); guard let draft = drafts[id] else { throw ProvisioningReviewFailure.unavailable }
        try verify(draft); return draft.preview
    }
    public func taskSource(_ id: UUID, name: String, offset: Int) throws -> ProvisioningTaskSource {
        try reviewAvailable()
        guard let draft = drafts[id], let task = draft.preview.tasks.first(where: { $0.name == name }),
              let bytes = draft.plan.snapshot.data(for: task.file), offset >= 0, offset <= bytes.count else { throw ProvisioningReviewFailure.invalid }
        try verify(draft)
        return .init(previewID: id, name: name, sha256: task.sha256, offset: offset, total: bytes.count, bytes: bytes.subdata(in: offset..<min(bytes.count, offset + 4096)))
    }
    private func verify(_ draft: ProvisioningDraft) throws {
        try environment.admitPackage(); try draft.storage.verifyRoot()
        do { try draft.plan.verify(in: draft.storage.directory) } catch { throw ProvisioningReviewFailure.changed }
    }
    public func prepareApply(_ id: UUID) async throws -> ProvisioningApplyReview {
        try enabled()
        if let review = applyReviews[id] { return review }
        if let task = applyPreparations[id] { return try await task.value }
        guard let draft = drafts[id], !reviewOperations.contains(id) else { throw ProvisioningReviewFailure.unavailable }
        reviewOperations.insert(id)
        let task = Task { try await self.prepareDraft(draft) }
        applyPreparations[id] = task
        do { let review = try await task.value; reviewOperations.remove(id); return review }
        catch { reviewOperations.remove(id); throw error } // Cache failure; no automatic retry.
    }
    private func prepareDraft(_ draft: ProvisioningDraft) async throws -> ProvisioningApplyReview {
        try enabled(); try verify(draft)
        let id = draft.preview.id
        guard let target = await manager.snapshots().first(where: { $0.id == draft.preview.vmID }), let sessionID = target.sessionID,
              draft.preview.sessionID == nil || draft.preview.sessionID == sessionID,
              let resolve = environment.resolveTarget else { throw ProvisioningReviewFailure.unavailable }
        let binding = try await resolve(target.id, sessionID)
        try enabled()
        guard binding.vmID == target.id, binding.sessionID == sessionID else { throw ProvisioningReviewFailure.changed }
        _ = try await manager.provisioningSSHAdmission(binding)
        try verify(draft)
        _ = try await prepare(id: id, plan: draft.plan, repository: draft.storage.directory, target: binding, inputLeaseID: UUID())
        let prepared = try await prepared(id)
        try enabled(); try verify(draft)
        let request = prepared.request
        let trust = request.selectedTasks.isEmpty ? nil : KitVerifier.sha256(try helperJSON(["custom-task-trust-v1", request.reviewIdentity, draft.preview.inputDigest] + request.selectedTasks))
        let review = ProvisioningApplyReview(previewID: id, vmID: binding.vmID, sessionID: binding.sessionID, planDigest: draft.preview.planDigest,
            inputDigest: draft.preview.inputDigest, dependencyDigest: request.dependencyDigest, reviewIdentity: request.reviewIdentity, taskTrustIdentity: trust,
            persistentGrantRequired: true, dockerRootAccessRequired: draft.preview.restartRequired)
        try review.validate(); applyReviews[id] = review; return review
    }
    public func apply(_ id: UUID, consent: ProvisioningApplyConsent) async throws -> ProvisioningWorkflowSnapshot {
        try enabled(); try consent.validate()
        guard let review = applyReviews[id], consent.reviewIdentity == review.reviewIdentity else { throw ProvisioningReviewFailure.consentRequired }
        guard consent.taskTrustIdentity == review.taskTrustIdentity else { throw ProvisioningReviewFailure.taskTrustRequired }
        guard consent.persistentGrantAcknowledged, !review.dockerRootAccessRequired || consent.dockerRootAccessAcknowledged else { throw ProvisioningReviewFailure.consentRequired }
        if let (original, task) = applySubmissions[id] {
            guard original == consent else { throw ProvisioningReviewFailure.conflictingConsent }
            return try await task.value
        }
        guard drafts[id] != nil, !reviewOperations.contains(id) else { throw ProvisioningReviewFailure.unavailable }
        reviewOperations.insert(id)
        let task = Task { try await self.submitDraft(id, review: review, consent: consent) }
        applySubmissions[id] = (consent, task)
        do { let result = try await task.value; reviewOperations.remove(id); return result }
        catch { reviewOperations.remove(id); throw error }
    }
    private func submitDraft(_ id: UUID, review: ProvisioningApplyReview, consent: ProvisioningApplyConsent) async throws -> ProvisioningWorkflowSnapshot {
        try enabled(); guard let draft = drafts[id] else { throw ProvisioningReviewFailure.unavailable }
        try verify(draft)
        let value = try await prepared(id)
        guard value.request.reviewIdentity == review.reviewIdentity else { throw ProvisioningReviewFailure.changed }
        // Check both original resource stamps and freshly discovered dependencies.
        let report = try await environment.dependencies.inspect()
        try enabled(); try verify(draft)
        let fresh = try await manager.admitProvisioningTransport(target: value.request.target, report: report, policy: environment.transportPolicy)
        try await manager.validateProvisioningTransport(value.transport)
        guard fresh.dependencyDigest == review.dependencyDigest else { throw ProvisioningReviewFailure.changed }
        try enabled(); try verify(draft)
        return try await approve(id, approval: .init(reviewIdentity: review.reviewIdentity, customTasksReviewed: consent.taskTrustIdentity != nil,
            persistentGrantAcknowledged: consent.persistentGrantAcknowledged, dockerRootAccessAcknowledged: consent.dockerRootAccessAcknowledged))
    }
}
