import Darwin
@testable import DevVMProvisioningCore
import Foundation
@testable import OmarchyVMManagerCore
import Testing
import TryOmarchyKitClient

final class WorkflowActionFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func created() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite("Reviewed workflow actions — fake/local only", .serialized) struct ProvisioningWorkflowActionTests {
    private func consent(_ review: ProvisioningWorkflowActionReview, ack: Bool = true) -> ProvisioningWorkflowActionConsent {
        .init(reviewID: review.id, action: review.action, reviewIdentity: review.reviewIdentity, acknowledged: ack)
    }
    private func restart(_ f: WorkflowFixture, id: UUID) async throws -> GuestBinding {
        let review = try await f.service.prepareAction(id, action: .restart, reviewID: UUID())
        _ = try await f.service.performAction(id, consent: consent(review))
        f.runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(await eventually { f.runtime.startedHandles.count == 2 })
        #expect(try await f.service.wait(id).stage == .waitingForRebind)
        let target = try GuestBinding(vmID: f.target.vmID, sessionID: f.runtime.startRequests[1].sessionID,
            owner: f.target.owner, ownerUID: f.target.ownerUID, hostKeyDigest: f.target.hostKeyDigest)
        try seedTransportEndpoint(root: f.runtime.startRequests[1].storageRoot, target: target, port: 22222)
        await f.manager.receiveSSH(.ready(user: target.owner, command: "unused fixture command"), vmID: target.vmID, sessionID: target.sessionID)
        return target
    }
    @Test func productActionsRefuseBeforeAnyTargetToolOrAdapterWork() async throws {
        let counter = WorkflowActionFactoryCounter(), guest = EngineFixtureGuest()
        let f = try await WorkflowFixture(enabled: false, recovery: { _ in counter.created(); return guest })
        for action in ProvisioningWorkflowAction.allCases {
            await #expect(throws: ProvisioningServiceFailure.disabled) { _ = try await f.service.prepareAction(UUID(), action: action, reviewID: UUID()) }
            await #expect(throws: ProvisioningServiceFailure.disabled) {
                _ = try await f.service.performAction(UUID(), consent: .init(reviewID: UUID(), action: action, reviewIdentity: String(repeating: "a", count: 64), acknowledged: true))
            }
        }
        #expect(await f.dependencies.inspections == 0); #expect(await f.launcher.launches == 0)
        #expect(counter.value == 0); #expect(await guest.commands.isEmpty)
        #expect(f.runtime.startedHandles.count == 1 && f.runtime.startedHandles[0].shutdownCount == 0)
        await f.close()
    }
    @Test func restartNeedsExactConsentAndMatchingExitBeforeFreshCheckReview() async throws {
        let f = try await WorkflowFixture(docker: true, task: "- ansible.builtin.debug: {msg: synthetic-custom-task}\n", allowRebind: true), id = try await f.apply(), reviewID = UUID()
        async let first = f.service.prepareAction(id, action: .restart, reviewID: reviewID)
        async let second = f.service.prepareAction(id, action: .restart, reviewID: reviewID)
        let (a, b) = try await (first, second)
        #expect(a == b && a.sessionID == f.target.sessionID && a.action == .restart)
        await #expect(throws: ProvisioningReviewFailure.consentRequired) { _ = try await f.service.performAction(id, consent: consent(a, ack: false)) }
        #expect(f.runtime.startedHandles[0].shutdownCount == 0)
        async let start = f.service.performAction(id, consent: consent(a))
        async let duplicate = f.service.performAction(id, consent: consent(a))
        _ = try await (start, duplicate)
        #expect(f.runtime.startedHandles[0].shutdownCount == 1 && f.runtime.startedHandles.count == 1)
        f.runtime.startedHandles[0].emit(.error(.init(code: .launchFailed, message: "fixture diagnostic")))
        try await Task.sleep(for: .milliseconds(40)); #expect(f.runtime.startedHandles.count == 1)
        f.runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(await eventually { f.runtime.startedHandles.count == 2 })
        #expect(try await f.service.wait(id).stage == .waitingForRebind)
        let binding = try GuestBinding(vmID: f.target.vmID, sessionID: f.runtime.startRequests[1].sessionID,
            owner: f.target.owner, ownerUID: f.target.ownerUID, hostKeyDigest: f.target.hostKeyDigest)
        try seedTransportEndpoint(root: f.runtime.startRequests[1].storageRoot, target: binding, port: 22222)
        await f.manager.receiveSSH(.ready(user: binding.owner, command: "unused"), vmID: binding.vmID, sessionID: binding.sessionID)
        let check = try await f.service.prepareAction(id, action: .check, reviewID: UUID())
        #expect(check.sessionID != a.sessionID && check.jobID != a.jobID && check.planDigest == a.planDigest && check.inputDigest == a.inputDigest)
        await #expect(throws: ProvisioningReviewFailure.consentRequired) {
            _ = try await f.service.performAction(id, consent: .init(reviewID: check.id, action: .check, reviewIdentity: a.reviewIdentity, acknowledged: true))
        }
        #expect(await f.launcher.launches == 1)
        async let checked = f.service.performAction(id, consent: consent(check))
        async let checkedAgain = f.service.performAction(id, consent: consent(check))
        _ = try await (checked, checkedAgain)
        #expect(try await f.service.wait(id).stage == .succeeded)
        #expect(await f.launcher.launches == 2)
        let runner = try #require(await f.launcher.runner(check.jobID))
        let calls = await runner.invocations
        #expect(calls.allSatisfy { if case .terminalLease = $0.input { return false }; return $0.context.mode == .check })
        #expect(calls.filter { [.features, .repository].contains($0.purpose) }.allSatisfy { $0.arguments.contains("--check") })
        #expect(calls.allSatisfy { $0.arguments.allSatisfy { !$0.contains("setup.custom") } })
        #expect(f.runtime.startedHandles.count == 2 && f.runtime.startedHandles[1].shutdownCount == 0)
        _ = try await f.service.performAction(id, consent: consent(check))
        #expect(await f.launcher.launches == 2)
        await f.close()
    }
    @Test func activeCleanupRiskIsNotARecoveryAction() async throws {
        let guest = EngineFixtureGuest(), counter = WorkflowActionFactoryCounter(), gate = IPCWorkerGate()
        let f = try await WorkflowFixture(recovery: { _ in counter.created(); return guest })
        let prepared = try await f.preview()
        await f.launcher.pause(gate)
        _ = try await f.service.approve(prepared.workflowID, approval: f.approval(prepared))
        #expect(await eventually { await gate.entered })
        let row = try #require(await f.service.status(prepared.workflowID))
        #expect(row.cleanupRequired && row.stage == .running && row.availableActions.isEmpty)
        await #expect(throws: ProvisioningServiceFailure.reviewRequired) { _ = try await f.service.prepareAction(row.id, action: .recover, reviewID: UUID()) }
        #expect(counter.value == 0)
        try await f.service.cancel(row.id); await gate.release(); _ = try await f.service.wait(row.id)
        await f.close()
    }
    @Test func recoveryDoesNotConstructAdapterUntilOriginalWorkerProofAndNeverReapplies() async throws {
        let guest = EngineFixtureGuest(), counter = WorkflowActionFactoryCounter()
        let f = try await WorkflowFixture(recovery: { _ in counter.created(); return guest })
        await f.launcher.uncertainNext()
        let id = try await f.apply()
        #expect(await f.service.status(id)?.cleanupRequired == true)
        let runner = try #require(await f.launcher.runner(id))
        let first = try await f.service.prepareAction(id, action: .recover, reviewID: UUID())
        #expect(counter.value == 0)
        await #expect(throws: ProvisioningJobFailure.ownershipUnverified) { _ = try await f.service.performAction(id, consent: consent(first)) }
        #expect(counter.value == 0); #expect(await guest.commands.isEmpty)
        await runner.proveCleanup()
        // A failed action remains a failed lookup, even after external proof changes.
        await #expect(throws: ProvisioningJobFailure.ownershipUnverified) { _ = try await f.service.performAction(id, consent: consent(first)) }
        let next = try await f.service.prepareAction(id, action: .recover, reviewID: UUID())
        #expect(next.reviewIdentity != first.reviewIdentity)
        try FileManager.default.removeItem(at: f.source) // Only the disposable setup source; no VM data.
        let result = try await f.service.performAction(id, consent: consent(next))
        #expect(!result.cleanupRequired && result.stage == .interrupted)
        #expect(counter.value == 1)
        let operations = await guest.commands
        #expect(!operations.isEmpty && operations.allSatisfy { $0.plan == nil && $0.inputLeaseID == nil })
        #expect(!operations.contains { [.stagePayload, .requestPersistentGrant, .configureFeatures, .configureRepository].contains($0.operation) })
        #expect(await f.launcher.launches == 1)
        #expect(f.runtime.startedHandles.count == 1 && f.runtime.startedHandles[0].shutdownCount == 0)
        _ = try await f.service.performAction(id, consent: consent(next)); #expect(counter.value == 1)
        try await f.assertCanPause(); await f.close()
    }
    @Test func failedRevocationKeepsRiskAndInvalidatesOtherPreparedRecoveryReviews() async throws {
        let guest = EngineFixtureGuest(failures: [.verifyGrantInactive]), counter = WorkflowActionFactoryCounter()
        let f = try await WorkflowFixture(recovery: { _ in counter.created(); return guest })
        await f.launcher.uncertainNext(); let id = try await f.apply()
        let runner = try #require(await f.launcher.runner(id)); await runner.proveCleanup()
        let first = try await f.service.prepareAction(id, action: .recover, reviewID: UUID())
        let stale = try await f.service.prepareAction(id, action: .recover, reviewID: UUID())
        let result = try await f.service.performAction(id, consent: consent(first))
        #expect(result.cleanupRequired)
        #expect(counter.value == 1)
        await #expect(throws: ProvisioningReviewFailure.changed) { _ = try await f.service.performAction(id, consent: consent(stale)) }
        _ = try await f.service.performAction(id, consent: consent(first))
        #expect(counter.value == 1)
        #expect(await f.service.status(id)?.cleanupRequired == true)
        await #expect(throws: VMFailure.self) { try await f.manager.pause(f.profile.id) }
        #expect(f.runtime.startedHandles[0].shutdownCount == 0)
        await f.close()
    }
    @Test func freshProcessWithoutOriginalCapabilityCannotRecoverEvenWithSavedJournal() async throws {
        let guest = EngineFixtureGuest(), counter = WorkflowActionFactoryCounter()
        let f = try await WorkflowFixture()
        await f.launcher.uncertainNext(); let id = try await f.apply()
        let runner = try #require(await f.launcher.runner(id)); await runner.proveCleanup()
        try await f.service.closeForReopen()
        let empty = WorkflowFixtureLauncher(provider: f.provider), target = f.target
        let reopened = try await ProvisioningService.open(manager: f.manager, directory: f.state, environment: .init(executionEnabled: true,
            engineDigest: ProvisioningCoordinator.engineIdentity(f.plan), dependencies: f.dependencies, launcher: empty,
            transportPolicy: .fixture(f.provider.root), admitPackage: {}, resolveTarget: { _, _ in target }, makeRecoveryAdapter: { _ in counter.created(); return guest }))
        let review = try await reopened.prepareAction(id, action: .recover, reviewID: UUID())
        await #expect(throws: ProvisioningJobFailure.ownershipUnverified) { _ = try await reopened.performAction(id, consent: consent(review)) }
        #expect(await reopened.status(id)?.cleanupRequired == true)
        #expect(counter.value == 0); #expect(await guest.commands.isEmpty)
        await #expect(throws: VMFailure.self) { try await f.manager.pause(f.profile.id) }
        #expect(await empty.launches == 0)
        try await reopened.closeForReopen(); await empty.close(); await f.launcher.close()
    }
    @Test(arguments: ["dependency", "cancel", "cancel-during"])
    func checkRecheckFailureCannotLaunchOrRepeatAHelper(kind: String) async throws {
        let f = try await WorkflowFixture(docker: true, allowRebind: true), id = try await f.apply()
        _ = try await restart(f, id: id)
        let review = try await f.service.prepareAction(id, action: .check, reviewID: UUID())
        if kind == "cancel-during" {
            let before = await f.dependencies.inspections, gate = IPCWorkerGate()
            await f.dependencies.pauseNext(gate)
            let attempt = Task { try await f.service.performAction(id, consent: consent(review)) }
            #expect(await eventually { await f.dependencies.inspections > before })
            try await f.service.cancel(id); await gate.release()
            do { _ = try await attempt.value; Issue.record("Cancelled action started check") } catch { }
        } else {
            if kind == "dependency" { try Data("replaced synthetic tool".utf8).write(to: f.provider.root.appendingPathComponent("ansible-playbook")) }
            else { try await f.service.cancel(id) }
            await #expect(throws: Error.self) { _ = try await f.service.performAction(id, consent: consent(review)) }
        }
        let inspections = await f.dependencies.inspections
        await #expect(throws: Error.self) { _ = try await f.service.performAction(id, consent: consent(review)) }
        #expect(await f.dependencies.inspections == inspections); #expect(await f.launcher.launches == 1)
        try? await f.service.cancel(id); await f.close()
    }
    @Test func staleRestartReviewCannotStopAChangedWorkflow() async throws {
        let f = try await WorkflowFixture(docker: true), id = try await f.apply()
        let review = try await f.service.prepareAction(id, action: .restart, reviewID: UUID())
        try await f.service.cancel(id)
        await #expect(throws: ProvisioningReviewFailure.changed) { _ = try await f.service.performAction(id, consent: consent(review)) }
        #expect(f.runtime.startedHandles.count == 1 && f.runtime.startedHandles[0].shutdownCount == 0)
        await f.close()
    }
    @Test func reviewIDsCannotChangeWorkflowOrActionAndCannotSurviveReopen() async throws {
        let f = try await WorkflowFixture(docker: true), id = try await f.apply(), reviewID = UUID()
        let review = try await f.service.prepareAction(id, action: .restart, reviewID: reviewID)
        await #expect(throws: ProvisioningJobFailure.jobConflict) { _ = try await f.service.prepareAction(UUID(), action: .restart, reviewID: reviewID) }
        await #expect(throws: ProvisioningJobFailure.jobConflict) { _ = try await f.service.prepareAction(id, action: .recover, reviewID: reviewID) }
        try await f.service.closeForReopen()
        let reopened = try await ProvisioningService.open(manager: f.manager, directory: f.state, environment: .init(executionEnabled: true,
            engineDigest: ProvisioningCoordinator.engineIdentity(f.plan), dependencies: f.dependencies, launcher: f.launcher,
            transportPolicy: .fixture(f.provider.root), admitPackage: {}))
        await #expect(throws: ProvisioningReviewFailure.consentRequired) { _ = try await reopened.performAction(id, consent: consent(review)) }
        #expect(f.runtime.startedHandles[0].shutdownCount == 0)
        try await reopened.closeForReopen(); await f.launcher.close()
    }
}
