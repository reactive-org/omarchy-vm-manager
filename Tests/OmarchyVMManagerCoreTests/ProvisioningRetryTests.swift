import Darwin
@testable import DevVMProvisioningCore
import Foundation
@testable import OmarchyVMManagerCore
import Testing

/// Issue #14: a plan runs once; Run setup again rebuilds the same frozen choices
/// under a new ID. Fake runtimes and local fixtures only; no test starts a VM.
@Suite("Run setup again — fake/local only", .serialized) struct ProvisioningRetryTests {
    private func capture(_ f: WorkflowFixture) async throws -> ProvisioningPlanPreview {
        try await f.service.preview(id: UUID(), vmID: f.profile.id, source: .init(directory: f.source.path))
    }
    private func consent(_ r: ProvisioningApplyReview) -> ProvisioningApplyConsent {
        .init(reviewIdentity: r.reviewIdentity, taskTrustIdentity: r.taskTrustIdentity, persistentGrantAcknowledged: true, dockerRootAccessAcknowledged: r.dockerRootAccessRequired)
    }
    private func run(_ f: WorkflowFixture, _ id: UUID) async throws -> ProvisioningWorkflowSnapshot {
        let review = try await f.service.prepareApply(id)
        _ = try await f.service.apply(id, consent: consent(review))
        return try await f.service.wait(id)
    }
    private func reopen(_ manager: VMManager, state: URL, dependencies: WorkflowFixtureDependencies, launcher: WorkflowFixtureLauncher,
                        policy: URL, engine: String, enabled: Bool) async throws -> ProvisioningService {
        try await ProvisioningService.open(manager: manager, directory: state, environment: .init(executionEnabled: enabled,
            engineDigest: engine, dependencies: dependencies, launcher: launcher, transportPolicy: .fixture(policy), admitPackage: {}))
    }
    /// A finished run as the workflow journal records it, for a closed service directory.
    private func writeFinishedRun(_ state: URL, id: UUID, vmID: UUID, stage: ProvisioningWorkflowStage, plan: String, input: String, engine: String) throws {
        var row = ProvisioningWorkflowRecord(id: id, vmID: vmID, originalSessionID: UUID(), planDigest: plan, inputDigest: input, engineDigest: engine)
        row.stage = stage; row.reviewDigest = String(repeating: "d", count: 64); row.applyJobID = id
        row.cleanupRequired = stage == .cleanupRequired; row.sequence = 4
        if stage == .failed { row.failure = .systemUpdateFailed }
        let journal = try ProvisioningWorkflowJournal(directory: state.appendingPathComponent("workflows"))
        defer { journal.close() }
        let existing = try journal.load()
        try journal.save(existing.filter { $0.id != id } + [row])
    }

    @Test func approveObservesAnInProgressRunAndNothingReplaysAFinishedOne() async throws {
        let f = try await WorkflowFixture()
        let p = try await capture(f), review = try await f.service.prepareApply(p.id)
        let consent = consent(review)
        _ = try await f.service.apply(p.id, consent: consent)
        let first = try await f.service.wait(p.id)
        #expect(first.stage == .restartRequired && first.stage.inProgress && !first.runFinished)
        // In progress: a repeated approval (a double-click) observes the same run.
        let approval = ProvisioningApproval(reviewIdentity: review.reviewIdentity, persistentGrantAcknowledged: true)
        #expect(try await f.service.approve(p.id, approval: approval) == first)
        #expect(try await f.service.apply(p.id, consent: consent).id == p.id)
        // A plan with a job is never offered for review again, even from the cached review.
        await #expect(throws: ProvisioningServiceFailure.alreadyRun) { _ = try await f.service.prepareApply(p.id) }
        try await f.service.cancel(p.id)
        #expect(await f.service.status(p.id)?.stage == .cancelled)
        await #expect(throws: ProvisioningServiceFailure.alreadyRun) { _ = try await f.service.approve(p.id, approval: approval) }
        await #expect(throws: ProvisioningServiceFailure.alreadyRun) { _ = try await f.service.apply(p.id, consent: consent) }
        await #expect(throws: ProvisioningServiceFailure.alreadyRun) { _ = try await f.service.prepareApply(p.id) }
        #expect(await f.launcher.launches == 1)
        #expect(f.runtime.startRequests.count == 1)
        await f.close()
    }

