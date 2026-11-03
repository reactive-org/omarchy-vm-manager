import Darwin
@testable import DevVMProvisioningCore
import Foundation
@testable import OmarchyVMManagerCore
import Testing

@Suite("Frozen preview and apply review — fake/local only", .serialized) struct ProvisioningReviewTests {
    private func capture(_ f: WorkflowFixture, id: UUID = UUID()) async throws -> ProvisioningPlanPreview {
        let selection = ProvisioningSetupSource(directory: f.source.path)
        try selection.validate()
        return try await f.service.preview(id: id, vmID: f.profile.id, source: selection)
    }
    private func consent(_ r: ProvisioningApplyReview, tasks: Bool = true) -> ProvisioningApplyConsent {
        .init(reviewIdentity: r.reviewIdentity, taskTrustIdentity: tasks ? r.taskTrustIdentity : nil,
              persistentGrantAcknowledged: true, dockerRootAccessAcknowledged: r.dockerRootAccessRequired)
    }
    @Test func productGateAllowsFrozenPreviewButRejectsApplyBeforeProbes() async throws {
        let f = try await WorkflowFixture(enabled: false, task: "- name: Synthetic review\n  ansible.builtin.debug: {msg: SYNTHETIC-PRIVATE-TASK}\n")
        let p = try await capture(f)
        #expect(!p.tasks.isEmpty)
        #expect(await f.dependencies.inspections == 0); #expect(await f.launcher.launches == 0)
        #expect(await f.service.status(p.id) == nil)
        await #expect(throws: ProvisioningServiceFailure.disabled) { _ = try await f.service.prepareApply(p.id) }
        await #expect(throws: ProvisioningServiceFailure.disabled) { _ = try await f.service.apply(p.id, consent: .init(reviewIdentity: p.planDigest)) }
        #expect(await f.dependencies.inspections == 0); #expect(await f.launcher.launches == 0)
        #expect(!String(reflecting: p).contains("SYNTHETIC-PRIVATE-TASK"))
        await f.close()
    }
    @Test func originalSourceEditsDoNotChangeFrozenPreviewOrAppliedInputs() async throws {
        let original = "- name: Frozen\n  ansible.builtin.debug: {msg: SYNTHETIC-FROZEN-TASK}\n"
        let f = try await WorkflowFixture(task: original)
        let p = try await capture(f)
        try Data("changed after preview".utf8).write(to: f.source.appendingPathComponent("custom.yml"))
        try Data("invalid: source-edited".utf8).write(to: f.source.appendingPathComponent("vm.yml"))
        let lookup = try await capture(f, id: p.id)
        #expect(lookup == p)
        let task = try await f.service.taskSource(p.id, name: "custom", offset: 0)
        #expect(task.bytes == Data(original.utf8) && task.sha256 == p.tasks.first?.sha256)
        #expect(!String(reflecting: task).contains("SYNTHETIC-FROZEN-TASK"))
        let review = try await f.service.prepareApply(p.id)
        _ = try await f.service.apply(p.id, consent: consent(review))
        #expect(try await f.service.wait(p.id).stage == .succeeded)
        #expect(await f.launcher.launches == 1)
        await f.close()
    }
    @Test func separateTaskTrustAndGrantAcknowledgementPrecedeAnyHelper() async throws {
        let f = try await WorkflowFixture(task: "- ansible.builtin.debug: {msg: fixture}\n")
        let p = try await capture(f), review = try await f.service.prepareApply(p.id)
        #expect(review.taskTrustIdentity != nil)
        await #expect(throws: ProvisioningReviewFailure.taskTrustRequired) { _ = try await f.service.apply(p.id, consent: consent(review, tasks: false)) }
        await #expect(throws: ProvisioningReviewFailure.taskTrustRequired) {
            _ = try await f.service.apply(p.id, consent: .init(reviewIdentity: review.reviewIdentity, taskTrustIdentity: String(repeating: "a", count: 64), persistentGrantAcknowledged: true))
        }
        await #expect(throws: ProvisioningReviewFailure.consentRequired) {
            _ = try await f.service.apply(p.id, consent: .init(reviewIdentity: review.reviewIdentity, taskTrustIdentity: review.taskTrustIdentity))
        }
        #expect(await f.launcher.launches == 0)
        async let first = f.service.apply(p.id, consent: consent(review))
        async let duplicate = f.service.apply(p.id, consent: consent(review))
        let (a, b) = try await (first, duplicate)
        #expect(a.id == b.id)
        #expect(try await f.service.wait(p.id).stage == .succeeded)
        #expect(await f.launcher.launches == 1)
        _ = try await f.service.apply(p.id, consent: consent(review))
        #expect(await f.launcher.launches == 1)
        await f.close()
    }
    @Test func preparationDeduplicatesAndDockerHasSeparateConsent() async throws {
        let f = try await WorkflowFixture(docker: true)
        let p = try await capture(f)
        async let first = f.service.prepareApply(p.id)
        async let duplicate = f.service.prepareApply(p.id)
        let (a, b) = try await (first, duplicate)
        #expect(a == b && a.dockerRootAccessRequired && a.taskTrustIdentity == nil)
        #expect(await f.dependencies.inspections == 1)
        await #expect(throws: ProvisioningReviewFailure.consentRequired) {
            _ = try await f.service.apply(p.id, consent: .init(reviewIdentity: a.reviewIdentity, persistentGrantAcknowledged: true))
        }
        #expect(await f.launcher.launches == 0)
        _ = try await f.service.apply(p.id, consent: consent(a))
        #expect(try await f.service.wait(p.id).stage == .restartRequired)
        #expect(f.runtime.startRequests.count == 1 && f.runtime.startedHandles[0].shutdownCount == 0)
        try await f.service.cancel(p.id); await f.close()
    }
    @Test(arguments: ["source", "dependency", "target", "cancel"])
    func changedAdmissionNeverSubmitsAndFailedSubmissionIsNotRetried(kind: String) async throws {
        let f = try await WorkflowFixture(task: "- ansible.builtin.debug: {msg: fixture}\n")
        let p = try await capture(f), review = try await f.service.prepareApply(p.id)
        switch kind {
        case "source":
            let root = try #require(await f.service.drafts[p.id]?.storage.directory)
            try Data("changed".utf8).write(to: root.appendingPathComponent("custom.yml"))
        case "dependency": try Data("replaced fixture tool".utf8).write(to: f.provider.root.appendingPathComponent("ansible-playbook"))
        case "target": await f.manager.receiveSSH(.ready(user: "changed_fixture_owner", command: "unused"), vmID: f.target.vmID, sessionID: f.target.sessionID)
        default: try await f.service.cancel(p.id)
        }
        await #expect(throws: Error.self) { _ = try await f.service.apply(p.id, consent: consent(review)) }
        let inspections = await f.dependencies.inspections
        await #expect(throws: Error.self) { _ = try await f.service.apply(p.id, consent: consent(review)) }
        #expect(await f.dependencies.inspections == inspections); #expect(await f.launcher.launches == 0)
        try? await f.service.cancel(p.id); await f.close()
    }
    @Test func cancellationDuringFinalRecheckCannotLaunchAWorker() async throws {
        let f = try await WorkflowFixture()
        let p = try await capture(f), review = try await f.service.prepareApply(p.id), gate = IPCWorkerGate()
        await f.dependencies.pauseNext(gate)
        let submission = Task { try await f.service.apply(p.id, consent: consent(review)) }
        #expect(await eventually { await f.dependencies.inspections == 2 })
        try await f.service.cancel(p.id)
        await gate.release()
        do { _ = try await submission.value; Issue.record("Cancelled review submitted") } catch { }
        #expect(await f.launcher.launches == 0)
        #expect(await f.service.status(p.id)?.stage == .cancelled)
        await f.close()
    }
    @Test func taskTrustDoesNotTransferToAnotherFrozenSnapshot() async throws {
        let f = try await WorkflowFixture(task: "- ansible.builtin.debug: {msg: first}\n")
        let first = try await capture(f), a = try await f.service.prepareApply(first.id)
        try await f.service.cancel(first.id)
        try Data("- ansible.builtin.debug: {msg: second}\n".utf8).write(to: f.source.appendingPathComponent("custom.yml"))
        let second = try await capture(f), b = try await f.service.prepareApply(second.id)
        #expect(a.taskTrustIdentity != b.taskTrustIdentity && first.inputDigest != second.inputDigest)
        await #expect(throws: ProvisioningReviewFailure.taskTrustRequired) {
            _ = try await f.service.apply(second.id, consent: .init(reviewIdentity: b.reviewIdentity, taskTrustIdentity: a.taskTrustIdentity, persistentGrantAcknowledged: true))
        }
        #expect(await f.launcher.launches == 0)
        try await f.service.cancel(second.id); await f.close()
    }
    @Test func previewQuotaPreservesExistingLookupAndNeverEvicts() async throws {
        let f = try await WorkflowFixture(enabled: false)
        let first = try await capture(f)
        for _ in 1..<16 { _ = try await capture(f) }
        await #expect(throws: ProvisioningReviewFailure.quota) { _ = try await capture(f) }
        #expect(try await f.service.preview(first.id) == first)
        #expect(await f.dependencies.inspections == 0); #expect(await f.launcher.launches == 0)
        await f.close()
    }
    @Test func previewIsInertAfterReopenAndMetadataCannotRecreateConsent() async throws {
        let f = try await WorkflowFixture()
        let p = try await capture(f)
        try await f.service.closeForReopen()
        let next = try await ProvisioningService.open(manager: f.manager, directory: f.state, environment: .init(executionEnabled: false,
            engineDigest: ProvisioningCoordinator.engineIdentity(f.plan), dependencies: f.dependencies, launcher: f.launcher,
            transportPolicy: .fixture(f.provider.root), admitPackage: {}))
        await #expect(throws: Error.self) { _ = try await next.preview(p.id) }
        await #expect(throws: ProvisioningServiceFailure.disabled) { _ = try await next.prepareApply(p.id) }
        #expect(await f.launcher.launches == 0)
        try await next.closeForReopen(); await f.launcher.close()
    }
    @Test func explicitTaskSourceIsChunkedScopedAndBoundsChecked() async throws {
        let text = "# " + String(repeating: "synthetic-source-€", count: 600) + "\n- ansible.builtin.debug: {msg: fixture}\n"
        let f = try await WorkflowFixture(task: text), p = try await capture(f)
        var bytes = Data(), offset = 0
        while true {
            let chunk = try await f.service.taskSource(p.id, name: "custom", offset: offset)
            #expect(chunk.bytes.count <= 4096)
            bytes += chunk.bytes; offset += chunk.bytes.count
            if offset == chunk.total { break }
        }
        #expect(bytes == Data(text.utf8))
        for (name, offset) in [("custom", -1), ("custom", bytes.count + 1), ("vm.yml", 0), ("../custom", 0)] {
            await #expect(throws: Error.self) { _ = try await f.service.taskSource(p.id, name: name, offset: offset) }
        }
        #expect(await f.dependencies.inspections == 0); #expect(await f.launcher.launches == 0)
        await f.close()
    }
}
