import Darwin
import DevVMProvisioningCore
import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

private let jobDependencies = String(repeating: "d", count: 64)
private actor JobRecoveryAuthority: ProvisioningRecoveryAuthorizing {
    var state: ProvisioningPriorWorkerState = .stoppedAndFenced
    var wrongChallenge = false
    var gate: JobGate?
    private(set) var expectations: [ProvisioningRecoveryExpectation] = []
    func deny(_ state: ProvisioningPriorWorkerState) { self.state = state }
    func mismatch() { wrongChallenge = true }
    func pause(_ gate: JobGate) { self.gate = gate }
    func reconcile(_ expectation: ProvisioningRecoveryExpectation) async throws -> ProvisioningRecoveryPermit {
        expectations.append(expectation)
        if let gate { self.gate = nil; await gate.pause() }
        let result = wrongChallenge ? ProvisioningRecoveryExpectation(challenge: UUID(), jobID: expectation.jobID,
            vmID: expectation.vmID, sessionID: expectation.sessionID, payloadID: expectation.payloadID,
            workerToken: expectation.workerToken, engineDigest: expectation.engineDigest,
            dependencyDigest: expectation.dependencyDigest, bindingDigest: expectation.bindingDigest,
            reviewDigest: expectation.reviewDigest, checkpointDigest: expectation.checkpointDigest) : expectation
        return .init(expectation: result, priorWorker: state)
    }
}
private actor JobGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor JobAuthority: ProvisioningSessionAuthority {
    private var allowed = true
    private var nextGate: JobGate?
    func deny() { allowed = false }
    func pauseNext(_ gate: JobGate) { nextGate = gate }
    func revalidate(_ binding: GuestBinding, dependencyDigest: String) async throws {
        if let gate = nextGate { nextGate = nil; await gate.pause() }
        guard allowed, dependencyDigest == jobDependencies else { throw SequencingFailure.dependencyChanged }
    }
}
private actor JobGuest: ProvisioningGuestAdapter {
    private(set) var commands: [DevVMProvisioningCore.GuestCommand] = []
    private(set) var interrupts: [UUID] = []
    private let gate: JobGate?
    private let pauseAt: GuestOperation?
    private let ignoreInterrupt: Bool
    private let failures: Set<GuestOperation>
    private let observe: (@Sendable (DevVMProvisioningCore.GuestCommand) throws -> Void)?
    init(pauseAt: GuestOperation? = nil, gate: JobGate? = nil, ignoreInterrupt: Bool = false,
         failures: Set<GuestOperation> = [], observe: (@Sendable (DevVMProvisioningCore.GuestCommand) throws -> Void)? = nil) {
        self.pauseAt = pauseAt; self.gate = gate; self.ignoreInterrupt = ignoreInterrupt
        self.failures = failures; self.observe = observe
    }
    func perform(_ command: DevVMProvisioningCore.GuestCommand) async throws -> DevVMProvisioningCore.GuestReply {
        commands.append(command); try observe?(command)
        if command.operation == pauseAt { await gate?.pause() }
        if !ignoreInterrupt, interrupts.contains(command.id) { throw SequencingFailure.cancelled }
        if failures.contains(command.operation) { throw SequencingFailure.adapterFailed }
        let proof: GuestProof
        switch command.operation {
        case .verifyIdentity: proof = .identityVerified
        case .verifyGrantActive: proof = .grantActiveWithoutCachedAuthentication
        case .verifyGrantInactive: proof = .grantInactiveAndCacheCleared
        case .quiesceOwnedWork: proof = .ownedWorkStopped
        case .removePayload: proof = .payloadAbsent
        default: proof = .completed
        }
        return DevVMProvisioningCore.GuestReply(commandID: command.id, jobID: command.context.jobID,
            target: command.context.target, dependencyDigest: command.context.dependencyDigest, proof: proof)
    }
    func interrupt(commandID: UUID, context: GuestJobContext) async {
        interrupts.append(commandID)
        if !ignoreInterrupt { await gate?.release() }
    }
}
private final class FailingJobJournal: ProvisioningJobJournaling, @unchecked Sendable {
    private let base: ProvisioningJobJournal
    private let lock = NSLock()
    private var failing = false
    init(_ base: ProvisioningJobJournal) { self.base = base }
    func failWrites() { lock.withLock { failing = true } }
    func load() throws -> [ProvisioningJobRecord] { try base.load() }
    func close() { base.close() }
    func save(_ records: [ProvisioningJobRecord]) throws {
        guard !lock.withLock({ failing }) else { throw NSError(domain: "fixture-secret-error-never-log", code: 1) }
        try base.save(records)
    }
}
private final class JobPackageAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    func refuse() { lock.withLock { allowed = false } }
    func check() throws {
        guard lock.withLock({ allowed }) else { throw ProvisioningJobFailure.invalidRequest }
    }
}
private final class JobFixture: Sendable {
    let root: URL
    let source: URL
    let plan: SetupPlan
    let profile: VMProfile
    let other: VMProfile
    let runtime: FakeRuntime
    let manager: VMManager
    let target: GuestBinding
    let authority: JobAuthority
    let journal: ProvisioningJobJournal
    let faults: FailingJobJournal
    let artifacts: ProvisioningJobArtifacts
    let recoveryAuthority = JobRecoveryAuthority()
    let coordinator: ProvisioningCoordinator
    let package = JobPackageAdmission()
    init(grace: Duration = .seconds(2), docker: Bool = false, quota: Int = 256 * 1024 * 1024) async throws {
        root = URL(fileURLWithPath: "/private/tmp/provisioning-job-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let features = docker ? "setup: {features: {enable: [cli, docker]}, options: {docker: {access: sudoless}}}" : "setup: {features: {enable: [cli]}}"
        try Data(("schema_version: 1\nid: fixture\n" + features + "\nvars: {private: NEVER-PERSIST-FIXTURE-SECRET}\n").utf8).write(to: source.appendingPathComponent("vm.yml"))
        plan = try SetupPlanner.plan(repository: source)
        profile = VMProfile(id: UUID(), name: "Fixture", clipboardEnabled: false)
        other = VMProfile(id: UUID(), name: "Other fixture", clipboardEnabled: false)
        runtime = FakeRuntime(initialEvents: [.ready])
        manager = VMManager(runtime: runtime, profiles: [profile, other], applicationSupport: root, hostMemoryMiB: 32768, logicalCPUs: 8)
        try await manager.start(profile.id)
        let id = profile.id, localManager = manager
        #expect(await eventually { await localManager.snapshots().first { $0.id == id }?.state == .running })
        let session = try #require(await manager.snapshots().first { $0.id == id }?.sessionID)
        await manager.receiveSSH(.ready(user: "fixture_owner", command: "synthetic-unused"), vmID: id, sessionID: session)
        target = try GuestBinding(vmID: id, sessionID: session, owner: "fixture_owner", ownerUID: 1000, hostKeyDigest: String(repeating: "a", count: 64))
        authority = JobAuthority()
        journal = try ProvisioningJobJournal(directory: root.appendingPathComponent("journal"))
        faults = FailingJobJournal(journal)
        artifacts = try ProvisioningJobArtifacts(directory: root.appendingPathComponent("artifacts"), maximumTotalBytes: quota)
        let admission = package
        coordinator = try await ProvisioningCoordinator.open(manager: manager, journal: faults, authority: authority,
            artifacts: artifacts, recoveryAuthority: recoveryAuthority,
            engineDigest: ProvisioningCoordinator.engineIdentity(plan), cleanupGrace: grace, admitPackage: { try admission.check() })
    }
    deinit {
        for handle in runtime.startedHandles where handle.isRunning { handle.emit(.exited(status: 0)) }
        try? FileManager.default.removeItem(at: root)
    }
    func request(id: UUID = UUID(), check: Bool = false, input: Bool = true) throws -> ProvisioningRequest {
        try ProvisioningRequest(jobID: id, plan: plan, repository: source, target: target, dependencyDigest: jobDependencies,
                                mode: check ? .check : .apply, inputLeaseID: check || !input ? nil : UUID())
    }
    func approve(_ request: ProvisioningRequest) -> ProvisioningApproval {
        .init(reviewIdentity: request.reviewIdentity, customTasksReviewed: true, persistentGrantAcknowledged: true, dockerRootAccessAcknowledged: true)
    }
    func reopen() async throws -> ProvisioningCoordinator {
        try await coordinator.closeForReopen()
        return try await ProvisioningCoordinator.open(manager: manager,
            journal: ProvisioningJobJournal(directory: journal.directory), authority: authority,
            artifacts: ProvisioningJobArtifacts(directory: artifacts.directory), recoveryAuthority: recoveryAuthority,
            engineDigest: ProvisioningCoordinator.engineIdentity(plan), admitPackage: {})
    }
}

@Suite("Provisioning coordinator — fake runtimes and adapters only") struct ProvisioningCoordinatorTests {
    @Test func writeAheadDurabilityAndSanitizedResults() async throws {
        let f = try await JobFixture(), request = try f.request()
        let file = f.journal.directory.appendingPathComponent("jobs.json")
        let guest = JobGuest(observe: { command in
            let data = try PrivateFiles.read(file, maximum: 1024*1024)
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains(command.id.uuidString) && text.contains(command.context.payloadID.uuidString))
            #expect(text.contains("\"cleanupRequired\":true"))
        })
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        let result = try await f.coordinator.wait(request.jobID)
        #expect(result.state == .succeeded && !result.cleanupRequired && !result.workerOutstanding)
        let disk = String(decoding: try PrivateFiles.read(file, maximum: 1024*1024), as: UTF8.self)
        for value in ["NEVER-PERSIST-FIXTURE-SECRET", "fixture_owner", f.root.path, "terminal", "privateKey", "helperPID"] { #expect(!disk.contains(value)) }
        #expect(await f.manager.activeSessionCount == 1)
        #expect(await f.manager.allocatedMemoryMiB == 4096)
        #expect(f.runtime.startedHandles[0].shutdownCount == 0)
        #expect(!FileManager.default.fileExists(atPath: ManagerStorage(applicationSupport: f.root).vms.path))
    }
    @Test func duplicateSubmissionAndSingleJobAdmission() async throws {
        let f = try await JobFixture(), gate = JobGate(), guest = JobGuest(pauseAt: .configureFeatures, gate: gate)
        let request = try f.request()
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        #expect(await eventually { await gate.entered })
        let unused = JobGuest()
        let duplicate = try await f.coordinator.submit(request, approval: f.approve(request), adapter: unused)
        #expect(duplicate.jobID == request.jobID)
        #expect(await unused.commands.isEmpty)
        let competing = try f.request()
        await #expect(throws: ProvisioningJobFailure.busy) { try await f.coordinator.submit(competing, approval: f.approve(competing), adapter: unused) }
        let conflict = try f.request(id: request.jobID, check: true)
        await #expect(throws: ProvisioningJobFailure.jobConflict) { try await f.coordinator.submit(conflict, approval: f.approve(conflict), adapter: unused) }
        await gate.release(); _ = try await f.coordinator.wait(request.jobID)
        let completed = try await f.coordinator.submit(request, approval: f.approve(request), adapter: unused)
        #expect(completed.state == .succeeded)
    }
    @Test func reviewSourceAndDependencyChangesStopBeforeGuestCalls() async throws {
        let f = try await JobFixture(), request = try f.request(), guest = JobGuest()
        await #expect(throws: ProvisioningJobFailure.approvalRequired) {
            try await f.coordinator.submit(request, approval: .init(reviewIdentity: "stale"), adapter: guest)
        }
        await f.authority.deny()
        await #expect(throws: ProvisioningJobFailure.dependencyChanged) { try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest) }
        try Data("changed".utf8).write(to: f.source.appendingPathComponent("vm.yml"))
        await #expect(throws: ProvisioningJobFailure.sourceChanged) { try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest) }
        #expect(await guest.commands.isEmpty)
        #expect(await f.coordinator.statuses().isEmpty)
    }
    @Test func targetChangeAcrossAdmissionAwaitNeverStages() async throws {
        let f = try await JobFixture(), request = try f.request(), guest = JobGuest(), gate = JobGate()
        await f.authority.pauseNext(gate)
        let submission = Task { try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest) }
        #expect(await eventually { await gate.entered })
        f.runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(await eventually { await f.manager.activeSessionCount == 0 })
        await gate.release()
        await #expect(throws: ProvisioningJobFailure.targetChanged) { try await submission.value }
        #expect(await guest.commands.isEmpty)
    }
    @Test func productInterlocksAndOrdinaryShutdownWaitForCleanup() async throws {
        let f = try await JobFixture(), gate = JobGate(), guest = JobGuest(pauseAt: .requestPersistentGrant, gate: gate, ignoreInterrupt: true)
        let request = try f.request()
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        #expect(await eventually { await gate.entered })
        await #expect(throws: VMFailure.self) { try await f.manager.pause(f.profile.id) }
        await #expect(throws: VMFailure.self) { try await f.manager.experimentalSuspend(f.profile.id, confirmed: true) }
        await #expect(throws: VMFailure.self) { try await f.manager.configure(f.profile) }
        await #expect(throws: VMFailure.self) { try await f.manager.deletionRequest(f.profile.id) }
        await #expect(throws: VMFailure.self) { try await f.manager.forceStop(f.profile.id, confirmed: false) }
        await f.manager.shutDown(f.profile.id)
        #expect(await eventually { await f.coordinator.status(request.jobID)?.state == .cancelling })
        #expect(f.runtime.startedHandles[0].shutdownCount == 0)
        await gate.release()
        let result = try await f.coordinator.wait(request.jobID)
        #expect(result.state == .cancelled && !result.cleanupRequired)
        #expect(await eventually { f.runtime.startedHandles[0].shutdownCount == 1 })
        #expect(await guest.commands.contains { $0.operation == .revokeGrant })
        #expect(await f.manager.activeSessionCount == 1)
        #expect(await f.manager.allocatedMemoryMiB == 4096)
        f.runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(await eventually { await f.manager.activeSessionCount == 0 })
    }
    @Test func forceStopKeepsUncertaintyAndMatchingExitOwnership() async throws {
        let f = try await JobFixture(), gate = JobGate(), guest = JobGuest(pauseAt: .configureFeatures, gate: gate, ignoreInterrupt: true)
        let request = try f.request()
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        #expect(await eventually { await gate.entered })
        try await f.manager.forceStop(f.profile.id, confirmed: true)
        #expect(f.runtime.startedHandles[0].terminationCount == 1)
        #expect(await f.manager.activeSessionCount == 1)
        await gate.release()
        let failed = try await f.coordinator.wait(request.jobID)
        #expect(failed.cleanupRequired)
        f.runtime.startedHandles[0].emit(.exited(status: 137))
        #expect(await eventually { await f.manager.activeSessionCount == 0 })
        await #expect(throws: VMFailure.self) { try await f.manager.start(f.profile.id) }
    }
    @Test func viewerCancellationDoesNotCancelJobAndDiagnosticsDoNotReleaseVM() async throws {
        let f = try await JobFixture(), gate = JobGate(), guest = JobGuest(pauseAt: .configureFeatures, gate: gate)
        let request = try f.request()
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        #expect(await eventually { await gate.entered })
        let viewer = Task { try await f.coordinator.wait(request.jobID) }; viewer.cancel()
        f.runtime.startedHandles[0].emit(.error(VMRunError(code: .launchFailed, message: "fixture diagnostic")))
        #expect(await eventually { await f.manager.snapshots()[0].lastFailure != nil })
        #expect(await f.manager.activeSessionCount == 1)
        #expect(await guest.interrupts.isEmpty)
        await gate.release()
        #expect(try await viewer.value.state == .succeeded)
        #expect(await f.manager.activeSessionCount == 1)
    }
    @Test func checkAndRestartRequiredAreNotVMLifecycleActions() async throws {
        let f = try await JobFixture(docker: true), check = try f.request(check: true), guest = JobGuest()
        try await f.coordinator.submit(check, approval: f.approve(check), adapter: guest)
        #expect(try await f.coordinator.wait(check.jobID).state == .checked)
        #expect(await guest.commands.allSatisfy { $0.operation != .requestPersistentGrant && $0.operation != .revokeGrant })
        let apply = try f.request(), applyGuest = JobGuest()
        try await f.coordinator.submit(apply, approval: f.approve(apply), adapter: applyGuest)
        #expect(try await f.coordinator.wait(apply.jobID).state == .restartRequired)
        #expect(f.runtime.startedHandles.count == 1 && f.runtime.startedHandles[0].shutdownCount == 0)
    }
    @Test func liveRecoveryUsesOnlyOriginalTargetAndDoesNotNeedSources() async throws {
        let f = try await JobFixture(), request = try f.request()
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: JobGuest(failures: [.quiesceOwnedWork]))
        let failed = try await f.coordinator.wait(request.jobID)
        #expect(failed.cleanupRequired && failed.engineFailure == nil)
        #expect(failed.cleanupFailures.contains(.adapterFailed))
        let retry = try f.request()
        await #expect(throws: ProvisioningJobFailure.cleanupRequired) { try await f.coordinator.submit(retry, approval: f.approve(retry), adapter: JobGuest()) }
        try FileManager.default.removeItem(at: f.source)
        let recovery = JobGuest()
        try await f.coordinator.recover(request.jobID, adapter: recovery)
        #expect(try await f.coordinator.wait(request.jobID).state == .cleanupConfirmed)
        #expect(await recovery.commands.allSatisfy { $0.plan == nil && $0.inputLeaseID == nil && $0.operation != .stagePayload && $0.operation != .requestPersistentGrant })
    }
    @Test func diskFailureStopsBodyButStillAttemptsRevocation() async throws {
        let f = try await JobFixture(), request = try f.request(), gate = JobGate(), guest = JobGuest(pauseAt: .configureFeatures, gate: gate)
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        #expect(await eventually { await gate.entered })
        f.faults.failWrites(); await gate.release()
        let result = try await f.coordinator.wait(request.jobID)
        #expect(result.cleanupRequired && result.failure == .journalUnavailable)
        #expect(await guest.commands.contains { $0.operation == .revokeGrant })
        #expect(await guest.commands.allSatisfy { $0.operation != .configureRepository })
        let disk = String(decoding: try PrivateFiles.read(f.journal.directory.appendingPathComponent("jobs.json"), maximum: 1024*1024), as: UTF8.self)
        #expect(!disk.contains("fixture-secret-error"))
        #expect(disk.contains("\"cleanupRequired\":true"))
        let next = try f.request()
        await #expect(throws: ProvisioningJobFailure.journalUnavailable) { try await f.coordinator.submit(next, approval: f.approve(next), adapter: JobGuest()) }
    }
    @Test func quitDeadlineRecordsUncertaintyBeforeNormalVMShutdown() async throws {
        let f = try await JobFixture(grace: .milliseconds(40)), request = try f.request(), gate = JobGate()
        let guest = JobGuest(pauseAt: .requestPersistentGrant, gate: gate, ignoreInterrupt: true)
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        #expect(await eventually { await gate.entered })
        #expect(await f.manager.beginApplicationShutdown() == false)
        #expect(await eventually { await f.coordinator.status(request.jobID)?.failure == .cleanupDeadline })
        #expect(await f.coordinator.status(request.jobID)?.workerOutstanding == true)
        #expect(await eventually { f.runtime.startedHandles[0].shutdownCount == 1 })
        #expect(await f.manager.activeSessionCount == 1)
        f.runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(await eventually { await f.manager.isIdle })
        await gate.release()
        #expect(try await f.coordinator.wait(request.jobID).cleanupRequired)
    }
    @Test func reopeningJournalNeverResumesOrReconstructsRecoveryFromMetadata() async throws {
        let f = try await JobFixture(), request = try f.request(), gate = JobGate()
        let guest = JobGuest(pauseAt: .configureFeatures, gate: gate)
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        #expect(await eventually { await gate.entered })
        let directory = f.root.appendingPathComponent("reopened")
        try PrivateFiles.directory(directory, create: true)
        let bytes = try PrivateFiles.read(f.journal.directory.appendingPathComponent("jobs.json"), maximum: 1024*1024)
        try PrivateFiles.write(bytes, name: "jobs.json", in: directory)
        let runtime = FakeRuntime(), manager = VMManager(runtime: runtime, profiles: [f.profile], applicationSupport: f.root)
        let journal = try ProvisioningJobJournal(directory: directory)
        let reopened = try await ProvisioningCoordinator.open(manager: manager, journal: journal, authority: f.authority,
            engineDigest: ProvisioningCoordinator.engineIdentity(f.plan), admitPackage: {})
        #expect(await reopened.status(request.jobID)?.state == .cleanupRequired)
        #expect(await reopened.status(request.jobID)?.failure == .managerRestarted)
        #expect(runtime.startedHandles.isEmpty)
        await #expect(throws: ProvisioningJobFailure.recoveryUnavailable) { try await reopened.recover(request.jobID, adapter: JobGuest()) }
        await #expect(throws: VMFailure.self) { try await manager.start(f.profile.id) }
        await gate.release(); _ = try await f.coordinator.wait(request.jobID)
    }
    @Test func missingInputReturnsAuthorizationRequiredWithoutGuestCalls() async throws {
        let f = try await JobFixture(), request = try f.request(input: false), guest = JobGuest()
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        let result = try await f.coordinator.wait(request.jobID)
        #expect(result.state == .authorizationRequired && !result.cleanupRequired)
        #expect(await guest.commands.isEmpty)
        let reviewed = try f.request()
        try await f.coordinator.submit(reviewed, approval: f.approve(reviewed), adapter: guest)
        #expect(try await f.coordinator.wait(reviewed.jobID).state == .succeeded)
    }
    @Test func failedAdmissionWriteCannotStartEngineOrAnotherJob() async throws {
        let f = try await JobFixture(), request = try f.request(), guest = JobGuest()
        f.faults.failWrites()
        await #expect(throws: ProvisioningJobFailure.journalUnavailable) {
            try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        }
        #expect(await guest.commands.isEmpty)
        #expect(await f.coordinator.status(request.jobID)?.workerOutstanding == false)
        let next = try f.request()
        await #expect(throws: ProvisioningJobFailure.journalUnavailable) {
            try await f.coordinator.submit(next, approval: f.approve(next), adapter: guest)
        }
    }
    @Test(arguments: ["exit", "sleep", "ssh"])
    func unexpectedRuntimeChangesCannotCompleteOrRetargetSetup(kind: String) async throws {
        let f = try await JobFixture(), request = try f.request(), gate = JobGate()
        let guest = JobGuest(pauseAt: .configureFeatures, gate: gate, ignoreInterrupt: true)
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        #expect(await eventually { await gate.entered })
        if kind == "exit" { f.runtime.startedHandles[0].emit(.exited(status: 0)) }
        else if kind == "sleep" { f.runtime.startedHandles[0].emit(.executionState(.init(state: .hostSleeping))) }
        else { await f.manager.receiveSSH(.failed("fixture readiness lost"), vmID: f.profile.id, sessionID: f.target.sessionID) }
        #expect(await eventually { await f.coordinator.status(request.jobID)?.failure == .lifecycleChanged })
        await gate.release()
        #expect(try await f.coordinator.wait(request.jobID).cleanupRequired)
        #expect(await guest.commands.allSatisfy { $0.operation != .configureRepository })
        if kind != "exit" { #expect(await f.manager.activeSessionCount == 1) }
    }
    @Test func changedPackageStopsBodyWithoutSuppressingCleanup() async throws {
        let f = try await JobFixture(), request = try f.request(), gate = JobGate()
        let guest = JobGuest(pauseAt: .configureFeatures, gate: gate)
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        #expect(await eventually { await gate.entered })
        f.package.refuse(); await gate.release()
        let result = try await f.coordinator.wait(request.jobID)
        #expect(result.state == .failed && !result.cleanupRequired)
        #expect(await guest.commands.allSatisfy { $0.operation != .configureRepository })
        #expect(await guest.commands.contains { $0.operation == .revokeGrant })
    }

    @Test func frozenInputsRemainPrivateAndInertAfterSourceRemoval() async throws {
        let f = try await JobFixture(), request = try f.request(), guest = JobGuest()
        let original = try Data(contentsOf: f.source.appendingPathComponent("vm.yml"))
        try Data("unselected sentinel".utf8).write(to: f.source.appendingPathComponent("unselected.txt"))
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        _ = try await f.coordinator.wait(request.jobID)
        try FileManager.default.removeItem(at: f.source)
        let restored = try await f.coordinator.frozenInputs(request.jobID)
        #expect(restored.identity == f.plan.snapshot.identity)
        #expect(restored.data(for: "vm.yml") == original)
        #expect(restored.data(for: "unselected.txt") == nil)
        #expect(String(reflecting: restored) == "FrozenInputsArchive(redacted)")
        for name in try FileManager.default.contentsOfDirectory(atPath: f.artifacts.directory.path) {
            var info = stat()
            #expect(lstat(f.artifacts.directory.appendingPathComponent(name).path, &info) == 0)
            #expect(info.st_mode & 0o7777 == 0o600 && info.st_nlink == 1)
        }
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
    }

    @Test func persistentRecoveryNeedsNoSourcesOrInputArchiveAndCannotResumeApply() async throws {
        let f = try await JobFixture(), request = try f.request(), original = JobGuest(failures: [.quiesceOwnedWork])
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: original)
        #expect(try await f.coordinator.wait(request.jobID).cleanupRequired)
        let payload = try #require(await original.commands.first?.context.payloadID)
        let reopened = try await f.reopen() // Drops every in-memory CleanupTicket and the journal lock.
        try FileManager.default.removeItem(at: f.source)
        try FileManager.default.removeItem(at: f.artifacts.directory.appendingPathComponent(request.jobID.uuidString + ".inputs"))
        await #expect(throws: ProvisioningJobFailure.artifactUnavailable) { _ = try await reopened.frozenInputs(request.jobID) }
        let recovery = JobGuest()
        try await reopened.recover(request.jobID, target: f.target, adapter: recovery)
        #expect(try await reopened.wait(request.jobID).state == .cleanupConfirmed)
        let commands = await recovery.commands
        #expect(!commands.isEmpty && commands.allSatisfy { $0.context.payloadID == payload && $0.plan == nil && $0.inputLeaseID == nil })
        #expect(commands.filter { $0.operation != .verifyIdentity }.map(\.operation) == [.quiesceOwnedWork, .revokeGrant, .clearAuthenticationCache, .verifyGrantInactive, .removePayload])
        #expect(commands.filter { $0.operation == .verifyIdentity }.count == 5)
        #expect(await f.recoveryAuthority.expectations.count == 1)
        #expect(f.runtime.startedHandles.count == 1 && f.runtime.startedHandles[0].shutdownCount == 0)
        await #expect(throws: ProvisioningJobFailure.recoveryUnavailable) { try await f.coordinator.recover(request.jobID, adapter: JobGuest()) }
    }

    @Test(arguments: ["unknown", "running", "challenge", "session", "binding", "authority-change"])
    func persistentRecoveryRequiresFreshExactFencedOwnership(kind: String) async throws {
        let f = try await JobFixture(), request = try f.request()
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: JobGuest(failures: [.quiesceOwnedWork]))
        _ = try await f.coordinator.wait(request.jobID)
        let reopened = try await f.reopen(), guest = JobGuest()
        if kind == "unknown" { await f.recoveryAuthority.deny(.unknown) }
        if kind == "running" { await f.recoveryAuthority.deny(.running) }
        if kind == "challenge" { await f.recoveryAuthority.mismatch() }
        var target = f.target
        if kind == "session" || kind == "binding" {
            target = try GuestBinding(vmID: f.target.vmID, sessionID: kind == "session" ? UUID() : f.target.sessionID,
                owner: "fixture_owner", ownerUID: 1000, hostKeyDigest: String(repeating: "b", count: 64))
        }
        if kind == "authority-change" { await f.authority.deny() }
        let expected: ProvisioningJobFailure = ["session", "binding"].contains(kind) ? .invalidRequest : kind == "authority-change" ? .dependencyChanged : .ownershipUnverified
        await #expect(throws: expected) { try await reopened.recover(request.jobID, target: target, adapter: guest) }
        #expect(await guest.commands.isEmpty)
        #expect(await reopened.status(request.jobID)?.cleanupRequired == true)
        await #expect(throws: VMFailure.self) { try await f.manager.configure(f.profile) }
    }

    @Test func persistentRecoveryRechecksSessionAfterFencingAwait() async throws {
        let f = try await JobFixture(), request = try f.request()
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: JobGuest(failures: [.quiesceOwnedWork]))
        _ = try await f.coordinator.wait(request.jobID)
        let reopened = try await f.reopen(), guest = JobGuest(), gate = JobGate()
        await f.recoveryAuthority.pause(gate)
        let attempt = Task { try await reopened.recover(request.jobID, target: f.target, adapter: guest) }
        #expect(await eventually { await gate.entered })
        f.runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(await eventually { await f.manager.activeSessionCount == 0 })
        await gate.release()
        await #expect(throws: ProvisioningJobFailure.targetChanged) { _ = try await attempt.value }
        #expect(await guest.commands.isEmpty)
    }

    @Test(arguments: ["missing", "tampered", "symlink", "hardlink", "mode", "swapped", "directory"])
    func damagedPersistentCheckpointCannotDelegateCleanup(kind: String) async throws {
        let f = try await JobFixture(), request = try f.request()
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: JobGuest(failures: [.quiesceOwnedWork]))
        _ = try await f.coordinator.wait(request.jobID)
        let reopened = try await f.reopen(), guest = JobGuest()
        let file = f.artifacts.directory.appendingPathComponent(request.jobID.uuidString + ".cleanup")
        if kind == "directory" {
            try FileManager.default.moveItem(at: f.artifacts.directory, to: f.root.appendingPathComponent("old-artifacts"))
            try FileManager.default.copyItem(at: f.root.appendingPathComponent("old-artifacts"), to: f.artifacts.directory)
        }
        else if kind == "mode" { chmod(file.path, 0o644) }
        else if kind == "hardlink" { #expect(link(file.path, f.root.appendingPathComponent("linked").path) == 0) }
        else if kind == "missing" { try FileManager.default.removeItem(at: file) }
        else if kind == "symlink" {
            try FileManager.default.moveItem(at: file, to: f.root.appendingPathComponent("sentinel"))
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: f.root.appendingPathComponent("sentinel"))
        } else if kind == "swapped" {
            let different = try f.request()
            _ = try f.artifacts.prepare(different, payloadID: UUID(), workerToken: UUID(), engineDigest: ProvisioningCoordinator.engineIdentity(f.plan))
            try Data(contentsOf: f.artifacts.directory.appendingPathComponent(different.jobID.uuidString + ".cleanup")).write(to: file)
        } else { try Data("{}".utf8).write(to: file) }
        await #expect(throws: ProvisioningJobFailure.artifactUnavailable) { try await reopened.recover(request.jobID, target: f.target, adapter: guest) }
        #expect(await guest.commands.isEmpty)
        #expect(await reopened.status(request.jobID)?.cleanupRequired == true)
    }

    @Test func damagedInputsStopBodyWithoutSuppressingKnownTargetCleanup() async throws {
        let f = try await JobFixture(), request = try f.request(), gate = JobGate()
        let guest = JobGuest(pauseAt: .configureFeatures, gate: gate)
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest)
        #expect(await eventually { await gate.entered })
        try Data("damaged".utf8).write(to: f.artifacts.directory.appendingPathComponent(request.jobID.uuidString + ".inputs"))
        await gate.release()
        let result = try await f.coordinator.wait(request.jobID)
        #expect(result.state == .failed && !result.cleanupRequired)
        #expect(await guest.commands.allSatisfy { $0.operation != .configureRepository })
        #expect(await guest.commands.contains { $0.operation == .revokeGrant })
    }

    @Test func quotaFailureAndOrphansNeverStartOrReplayWork() async throws {
        let f = try await JobFixture(quota: 0), request = try f.request(), guest = JobGuest()
        await #expect(throws: ProvisioningJobFailure.artifactUnavailable) { try await f.coordinator.submit(request, approval: f.approve(request), adapter: guest) }
        #expect(await f.coordinator.statuses().isEmpty)
        #expect(await guest.commands.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.artifacts.directory.path).isEmpty)
        // A pre-index crash can leave files; opening never imports or replays them.
        let orphan = try await JobFixture(), unindexed = try orphan.request()
        _ = try orphan.artifacts.prepare(unindexed, payloadID: UUID(), workerToken: UUID(), engineDigest: ProvisioningCoordinator.engineIdentity(orphan.plan))
        let reopened = try await orphan.reopen()
        #expect(await reopened.statuses().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: orphan.artifacts.directory.path).count == 2)
        let limited = try ProvisioningJobArtifacts(directory: orphan.artifacts.directory, maximumTotalBytes: 1)
        #expect(throws: ProvisioningJobFailure.artifactUnavailable) {
            _ = try limited.prepare(orphan.request(), payloadID: UUID(), workerToken: UUID(), engineDigest: ProvisioningCoordinator.engineIdentity(orphan.plan))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: orphan.artifacts.directory.path).count == 2)
        #expect(await guest.commands.isEmpty)
    }

    @Test func interruptedDurableMarkerStillRequiresFreshWorkerReconciliation() async throws {
        let f = try await JobFixture(), request = try f.request()
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: JobGuest(failures: [.quiesceOwnedWork]))
        _ = try await f.coordinator.wait(request.jobID)
        try await f.coordinator.closeForReopen()
        // Represent the last fsynced marker from an interrupted fake worker.
        let journal = try ProvisioningJobJournal(directory: f.journal.directory)
        var rows = try journal.load(); rows[0].state = .running; rows[0].workerOutstanding = true; try journal.save(rows)
        let reopened = try await ProvisioningCoordinator.open(manager: f.manager, journal: journal, authority: f.authority,
            artifacts: f.artifacts, recoveryAuthority: f.recoveryAuthority,
            engineDigest: ProvisioningCoordinator.engineIdentity(f.plan), admitPackage: {})
        #expect(await reopened.status(request.jobID)?.failure == .managerRestarted)
        #expect(await reopened.status(request.jobID)?.cleanupRequired == true)
        let guest = JobGuest()
        await f.recoveryAuthority.deny(.running)
        await #expect(throws: ProvisioningJobFailure.ownershipUnverified) { try await reopened.recover(request.jobID, target: f.target, adapter: guest) }
        #expect(await guest.commands.isEmpty)
        await f.recoveryAuthority.deny(.stoppedAndFenced)
        try await reopened.recover(request.jobID, target: f.target, adapter: guest)
        #expect(try await reopened.wait(request.jobID).state == .cleanupConfirmed)
        let expectations = await f.recoveryAuthority.expectations
        #expect(expectations.count == 2 && expectations[0].challenge != expectations[1].challenge)
        #expect(expectations[0].workerToken == expectations[1].workerToken)
    }

    @Test func durableRecoveryWithoutOwnershipChannelFailsClosed() async throws {
        let f = try await JobFixture(), request = try f.request()
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: JobGuest(failures: [.quiesceOwnedWork]))
        _ = try await f.coordinator.wait(request.jobID)
        try await f.coordinator.closeForReopen()
        let reopened = try await ProvisioningCoordinator.open(manager: f.manager,
            journal: ProvisioningJobJournal(directory: f.journal.directory), authority: f.authority, artifacts: f.artifacts,
            engineDigest: ProvisioningCoordinator.engineIdentity(f.plan), admitPackage: {})
        let guest = JobGuest()
        await #expect(throws: ProvisioningJobFailure.ownershipUnverified) { try await reopened.recover(request.jobID, target: f.target, adapter: guest) }
        #expect(await guest.commands.isEmpty)
        #expect(await reopened.status(request.jobID)?.cleanupRequired == true)
    }

    @Test func closingActiveCoordinatorIsRejectedAndRetainsOwnership() async throws {
        let f = try await JobFixture(), request = try f.request(), gate = JobGate()
        try await f.coordinator.submit(request, approval: f.approve(request), adapter: JobGuest(pauseAt: .configureFeatures, gate: gate))
        #expect(await eventually { await gate.entered })
        await #expect(throws: ProvisioningJobFailure.busy) { try await f.coordinator.closeForReopen() }
        await gate.release()
        #expect(try await f.coordinator.wait(request.jobID).state == .succeeded)
    }
}