    @Test(arguments: [ProvisioningWorkflowStage.succeeded, .checked, .failed, .cancelled, .interrupted, .cleanupRequired])
    func approveAndPrepareApplyRefuseEveryFinishedRun(stage: ProvisioningWorkflowStage) async throws {
        let f = try await CreationFixture(), p = try await f.prepare(), vmID = try await f.create(p)
        try await f.service.closeForReopen()
        try writeFinishedRun(f.state, id: p.id, vmID: vmID, stage: stage, plan: p.planDigest, input: p.inputDigest, engine: f.engine)
        let next = try await reopen(f.manager, state: f.state, dependencies: f.dependencies, launcher: f.launcher, policy: f.provider.root, engine: f.engine, enabled: true)
        let row = try #require(await next.status(p.id))
        #expect(row.stage == stage && row.runFinished && !stage.inProgress)
        await #expect(throws: ProvisioningServiceFailure.alreadyRun) { _ = try await next.approve(p.id, approval: .init(reviewIdentity: String(repeating: "d", count: 64))) }
        await #expect(throws: ProvisioningServiceFailure.alreadyRun) { _ = try await next.prepareApply(p.id) }
        #expect(await next.status(p.id) == row)
        try await next.closeForReopen(); await f.assertInert(); await f.launcher.close()
    }

    @Test func retryRebuildsTheFrozenChoicesUnderANewIDAfterTheSourceFolderIsRemoved() async throws {
        let f = try await WorkflowFixture()
        await f.launcher.failUpdate()
        let p = try await capture(f)
        #expect(try await run(f, p.id).stage == .failed)
        let failed = await f.service.status(p.id)
        #expect(await f.service.latestSetup(vmID: f.profile.id) == .init(planID: p.id, workflow: failed))
        // "The same choices again", not "whatever is in the folder now".
        try FileManager.default.removeItem(at: f.source)
        let retryID = UUID(), retry = try await f.service.prepareRetry(id: retryID, of: p.id)
        #expect(retry.preview.id == retryID && retry.preview.id != p.id && retry.previousID == p.id && retry.preview.vmID == f.profile.id)
        #expect(retry.preview.inputDigest == p.inputDigest && retry.preview.planDigest == p.planDigest && retry.preview.proposal == p.proposal)
        #expect(!retry.engineChanged && !retry.planChanged && retry.addedFeatures == [] && retry.removedFeatures == [])
        #expect(try await f.service.prepareRetry(id: retryID, of: p.id) == retry) // Lookup, never a re-plan.
        #expect(await f.service.status(retryID) == nil)
        #expect(await f.launcher.launches == 1)
        // The retry goes through the normal review and starts a second run.
        let second = try await run(f, retryID)
        #expect(second.id == retryID && second.stage == .restartRequired)
        #expect(await f.launcher.launches == 2)
        #expect(await f.service.latestSetup(vmID: f.profile.id) == .init(planID: retryID, workflow: second))
        #expect(await f.service.status(p.id)?.stage == .failed)
        // Only a finished run without a cleanup hold can be retried.
        await #expect(throws: ProvisioningReviewFailure.unavailable) { _ = try await f.service.prepareRetry(id: UUID(), of: retryID) }
        try await f.service.cancel(retryID); await f.close()
    }

    @Test func retryAfterReopenUsesTheRecordedInputsAndNamesAnEngineChange() async throws {
        let f = try await WorkflowFixture()
        await f.launcher.failUpdate()
        let p = try await capture(f)
        #expect(try await run(f, p.id).stage == .failed)
        try await f.service.closeForReopen()
        let engine = try ProvisioningCoordinator.engineIdentity(f.plan)
        let next = try await reopen(f.manager, state: f.state, dependencies: f.dependencies, launcher: f.launcher, policy: f.provider.root, engine: engine, enabled: true)
        let latest = try #require(await next.latestSetup(vmID: f.profile.id))
        #expect(latest.planID == p.id && latest.workflow?.stage == .failed && latest.workflow?.failure == .systemUpdateFailed)
        let restored = try await next.preview(p.id)
        #expect(restored.planDigest == p.planDigest && restored.inputDigest == p.inputDigest && restored.sessionID == nil)
        await #expect(throws: ProvisioningServiceFailure.alreadyRun) { _ = try await next.prepareApply(p.id) }
        // Stand in for a run made by an older dev-vm: its record names a different
        // engine, plan and feature set for the same frozen inputs.
        let history = await next.planHistory, record = try #require(history.record(p.id))
        #expect(record.vmID == f.profile.id && record.tree.hasPrefix("inputs-") && record.manifest == "vm.yml" && record.features.contains("cli"))
        try history.replaceForTesting(.init(id: record.id, vmID: record.vmID, tree: record.tree, manifest: record.manifest,
            planDigest: String(repeating: "b", count: 64), inputDigest: record.inputDigest, engineDigest: String(repeating: "a", count: 64),
            features: record.features.filter { $0 != "cli" } + ["retired-feature"]))
        try await next.closeForReopen()
        let updated = try await reopen(f.manager, state: f.state, dependencies: f.dependencies, launcher: f.launcher, policy: f.provider.root, engine: engine, enabled: true)
        // The old plan can't be shown under a different engine, but it can be retried.
        await #expect(throws: ProvisioningReviewFailure.changed) { _ = try await updated.preview(p.id) }
        try FileManager.default.removeItem(at: f.source)
        let retry = try await updated.prepareRetry(id: UUID(), of: p.id)
        #expect(retry.engineChanged && retry.planChanged && retry.preview.engineDigest == engine && retry.preview.inputDigest == p.inputDigest)
        #expect(retry.addedFeatures == ["cli"] && retry.removedFeatures == ["retired-feature"])
        #expect(await f.launcher.launches == 1)
        try await updated.closeForReopen(); await f.launcher.close()
    }

