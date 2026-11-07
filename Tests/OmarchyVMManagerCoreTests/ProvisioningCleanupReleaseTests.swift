import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

/// Issue #24: a stopped guest whose setup cleanup can't be verified. Fake runtimes,
/// local fixtures and disposable roots only; no real VM is started or changed.
@Suite("Cleanup hold release — fake runtimes/local fixtures") struct ProvisioningCleanupReleaseTests {
    private func consent(_ review: ProvisioningWorkflowActionReview, acknowledged: Bool = true) -> ProvisioningWorkflowActionConsent {
        .init(reviewID: review.id, action: review.action, reviewIdentity: review.reviewIdentity, acknowledged: acknowledged)
    }
    private func stop(_ f: WorkflowFixture) async {
        await f.manager.shutDown(f.profile.id)
        f.runtime.startedHandles.last?.emit(.exited(status: 0))
        let manager = f.manager, id = f.profile.id
        #expect(await eventually { await manager.snapshots().first { $0.id == id }?.sessionID == nil })
    }

    @Test func aStoppedGuestCanBeReleasedAndUsedAgainAfterReopen() async throws {
        let f = try await WorkflowFixture()
        await f.launcher.uncertainNext()
        let id = try await f.apply()
        let held = try #require(await f.service.status(id))
        #expect(held.cleanupRequired && held.availableActions == [.recover, .release])
        // While the original session is live, only recovery applies.
        await #expect(throws: ProvisioningJobFailure.targetChanged) { _ = try await f.service.prepareAction(id, action: .release, reviewID: UUID()) }
        await stop(f)
        // The deadlock from #24: every lifecycle action is refused while the hold stands.
        let current = try #require(await f.manager.snapshots().first { $0.id == f.profile.id }?.profile)
        for attempt in 0..<2 {
            do {
                if attempt == 0 { try await f.manager.start(f.profile.id) } else { try await f.manager.configure(current) }
                Issue.record("A held guest was not refused")
            } catch let failure as VMFailure { #expect(failure.code == "provisioning-busy") }
        }
        await #expect(throws: ProvisioningReviewFailure.unavailable) { _ = try await f.service.prepareAction(id, action: .recover, reviewID: UUID()) }
        let review = try await f.service.prepareAction(id, action: .release, reviewID: UUID())
        #expect(review.action == .release && review.vmID == f.profile.id)
        await #expect(throws: ProvisioningReviewFailure.consentRequired) { _ = try await f.service.performAction(id, consent: consent(review, acknowledged: false)) }
        #expect(await f.service.status(id)?.cleanupRequired == true)
        let released = try await f.service.performAction(id, consent: consent(review))
        #expect(!released.cleanupRequired && released.cleanupRelease == .unverified && released.availableActions.isEmpty)
        #expect([.interrupted, .failed, .cancelled].contains(released.stage) && released.title == "Cleanup released without verification")
        let job = try #require(await f.service.jobStatus(id))
        #expect(!job.cleanupRequired && job.cleanupRelease == .unverified)
        // Both journals record the release under their new schema versions.
        let jobsDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: f.state.appendingPathComponent("jobs/jobs.json"))) as! [String: Any]
        let workflowFile = try #require(FileManager.default.contentsOfDirectory(at: f.state.appendingPathComponent("workflows"), includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        let workflowDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: workflowFile)) as! [String: Any]
        #expect(jobsDocument["schemaVersion"] as? Int == 8 && workflowDocument["schemaVersion"] as? Int == 2)
        // Reopening never reloads the hold, and history still says it was released unverified.
        try await f.service.closeForReopen()
        let reopened = try await ProvisioningService.open(manager: f.manager, directory: f.state, environment: .init(executionEnabled: true,
            engineDigest: ProvisioningCoordinator.engineIdentity(f.plan), dependencies: f.dependencies, launcher: f.launcher,
            transportPolicy: .fixture(f.provider.root), admitPackage: {}))
        let after = try #require(await reopened.status(id))
        #expect(!after.cleanupRequired && after.cleanupRelease == .unverified)
        #expect(await reopened.statuses().allSatisfy { !$0.cleanupRequired })
        // The fixture has no registry, so configure stops later; it is no longer the hold.
        do { try await f.manager.configure(current) } catch let failure as VMFailure { #expect(failure.code != "provisioning-busy") }
        try await f.manager.start(f.profile.id)
        let manager = f.manager, vmID = f.profile.id
        #expect(await eventually { await manager.snapshots().first { $0.id == vmID }?.state == .running })
        // The fixture's "uncertain" helper never proves its exit, so its launcher is not closed.
        try await reopened.closeForReopen()
    }

    @Test func releaseIsRefusedWhileProvisioningStorageIsUnknown() async throws {
        let f = try await WorkflowFixture()
        await f.launcher.uncertainNext()
        let id = try await f.apply()
        await stop(f)
        let review = try await f.service.prepareAction(id, action: .release, reviewID: UUID())
        await f.manager.markProvisioningStorageUnknown()
        await #expect(throws: Error.self) { _ = try await f.service.performAction(id, consent: consent(review)) }
        #expect(await f.service.status(id)?.cleanupRequired == true)
        #expect(await f.service.jobStatus(id)?.cleanupRequired == true)
        // The fake helper of an unreleased, unrecovered job never stops serving once its
        // guest has gone, so only the service is closed here.
        try? await f.service.closeForReopen()
    }

    @Test func releasingOneGuestLeavesAnotherGuestsHoldInPlace() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/provisioning-release-" + UUID().uuidString)
        try PrivateFiles.directory(root, create: true); defer { try? FileManager.default.removeItem(at: root) }
        let first = VMProfile(id: UUID(), name: "Release fixture", clipboardEnabled: false), second = VMProfile(id: UUID(), name: "Held fixture", clipboardEnabled: false)
        let runtime = FakeRuntime(initialEvents: [.ready])
        let manager = VMManager(runtime: runtime, profiles: [first, second], applicationSupport: root, hostMemoryMiB: 32768, logicalCPUs: 8)
        await manager.seedProvisioningRisk([first.id, second.id])
        await manager.setProvisioningWorkflowHold(UUID(), vmID: first.id, required: true)
        await manager.setProvisioningWorkflowHold(UUID(), vmID: second.id, required: true)
        try await manager.releaseProvisioningHold(first.id)
        await #expect(throws: VMFailure.self) { try await manager.start(second.id) }
        try await manager.start(first.id)
        #expect(await eventually { await manager.snapshots().first { $0.id == first.id }?.state == .running })
        // A running guest can't be released; neither can anything once storage is unknown.
        await #expect(throws: ProvisioningJobFailure.targetChanged) { try await manager.requireProvisioningHoldReleasable(first.id) }
        await manager.markProvisioningStorageUnknown()
        await #expect(throws: ProvisioningJobFailure.busy) { try await manager.requireProvisioningHoldReleasable(second.id) }
        for handle in runtime.startedHandles where handle.isRunning { handle.emit(.exited(status: 0)) }
    }
}
