import Darwin
@testable import DevVMProvisioningCore
import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

actor WorkflowFixtureDependencies: ProvisioningDependencyProviding {
    let report: ProvisioningToolReport
    private(set) var inspections = 0
    private var gate: IPCWorkerGate?
    func pauseNext(_ value: IPCWorkerGate) { gate = value }
    init(_ report: ProvisioningToolReport) { self.report = report }
    func inspect() async throws -> ProvisioningToolReport { inspections += 1; if let gate { self.gate = nil; await gate.wait() }; return report }
}
actor WorkflowFixtureLauncher: ProvisioningServiceLaunching {
    let provider: SessionFixtureProvider
    private var children: [UUID: LocalTransportLauncher] = [:]
    private var runners: [UUID: SessionFixtureRunner] = [:]
    private var gate: IPCWorkerGate?
    private var registrationGate: IPCWorkerGate?
    private var denyExit = false
    var uncertain = false
    init(provider: SessionFixtureProvider) { self.provider = provider }
    func pause(_ gate: IPCWorkerGate) { self.gate = gate }
    func pauseRegistration(_ gate: IPCWorkerGate) { registrationGate = gate }
    func withholdExitProof() { denyExit = true }
    func uncertainNext() { uncertain = true }
    var launches: Int { children.count }
    func runner(_ id: UUID) -> SessionFixtureRunner? { runners[id] }
    func prepare(_ registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperLaunchTicket { throw ProvisioningServiceFailure.unavailable }
    func prepare(_ registration: ProvisioningHelperWorkerRegistration, delivery: ProvisioningFrozenDeliverySource) async throws -> ProvisioningHelperLaunchTicket { throw ProvisioningServiceFailure.unavailable }
    func prepare(_ registration: ProvisioningHelperWorkerRegistration, delivery: ProvisioningFrozenDeliverySource, transport: ProvisioningTransportHandoff) async throws -> ProvisioningHelperLaunchTicket {
        guard children[registration.scope.jobID] == nil else { throw ProvisioningJobFailure.jobConflict }
        let runner = SessionFixtureRunner(uncertainFeatures: uncertain); uncertain = false
        let child = LocalTransportLauncher(provider: provider, processRunner: runner)
        if let gate { self.gate = nil; await child.checks.pause(gate) }
        let ticket = try await child.prepare(registration, delivery: delivery, transport: transport)
        children[registration.scope.jobID] = child; runners[registration.scope.jobID] = runner; return ticket
    }
    func launch(_ ticket: ProvisioningHelperLaunchTicket) async throws -> ProvisioningHelperRegistrationReceipt {
        let receipt = try await selected(ticket.registration.scope.jobID).launch(ticket)
        if let registrationGate { self.registrationGate = nil; await registrationGate.wait() }
        return receipt
    }
    private func selected(_ id: UUID) throws -> LocalTransportLauncher { guard let child = children[id] else { throw ProvisioningHelperIPCFailure.ownership }; return child }
    func bindSessionAuthority(_ activation: ProvisioningHelperActivation, check: @escaping ProvisioningManagerSessionCheck) async throws { try await selected(activation.scope.jobID).bindSessionAuthority(activation, check: check) }
    func dispatch(_ kind: ProvisioningHelperDispatchKind, activation: ProvisioningHelperActivation) async throws -> ProvisioningHelperWorkerSnapshot { try await selected(activation.scope.jobID).dispatch(kind, activation: activation) }
    func reconcile(_ expected: ProvisioningRecoveryExpectation) async throws -> ProvisioningRecoveryPermit { try await selected(expected.jobID).reconcile(expected) }
    func releaseAfterCleanup(jobID: UUID, helperIdentity: ProvisioningHelperIdentity) async { try? await selected(jobID).releaseAfterCleanup(jobID: jobID, helperIdentity: helperIdentity) }
    func abort(_ activation: ProvisioningHelperActivation) async { try? await selected(activation.scope.jobID).abort(activation) }
    func abandon(_ ticket: ProvisioningHelperLaunchTicket) async { try? await selected(ticket.registration.scope.jobID).abandon(ticket) }
    func waitForExit(jobID: UUID, identity: ProvisioningHelperIdentity, timeout: Duration) async -> Bool { if denyExit { return false }; return (try? await selected(jobID).waitForExit(jobID: jobID, identity: identity, timeout: timeout)) ?? false }
    func close() async { for child in children.values { await child.close() } }
}
final class WorkflowFixture: Sendable {
    let root: URL, source: URL, state: URL
    let manager: VMManager, runtime: FakeRuntime, profile: VMProfile, target: GuestBinding
    let provider: SessionFixtureProvider, dependencies: WorkflowFixtureDependencies, launcher: WorkflowFixtureLauncher
    let plan: SetupPlan, service: ProvisioningService
    init(docker: Bool = false, ready: Bool = true, enabled: Bool = true, task: String? = nil, allowRebind: Bool = false,
         recovery: (@Sendable (ProvisioningTransportAdmission) throws -> any ProvisioningGuestAdapter)? = nil) async throws {
        root = URL(fileURLWithPath: "/private/tmp/provisioning-workflow-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); state = root.appendingPathComponent("state")
        try PrivateFiles.directory(root, create: true); try PrivateFiles.directory(source, create: true)
        let setup = docker ? "setup: {features: {enable: [cli, docker]}, options: {docker: {access: sudoless}}}" : "setup: {features: {enable: [cli]}}"
        if let task { try Data(task.utf8).write(to: source.appendingPathComponent("custom.yml")) }
        let custom = task == nil ? "" : "tasks: [{name: custom, file: custom.yml}]\n"
        try Data(("schema_version: 1\nid: workflow-fixture\n" + setup + "\n" + custom + "vars: {private: NEVER-PUBLISH-WORKFLOW-INPUT}\n").utf8).write(to: source.appendingPathComponent("vm.yml"))
        plan = try SetupPlanner.plan(repository: source)
        var profile = VMProfile(id: UUID(), name: "Workflow fixture", clipboardEnabled: false); profile.ssh = .init(hostPort: 22222); self.profile = profile
        runtime = FakeRuntime(initialEvents: [.ready])
        manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: root, hostMemoryMiB: 32768, logicalCPUs: 8, portProbe: TransportFixturePorts())
        try await manager.start(profile.id)
        let manager = manager, id = profile.id
        #expect(await eventually { await manager.snapshots().first?.state == .running })
        let session = try #require(await manager.snapshots().first?.sessionID)
        target = try GuestBinding(vmID: id, sessionID: session, owner: "fixture_owner", ownerUID: 1000, hostKeyDigest: sessionFixtureHostKeyDigest)
        try seedTransportEndpoint(root: runtime.startRequests[0].storageRoot, target: target, port: 22222)
        await manager.receiveSSH(ready ? .ready(user: target.owner, command: "fixture-unused") : .connecting, vmID: id, sessionID: session)
        provider = try SessionFixtureProvider(); dependencies = WorkflowFixtureDependencies(try provider.admittedReport()); launcher = WorkflowFixtureLauncher(provider: provider)
        let fixtureTarget = target
        service = try await ProvisioningService.open(manager: manager, directory: state, environment: .init(executionEnabled: enabled,
            engineDigest: ProvisioningCoordinator.engineIdentity(plan), dependencies: dependencies, launcher: launcher, transportPolicy: .fixture(provider.root), admitPackage: {}, resolveTarget: { vm, session in
                guard vm == fixtureTarget.vmID, allowRebind || session == fixtureTarget.sessionID else { throw ProvisioningReviewFailure.changed }
                return try GuestBinding(vmID: vm, sessionID: session, owner: fixtureTarget.owner, ownerUID: fixtureTarget.ownerUID, hostKeyDigest: fixtureTarget.hostKeyDigest)
            }, makeRecoveryAdapter: recovery))
    }
    deinit { for handle in runtime.startedHandles where handle.isRunning { handle.emit(.exited(status: 0)) }; try? FileManager.default.removeItem(at: root) }
    func preview(_ id: UUID = UUID()) async throws -> ProvisioningPreparedJob {
        try await service.prepare(id: id, plan: plan, repository: source, target: target, inputLeaseID: UUID(), timeout: .seconds(3))
        return try await service.prepared(id)
    }
    func approval(_ value: ProvisioningPreparedJob) -> ProvisioningApproval { .init(reviewIdentity: value.request.reviewIdentity, customTasksReviewed: true, persistentGrantAcknowledged: true, dockerRootAccessAcknowledged: true) }
    func apply() async throws -> UUID {
        let p = try await preview(); try await service.approve(p.workflowID, approval: approval(p)); _ = try await service.wait(p.workflowID); return p.workflowID
    }
    func assertCanPause() async throws {
        let task = Task { try await manager.pause(profile.id, timeout: .seconds(2)) }
        #expect(await eventually { self.runtime.startedHandles.last?.pauseCount == 1 })
        runtime.startedHandles.last?.emit(.executionState(.init(state: .paused, command: .pause)))
        try await task.value
    }
    func close() async { try? await service.closeForReopen(); await launcher.close() }
}
@Suite("Milestone 3 workflow completion — fake runtimes/local fixtures") struct ProvisioningServiceTests {
    @Test func productGateRejectsBeforeProbesOrHelperConstruction() async throws {
        let f = try await WorkflowFixture(enabled: false)
        await #expect(throws: ProvisioningServiceFailure.disabled) { _ = try await f.service.prepare(plan: f.plan, repository: f.source, target: f.target) }
        #expect(await f.dependencies.inspections == 0); #expect(await f.launcher.launches == 0)
        #expect(f.runtime.startedHandles.count == 1 && f.runtime.startedHandles[0].shutdownCount == 0)
        await f.close()
    }
    @Test func waitsForExactSSHAndSurvivesViewerDetachWithOneJob() async throws {
        let f = try await WorkflowFixture(ready: false), id = UUID()
        try await f.service.prepare(id: id, plan: f.plan, repository: f.source, target: f.target, inputLeaseID: UUID(), timeout: .seconds(3))
        let viewer = Task { try await f.service.wait(id) }; viewer.cancel()
        #expect(await f.service.status(id)?.stage == .waitingForSSH)
        #expect(await f.dependencies.inspections == 0)
        await #expect(throws: Error.self) { _ = try await f.service.prepare(plan: f.plan, repository: f.source, target: f.target) }
        await #expect(throws: VMFailure.self) { try await f.manager.pause(f.profile.id) }
        await f.manager.receiveSSH(.ready(user: f.target.owner, command: "fixture"), vmID: f.target.vmID, sessionID: UUID())
        #expect(await f.service.status(id)?.stage == .waitingForSSH)
        await f.manager.receiveSSH(.ready(user: f.target.owner, command: "fixture"), vmID: f.target.vmID, sessionID: f.target.sessionID)
        #expect(try await viewer.value.stage == .readyForReview)
        let p = try await f.service.prepared(id)
        try await f.service.approve(id, approval: f.approval(p))
        #expect(try await f.service.wait(id).stage == .succeeded)
        _ = try await f.service.approve(id, approval: f.approval(p))
        #expect(await f.launcher.launches == 1)
        try await f.service.cancel(id)
        #expect(await f.service.status(id)?.stage == .succeeded)
        let report = try await f.service.retention(); #expect(report.retainedFiles == 3 && !report.automaticEviction && report.unresolvedJobs == 0)
        await f.close()
    }
    @Test(arguments: ["timeout", "cancel", "shutdown", "source", "owner"])
    func preparationFailureNeverStartsHelperOrStopsAnUnrelatedGuest(kind: String) async throws {
        let f = try await WorkflowFixture(ready: false), id = UUID()
        try await f.service.prepare(id: id, plan: f.plan, repository: f.source, target: f.target, timeout: kind == "timeout" ? .milliseconds(60) : .seconds(3))
        if kind == "cancel" { try await f.service.cancel(id) }
        if kind == "shutdown" { await f.manager.shutDown(f.profile.id) }
        if kind == "source" { try Data("changed".utf8).write(to: f.source.appendingPathComponent("vm.yml")); await f.manager.receiveSSH(.ready(user: f.target.owner, command: "fixture"), vmID: f.target.vmID, sessionID: f.target.sessionID) }
        if kind == "owner" { await f.manager.receiveSSH(.ready(user: "different", command: "fixture"), vmID: f.target.vmID, sessionID: f.target.sessionID) }
        let result = try await f.service.wait(id)
        #expect([.failed, .cancelled].contains(result.stage) && !result.cleanupRequired)
        #expect(await f.launcher.launches == 0)
        #expect(f.runtime.startedHandles[0].shutdownCount == (kind == "shutdown" ? 1 : 0))
        await f.close()
    }
    @Test func plannedRestartWaitsForMatchingExitAndRequiresFreshRebindReview() async throws {
        let f = try await WorkflowFixture(docker: true), id = try await f.apply()
        #expect(await f.service.status(id)?.stage == .restartRequired)
        let review = try await f.service.restartReview(id), identity = try review.identity
        async let firstRestart = f.service.approveRestart(review, identity: identity, timeout: .seconds(3))
        async let secondRestart = f.service.approveRestart(review, identity: identity, timeout: .seconds(3))
        _ = try await (firstRestart, secondRestart)
        #expect(f.runtime.startedHandles[0].shutdownCount == 1 && f.runtime.startedHandles.count == 1)
        f.runtime.startedHandles[0].emit(.error(.init(code: .launchFailed, message: "fixture diagnostic")))
        try await Task.sleep(for: .milliseconds(50)); #expect(f.runtime.startedHandles.count == 1)
        await #expect(throws: VMFailure.self) { try await f.manager.start(f.profile.id) }
        f.runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(await eventually { f.runtime.startedHandles.count == 2 })
        #expect(try await f.service.wait(id).stage == .waitingForRebind)
        let newID = f.runtime.startRequests[1].sessionID
        let target = try GuestBinding(vmID: f.target.vmID, sessionID: newID, owner: f.target.owner, ownerUID: f.target.ownerUID, hostKeyDigest: f.target.hostKeyDigest)
        try seedTransportEndpoint(root: f.runtime.startRequests[1].storageRoot, target: target, port: 22222)
        await f.manager.receiveSSH(.ready(user: target.owner, command: "fixture"), vmID: target.vmID, sessionID: newID)
        let wrong = try GuestBinding(vmID: target.vmID, sessionID: newID, owner: target.owner, ownerUID: target.ownerUID, hostKeyDigest: String(repeating: "f", count: 64))
        await #expect(throws: ProvisioningServiceFailure.reviewRequired) { _ = try await f.service.prepareRebind(id, target: wrong) }
        let prepared = try await f.service.prepareRebind(id, target: target)
        let duplicate = try await f.service.prepareRebind(id, target: target)
        #expect(prepared.request.jobID == duplicate.request.jobID)
        #expect(prepared.request.mode == .check && prepared.request.selectedTasks.isEmpty && prepared.request.inputLeaseID == nil)
        let rebind = try await f.service.rebindReview(id)
        await #expect(throws: ProvisioningServiceFailure.reviewRequired) { _ = try await f.service.approveRebind(rebind, identity: identity) }
        let rebindIdentity = try rebind.identity
        async let firstCheck = f.service.approveRebind(rebind, identity: rebindIdentity)
        async let secondCheck = f.service.approveRebind(rebind, identity: rebindIdentity)
        _ = try await (firstCheck, secondCheck)
        #expect(try await f.service.wait(id).stage == .succeeded)
        _ = try await f.service.approveRebind(rebind, identity: rebind.identity)
        #expect(await f.launcher.launches == 2)
        #expect(f.runtime.startedHandles.count == 2 && f.runtime.startedHandles[1].shutdownCount == 0)
        await f.close()
    }
    @Test(arguments: ["timeout", "cancel"])
    func restartFailureDoesNotInventExitOrLaunchAReplacement(kind: String) async throws {
        let f = try await WorkflowFixture(docker: true), id = try await f.apply(), review = try await f.service.restartReview(id)
        try await f.service.approveRestart(review, identity: review.identity, timeout: .milliseconds(80))
        if kind == "cancel" { try await f.service.cancel(id) }
        let result = try await f.service.wait(id)
        #expect([.cancelled, .failed].contains(result.stage))
        #expect(f.runtime.startedHandles.count == 1 && f.runtime.startedHandles[0].isRunning)
        await f.close()
    }
    @Test func cancellingAnInertRegistrationFencesWithoutActivatingOrRemoteCleanup() async throws {
        let f = try await WorkflowFixture(), p = try await f.preview(), gate = IPCWorkerGate()
        await f.launcher.pauseRegistration(gate)
        try await f.service.approve(p.workflowID, approval: f.approval(p))
        #expect(await eventually { await gate.entered })
        try await f.service.cancel(p.workflowID)
        await gate.release()
        let result = try await f.service.wait(p.workflowID)
        #expect(result.stage == .cancelled && !result.cleanupRequired)
        let runner = try #require(await f.launcher.runner(p.request.jobID))
        #expect(await runner.invocations.isEmpty)
        try await f.assertCanPause()
        await f.close()
    }
    @Test func lostExitProofRetainsWorkflowHoldEvenAfterCleanEngineResult() async throws {
        let f = try await WorkflowFixture()
        await f.launcher.withholdExitProof()
        let id = try await f.apply()
        #expect(await f.service.status(id)?.cleanupRequired == true)
        await #expect(throws: VMFailure.self) { try await f.manager.pause(f.profile.id) }
        try await f.service.closeForReopen()
        let reopened = try await ProvisioningService.open(manager: f.manager, directory: f.state, environment: .init(executionEnabled: true,
            engineDigest: ProvisioningCoordinator.engineIdentity(f.plan), dependencies: f.dependencies, launcher: f.launcher,
            transportPolicy: .fixture(f.provider.root), admitPackage: {}))
        #expect(await reopened.status(id)?.cleanupRequired == true)
        #expect(await f.launcher.launches == 1)
        try await reopened.closeForReopen(); await f.launcher.close()
    }
    @Test(arguments: [false, true])
    func reopenedRecoveryRequiresSurvivingOriginalCapabilityAndIndependentLocalProof(lostCapability: Bool) async throws {
        let f = try await WorkflowFixture(), p = try await f.preview()
        await f.launcher.uncertainNext()
        try await f.service.approve(p.workflowID, approval: f.approval(p))
        #expect(try await f.service.wait(p.workflowID).cleanupRequired)
        let runner = try #require(await f.launcher.runner(p.request.jobID))
        try await f.service.closeForReopen()
        let recoveryLauncher = lostCapability ? WorkflowFixtureLauncher(provider: f.provider) : f.launcher
        let reopened = try await ProvisioningService.open(manager: f.manager, directory: f.state, environment: .init(executionEnabled: true,
            engineDigest: ProvisioningCoordinator.engineIdentity(f.plan), dependencies: f.dependencies, launcher: recoveryLauncher,
            transportPolicy: .fixture(f.provider.root), admitPackage: {}))
        let guest = EngineFixtureGuest()
        await #expect(throws: ProvisioningJobFailure.ownershipUnverified) { _ = try await reopened.recover(p.workflowID, admission: p.transport, adapter: guest) }
        #expect(await guest.commands.isEmpty)
        await runner.proveCleanup()
        if lostCapability {
            await #expect(throws: ProvisioningJobFailure.ownershipUnverified) { _ = try await reopened.recover(p.workflowID, admission: p.transport, adapter: guest) }
            #expect(await guest.commands.isEmpty)
            await #expect(throws: VMFailure.self) { try await f.manager.pause(f.profile.id) }
        } else {
            #expect(try await reopened.recover(p.workflowID, admission: p.transport, adapter: guest).cleanupRequired == false)
            #expect(await guest.commands.allSatisfy { $0.plan == nil && $0.inputLeaseID == nil && $0.operation != .stagePayload && $0.operation != .requestPersistentGrant })
            try await f.assertCanPause()
        }
        #expect(await f.launcher.launches == 1)
        #expect(await recoveryLauncher.launches == (lostCapability ? 0 : 1))
        try await reopened.closeForReopen(); await f.launcher.close(); await recoveryLauncher.close()
    }
    @Test func reopeningAnUnsubmittedReviewNeverResumesItAndPreservesOpaqueInputs() async throws {
        let f = try await WorkflowFixture(), p = try await f.preview()
        try await f.service.closeForReopen()
        let reopened = try await ProvisioningService.open(manager: f.manager, directory: f.state, environment: .init(executionEnabled: true,
            engineDigest: ProvisioningCoordinator.engineIdentity(f.plan), dependencies: f.dependencies, launcher: f.launcher,
            transportPolicy: .fixture(f.provider.root), admitPackage: {}))
        #expect(await reopened.status(p.workflowID)?.stage == .interrupted)
        await #expect(throws: ProvisioningServiceFailure.reviewRequired) { _ = try await reopened.approve(p.workflowID, approval: f.approval(p)) }
        #expect(await f.launcher.launches == 0)
        #expect(await f.dependencies.inspections == 1)
        let bytes = try Data(contentsOf: f.state.appendingPathComponent("workflows/workflows.json"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("NEVER-PUBLISH"))
        try await reopened.closeForReopen(); await f.launcher.close()
    }
    @Test func workflowWriteFailureBeforeSubmissionCannotStartHelper() async throws {
        let f = try await WorkflowFixture(), p = try await f.preview()
        let file = f.state.appendingPathComponent("workflows/workflows.json")
        let changed = Data("external-edit-preserved".utf8)
        try changed.write(to: file)
        await #expect(throws: ProvisioningJobFailure.journalUnavailable) { _ = try await f.service.approve(p.workflowID, approval: f.approval(p)) }
        #expect(await f.launcher.launches == 0)
        #expect(try Data(contentsOf: file) == changed)
        await #expect(throws: VMFailure.self) { try await f.manager.pause(f.profile.id) }
        await f.close()
    }

    @Test func retentionPreservesOrphansAndRefusesQuotaWithoutEviction() async throws {
        let f = try await WorkflowFixture(), p = try await f.preview()
        let directory = f.state.appendingPathComponent("artifacts")
        let orphan = Data("PRIVATE-ORPHAN-RETAINED".utf8)
        try PrivateFiles.write(orphan, name: "orphan.inputs", in: directory, exclusively: true)
        let report = try await f.service.retention()
        #expect(report.retainedFiles == 1 && report.orphanFiles == 1 && !report.automaticEviction)
        let small = try ProvisioningJobArtifacts(directory: directory, maximumTotalBytes: orphan.count)
        #expect(throws: ProvisioningJobFailure.artifactUnavailable) {
            _ = try small.prepare(p.request, payloadID: UUID(), workerToken: UUID(), engineDigest: ProvisioningCoordinator.engineIdentity(f.plan))
        }
        #expect(try PrivateFiles.read(directory.appendingPathComponent("orphan.inputs")) == orphan)
        let sources = f.state.appendingPathComponent("sources")
        for _ in 0..<128 { try PrivateFiles.directory(sources.appendingPathComponent(UUID().uuidString), create: true) }
        let archive = try FrozenInputsArchive(privateArchive: f.plan.snapshot.privateArchive(), expectedIdentity: f.plan.snapshot.identity)
        #expect(throws: ProvisioningJobFailure.artifactUnavailable) { try ProvisioningSourceRetention.admit(archive, into: sources) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: sources.path).count == 128)
        await f.close()
    }

    @Test func concurrentApprovalsPublishOneAcceptedJobBeforeSuspending() async throws {
        let f = try await WorkflowFixture(), p = try await f.preview(), approval = f.approval(p)
        async let a = f.service.approve(p.workflowID, approval: approval)
        async let b = f.service.approve(p.workflowID, approval: approval)
        _ = try await (a, b)
        #expect(try await f.service.wait(p.workflowID).stage == .succeeded)
        #expect(await f.launcher.launches == 1)
        await f.close()
    }
    @Test(arguments: ["source", "tool", "session"])
    func stalePreviewCannotStartAHelper(kind: String) async throws {
        let f = try await WorkflowFixture(), p = try await f.preview()
        if kind == "source" { try Data("changed".utf8).write(to: f.source.appendingPathComponent("vm.yml")) }
        if kind == "tool" { try Data("changed".utf8).write(to: f.provider.root.appendingPathComponent("ssh")) }
        if kind == "session" { await f.manager.receiveSSH(.failed("fixture failure"), vmID: f.target.vmID, sessionID: f.target.sessionID) }
        try await f.service.approve(p.workflowID, approval: f.approval(p))
        let result = try await f.service.wait(p.workflowID)
        #expect(result.stage == .failed && !result.cleanupRequired)
        #expect(await f.launcher.launches == 0)
        _ = try await f.service.approve(p.workflowID, approval: f.approval(p))
        #expect(await f.launcher.launches == 0)
        await f.close()
    }

    @Test(arguments: ["cancel", "timeout"])
    func rebindWaitFailureRetainsTheNewVMWithoutLaunchingAnotherHelper(kind: String) async throws {
        let f = try await WorkflowFixture(docker: true), id = try await f.apply(), review = try await f.service.restartReview(id)
        try await f.service.approveRestart(review, identity: review.identity, timeout: .seconds(3))
        f.runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(try await f.service.wait(id).stage == .waitingForRebind)
        let newID = f.runtime.startRequests[1].sessionID
        let target = try GuestBinding(vmID: f.target.vmID, sessionID: newID, owner: f.target.owner, ownerUID: f.target.ownerUID, hostKeyDigest: f.target.hostKeyDigest)
        await f.manager.receiveSSH(.connecting, vmID: target.vmID, sessionID: newID)
        let task = Task { try await f.service.prepareRebind(id, target: target, timeout: .milliseconds(100)) }
        if kind == "cancel" { try await f.service.cancel(id) }
        await #expect(throws: Error.self) { _ = try await task.value }
        let result = try #require(await f.service.status(id))
        #expect([.failed, .cancelled].contains(result.stage) && !result.cleanupRequired)
        #expect(await f.launcher.launches == 1)
        #expect(f.runtime.startedHandles.count == 2 && f.runtime.startedHandles[1].shutdownCount == 0)
        await f.close()
    }

}