    @Test func legacyCreationPlanIsRetriedFromItsRetainedInputsByInputDigest() async throws {
        let f = try await CreationFixture(), p = try await f.prepare(), vmID = try await f.create(p)
        try await f.service.closeForReopen()
        try writeFinishedRun(f.state, id: p.id, vmID: vmID, stage: .failed, plan: p.planDigest, input: p.inputDigest, engine: f.engine)
        try FileManager.default.removeItem(at: f.source)
        let next = try await reopen(f.manager, state: f.state, dependencies: f.dependencies, launcher: f.launcher, policy: f.provider.root, engine: f.engine, enabled: false)
        let latest = try #require(await next.latestSetup(vmID: vmID))
        #expect(latest.planID == p.id && latest.workflow?.stage == .failed)
        let retry = try await next.prepareRetry(id: UUID(), of: p.id)
        #expect(retry.preview.inputDigest == p.inputDigest && retry.preview.planDigest == p.planDigest && !retry.engineChanged && !retry.planChanged)
        // Retrying grants nothing: execution stays disabled in this service.
        await #expect(throws: ProvisioningServiceFailure.disabled) { _ = try await next.prepareApply(retry.preview.id) }
        try await next.closeForReopen()
        // The same legacy run, made by an older engine: found by its engine-independent input digest.
        try writeFinishedRun(f.state, id: p.id, vmID: vmID, stage: .failed, plan: String(repeating: "b", count: 64), input: p.inputDigest, engine: String(repeating: "a", count: 64))
        let updated = try await reopen(f.manager, state: f.state, dependencies: f.dependencies, launcher: f.launcher, policy: f.provider.root, engine: f.engine, enabled: false)
        let changed = try await updated.prepareRetry(id: UUID(), of: p.id)
        #expect(changed.engineChanged && changed.planChanged && changed.addedFeatures == nil && changed.preview.inputDigest == p.inputDigest)
        try await updated.closeForReopen(); await f.assertInert(); await f.launcher.close()
    }

    @Test func damagedPlanHistoryIsPreservedAndNoRunStartsWithoutItsRecord() async throws {
        let f = try await WorkflowFixture()
        try await f.service.closeForReopen()
        let plans = f.state.appendingPathComponent("plans")
        try PrivateFiles.write(Data("{\"damaged\": true}".utf8), name: "plans.json", in: plans)
        let next = try await reopen(f.manager, state: f.state, dependencies: f.dependencies, launcher: f.launcher, policy: f.provider.root,
            engine: try ProvisioningCoordinator.engineIdentity(f.plan), enabled: true)
        let p = try await next.preview(id: UUID(), vmID: f.profile.id, source: .init(directory: f.source.path))
        _ = p
        await #expect(throws: Error.self) {
            let review = try await next.prepareApply(p.id)
            _ = try await next.apply(p.id, consent: consent(review))
        }
        #expect(await f.launcher.launches == 0)
        #expect(await next.status(p.id)?.applyJobID == nil)
        #expect(try PrivateFiles.read(plans.appendingPathComponent("plans.json")) == Data("{\"damaged\": true}".utf8))
        try? await next.cancel(p.id)
        try await next.closeForReopen(); await f.launcher.close()
    }
}
