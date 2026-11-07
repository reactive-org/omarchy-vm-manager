import Foundation
import Testing
@testable import DevVMProvisioningCore

private let toolPin = String(repeating: "a", count: 64)
private let hostPin = String(repeating: "b", count: 64)

private final class SequenceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let target: GuestBinding
    let plan: SetupPlan
    init(docker: Bool = false, tasks: Bool = false) throws {
        target = try GuestBinding(vmID: UUID(), sessionID: UUID(), owner: "synthetic-owner", ownerUID: 1000, hostKeyDigest: hostPin)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let manifest = "schema_version: 1\nid: fixture\nvm: {packages: ['pkg:jq']}\nsetup:\n  features: {enable: [cli\(docker ? ", docker" : "")]}\n" +
            (docker ? "  options: {docker: {access: sudoless}}\n" : "") +
            (tasks ? "tasks: [{name: custom, file: task.yml}]\n" : "") +
            "vars: {synthetic: synthetic-secret-never-log}\n"
        try Data(manifest.utf8).write(to: root.appendingPathComponent("vm.yml"))
        if tasks { try Data("not even valid YAML: [ {{ synthetic-secret-never-log }}".utf8).write(to: root.appendingPathComponent("task.yml")) }
        plan = try SetupPlanner.plan(repository: root)
    }
    deinit { try? FileManager.default.removeItem(at: root) } // Our disposable UUID fixture only.
    func request(mode: ProvisioningMode = .apply, tasks: [String]? = nil, checkTasks: Bool = false,
                 input: UUID? = UUID(), target: GuestBinding? = nil, pin: String = toolPin) throws -> ProvisioningRequest {
        try ProvisioningRequest(jobID: UUID(), plan: plan, repository: root, target: target ?? self.target,
            dependencyDigest: pin, mode: mode, tasks: tasks, includeTasksInCheck: checkTasks, inputLeaseID: input)
    }
}
private func approval(_ request: ProvisioningRequest, tasks: Bool = true, grant: Bool = true, docker: Bool = true) -> ProvisioningApproval {
    ProvisioningApproval(reviewIdentity: request.reviewIdentity, customTasksReviewed: tasks,
                         persistentGrantAcknowledged: grant, dockerRootAccessAcknowledged: docker)
}

private actor FakeGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withCheckedContinuation { continuation in
            waiting = continuation; entered = true
            for observer in observers { observer.resume() }; observers = []
        }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { waiting?.resume(); waiting = nil }
}
private enum FakeFault: Sendable {
    case fail(SequencingFailure), rawError, wrongTarget(GuestBinding), wrongTools, wrongProtocol, wrongCommand, wrongJob, wrongProof
}
private struct SyntheticAdapterError: Error, CustomStringConvertible {
    var description: String { "synthetic-secret-never-log" }
}
/// The only conformance in the repository. No Process, SSH, Ansible, sockets or VM.
private actor FakeGuest: ProvisioningGuestAdapter {
    private(set) var commands: [GuestCommand] = []
    private(set) var interrupts: [UUID] = []
    private(set) var cancelledCalls: [Bool] = []
    private var faults: [GuestOperation: [FakeFault]]
    private let pauseAt: GuestOperation?
    private let gate: FakeGate?
    private var pausedID: UUID?
    private var interrupted = Set<UUID>()
    private let hook: (@Sendable (GuestCommand) throws -> Void)?
    init(_ faults: [GuestOperation: [FakeFault]] = [:], pauseAt: GuestOperation? = nil, gate: FakeGate? = nil,
         hook: (@Sendable (GuestCommand) throws -> Void)? = nil) {
        self.faults = faults; self.pauseAt = pauseAt; self.gate = gate; self.hook = hook
    }
    func perform(_ command: GuestCommand) async throws -> GuestReply {
        commands.append(command); cancelledCalls.append(Task.isCancelled)
        try hook?(command)
        if pauseAt == command.operation, let gate {
            pausedID = command.id; await gate.pause(); pausedID = nil
            if interrupted.contains(command.id) { throw CancellationError() }
        }
        var target = command.context.target, tools = command.context.dependencyDigest
        var version = 1, commandID = command.id, job = command.context.jobID, proof = command.operation.expectedProof
        if let fault = faults[command.operation]?.first {
            faults[command.operation]!.removeFirst()
            switch fault {
            case .fail(let failure): throw failure
            case .rawError: throw SyntheticAdapterError()
            case .wrongTarget(let value): target = value
            case .wrongTools: tools = String(repeating: "f", count: 64)
            case .wrongProtocol: version = 2
            case .wrongCommand: commandID = UUID()
            case .wrongJob: job = UUID()
            case .wrongProof: proof = .completed
            }
        }
        return GuestReply(protocolVersion: version, commandID: commandID, jobID: job, target: target, dependencyDigest: tools, proof: proof)
    }
    func interrupt(commandID: UUID, context: GuestJobContext) async {
        interrupts.append(commandID)
        if pausedID == commandID { interrupted.insert(commandID); await gate?.release() }
    }
    func operations() -> [GuestOperation] { commands.map(\.operation).filter { $0 != .verifyIdentity } }
}

@Test func applySequenceHasCleanupCoverageAndProofs() async throws {
    let fixture = try SequenceFixture(), request = try fixture.request(), guest = FakeGuest()
    let result = await ProvisioningSequencer().run(request, approval: approval(request), adapter: guest)
    #expect(result.outcome == .appliedRestartRequired); #expect(result.recovery == nil)
    #expect(await guest.operations() == [.stagePayload, .resetGrant, .clearAuthenticationCache, .requestPersistentGrant,
        .verifyGrantActive, .updateSystem, .installManifestPackages, .configureFeatures, .configureRepository,
        .quiesceOwnedWork, .revokeGrant, .clearAuthenticationCache, .verifyGrantInactive, .removePayload])
    let commands = await guest.commands
    for event in result.events {
        #expect(event.jobID == request.jobID && event.vmID == request.target.vmID && event.sessionID == request.target.sessionID)
    }
    for (index, command) in commands.enumerated() where command.operation != .verifyIdentity {
        #expect(index > 0 && commands[index - 1].operation == .verifyIdentity)
        #expect(command.context.target == request.target)
        #expect(command.context.jobID == request.jobID)
        #expect(command.context.payloadID == commands[0].context.payloadID)
        #expect(command.inputLeaseID == (command.operation.interactive ? request.inputLeaseID : nil))
        if command.plan == nil { #expect(command.timeoutSeconds == 30) }
        #expect(result.events.contains { $0.commandID == command.id && $0.kind == .completed })
    }
}

@Test func dockerChecksAfterRevocationAndOnlyRequestsRestart() async throws {
    let fixture = try SequenceFixture(docker: true), request = try fixture.request(), guest = FakeGuest()
    let result = await ProvisioningSequencer().run(request, approval: approval(request), adapter: guest)
    #expect(result.outcome == .appliedRestartRequired)
    let ops = await guest.operations()
    #expect(try #require(ops.firstIndex(of: .verifyGrantInactive)) < #require(ops.firstIndex(of: .verifyOwnerDockerAccess)))
    #expect(ops.filter { $0 == .quiesceOwnedWork }.count == 2)
    #expect(ops.last == .removePayload)
    // There is no restart/launch operation or lifecycle adapter in the protocol.
}

@Test(arguments: [false, true]) func checkNeverChangesAuthorization(checkTasks: Bool) async throws {
    let fixture = try SequenceFixture(docker: true, tasks: true)
    let request = try fixture.request(mode: .check, checkTasks: checkTasks, input: nil), guest = FakeGuest()
    let result = await ProvisioningSequencer().run(request, approval: approval(request, tasks: checkTasks, grant: false, docker: false), adapter: guest)
    #expect(result.outcome == .checked)
    #expect(await guest.operations() == [.stagePayload, .configureFeatures, .configureRepository, .quiesceOwnedWork, .removePayload])
    for command in await guest.commands {
        #expect(command.mode == .check && command.inputLeaseID == nil)
        if command.operation == .configureRepository { #expect(command.tasks == (checkTasks ? ["custom"] : [])) }
    }
}

@Test(arguments: ["digest", "trust", "grant", "docker", "input"]) func preflightRejectsBeforeAnyGuestCall(reason: String) async throws {
    let fixture = try SequenceFixture(docker: true, tasks: true)
    let request = try fixture.request(input: reason == "input" ? nil : UUID()), guest = FakeGuest()
    let a = ProvisioningApproval(reviewIdentity: reason == "digest" ? String(repeating: "0", count: 64) : request.reviewIdentity,
        customTasksReviewed: reason != "trust", persistentGrantAcknowledged: reason != "grant", dockerRootAccessAcknowledged: reason != "docker")
    let result = await ProvisioningSequencer().run(request, approval: a, adapter: guest)
    #expect(result.outcome == (reason == "input" ? .authorizationRequired : .rejected))
    #expect(await guest.commands.isEmpty)
}

@Test(arguments: [GuestOperation.stagePayload, .resetGrant, .requestPersistentGrant, .verifyGrantActive,
                   .installManifestPackages, .configureFeatures, .configureDockerOwnerAccess, .configureRepository])
func failuresAndPartialGrantsCleanUp(operation: GuestOperation) async throws {
    let fixture = try SequenceFixture(docker: true), request = try fixture.request(), guest = FakeGuest([operation: [.fail(.adapterFailed)]])
    let result = await ProvisioningSequencer().run(request, approval: approval(request), adapter: guest)
    #expect(result.outcome == .failed && result.primaryFailure == .adapterFailed && result.recovery == nil)
    let ops = await guest.operations()
    #expect(ops.contains(.quiesceOwnedWork) && ops.last == .removePayload)
    #expect(ops.contains(.revokeGrant) == (operation != .stagePayload))
    #expect(!ops.contains(.verifyOwnerDockerAccess))
}

@Test(arguments: [GuestOperation.quiesceOwnedWork, .verifyGrantInactive, .removePayload])
func cleanupUncertaintyHasSameTargetRecovery(operation: GuestOperation) async throws {
    let fixture = try SequenceFixture(), request = try fixture.request(), guest = FakeGuest([operation: [.fail(.timedOut)]])
    let result = await ProvisioningSequencer().run(request, approval: approval(request), adapter: guest)
    #expect(result.outcome == .cleanupRequired)
    let ticket = try #require(result.recovery), recoveryGuest = FakeGuest()
    #expect(ticket.context.target == request.target)
    let recovered = await ProvisioningSequencer().recover(ticket, adapter: recoveryGuest)
    #expect(recovered.outcome == .cleanupConfirmed)
    for command in await recoveryGuest.commands {
        #expect(command.context == ticket.context && command.plan == nil && command.inputLeaseID == nil)
        #expect([.verifyIdentity, .quiesceOwnedWork, .revokeGrant, .clearAuthenticationCache, .verifyGrantInactive, .removePayload].contains(command.operation))
    }
    if operation == .quiesceOwnedWork {
        #expect(!(await guest.operations()).contains(.removePayload))
        #expect((await recoveryGuest.operations()).contains(.revokeGrant)) // Inactive while work runs is insufficient.
    }
}

@Test func lostRevokeAcknowledgementCanBeReconciledByProof() async throws {
    let fixture = try SequenceFixture(), request = try fixture.request(), guest = FakeGuest([.revokeGrant: [.fail(.timedOut)]])
    let result = await ProvisioningSequencer().run(request, approval: approval(request), adapter: guest)
    #expect(result.outcome == .appliedRestartRequired && result.recovery == nil && result.cleanupFailures == [.timedOut])
}

@Test func sourceChangeDuringGrantStillRevokesWithoutUsingChangedInputs() async throws {
    let fixture = try SequenceFixture(), request = try fixture.request(), source = fixture.root.appendingPathComponent("vm.yml")
    let guest = FakeGuest(hook: { command in
        if command.operation == .requestPersistentGrant { try Data("changed".utf8).write(to: source) }
    })
    let result = await ProvisioningSequencer().run(request, approval: approval(request), adapter: guest)
    #expect(result.primaryFailure == .sourceChanged && result.outcome == .failed)
    let ops = await guest.operations()
    #expect(ops.contains(.revokeGrant) && !ops.contains(.configureFeatures) && ops.last == .removePayload)
}

@Test(arguments: ["vm", "session", "owner", "uid", "key", "tools", "protocol", "command", "job", "proof"])
func mismatchedRepliesNeverAdvanceOrRetarget(kind: String) async throws {
    let fixture = try SequenceFixture(), request = try fixture.request()
    let target = try GuestBinding(vmID: kind == "vm" ? UUID() : fixture.target.vmID,
        sessionID: kind == "session" ? UUID() : fixture.target.sessionID,
        owner: kind == "owner" ? "different-owner" : fixture.target.owner, ownerUID: kind == "uid" ? 1001 : fixture.target.ownerUID,
        hostKeyDigest: kind == "key" ? String(repeating: "c", count: 64) : hostPin)
    let fault: FakeFault
    switch kind {
    case "tools": fault = .wrongTools
    case "protocol": fault = .wrongProtocol
    case "command": fault = .wrongCommand
    case "job": fault = .wrongJob
    case "proof": fault = .wrongProof
    default: fault = .wrongTarget(target)
    }
    // Probe failure after the grant request might mean the grant remains active.
    let guest = FakeGuest([.verifyGrantActive: [fault]])
    let result = await ProvisioningSequencer().run(request, approval: approval(request), adapter: guest)
    #expect(result.outcome == .cleanupRequired && result.recovery != nil)
    let ops = await guest.operations()
    #expect(!ops.contains(.configureFeatures) && !ops.contains(.revokeGrant) && !ops.contains(.removePayload))
}

@Test(arguments: [GuestOperation.requestPersistentGrant, .updateSystem])
func cancellationInterruptsExactCommandThenCleansUncancelled(operation: GuestOperation) async throws {
    let fixture = try SequenceFixture(), request = try fixture.request(), gate = FakeGate()
    let guest = FakeGuest(pauseAt: operation, gate: gate), sequencer = ProvisioningSequencer()
    let task = Task { await sequencer.run(request, approval: approval(request), adapter: guest) }
    await gate.waitForEntry(); task.cancel()
    let result = await task.value
    #expect(result.outcome == .cancelled && result.recovery == nil)
    let commands = await guest.commands, cancellations = await guest.cancelledCalls
    #expect(await guest.interrupts == commands.filter { $0.operation == operation }.map(\.id))
    for (index, command) in commands.enumerated() where command.plan == nil { #expect(!cancellations[index]) }
    #expect((await guest.operations()).contains(.revokeGrant))
    #expect(!(await guest.operations()).contains(.configureFeatures))
}

@Test(arguments: [SequencingFailure.systemUpdateFailed, .timedOut])
func failedUpdateStopsFeatureInstallsAndRetainsCleanupProof(failure: SequencingFailure) async throws {
    let fixture = try SequenceFixture(), request = try fixture.request()
    let guest = FakeGuest([.updateSystem: [.fail(failure)]])
    let result = await ProvisioningSequencer().run(request, approval: approval(request), adapter: guest)
    #expect(result.primaryFailure == failure && result.recovery == nil)
    #expect(result.outcome == (failure == .timedOut ? .timedOut : .failed))
    let ops = await guest.operations()
    #expect(ops.filter { $0 == .updateSystem }.count == 1)
    #expect(!ops.contains(.installManifestPackages) && !ops.contains(.configureFeatures) && !ops.contains(.configureRepository))
    #expect(ops.suffix(5) == [.quiesceOwnedWork, .revokeGrant, .clearAuthenticationCache, .verifyGrantInactive, .removePayload])
}

@Test func uncertainUpdateCleanupCanOnlyRecoverCleanup() async throws {
    let fixture = try SequenceFixture(), request = try fixture.request()
    let guest = FakeGuest([.updateSystem: [.fail(.systemUpdateFailed)], .quiesceOwnedWork: [.fail(.timedOut)]])
    let result = await ProvisioningSequencer().run(request, approval: approval(request), adapter: guest)
    #expect(result.outcome == .cleanupRequired && result.primaryFailure == .systemUpdateFailed)
    #expect(!(await guest.operations()).contains(.removePayload))
    let recovery = FakeGuest()
    let recovered = await ProvisioningSequencer().recover(try #require(result.recovery), adapter: recovery)
    #expect(recovered.outcome == .cleanupConfirmed)
    #expect(!(await recovery.operations()).contains(.updateSystem))
}

@Test func updatePolicyIsVisibleAndOldReviewCannotAuthorizeIt() async throws {
    let fixture = try SequenceFixture(), request = try fixture.request()
    let requirements = try #require(fixture.plan.document.object?["requirements"]?.object)
    #expect(requirements["system_update_required"] == .bool(true))
    #expect(requirements["system_restart_required"] == .bool(true))
    #expect(requirements["update_policy"]?.string?.contains("omarchy update -y") == true)
    let previous = digest(try canonicalData(ManifestValue.object([
        "sequencing_api": .integer(1), "job": .string(request.jobID.uuidString), "plan": .string(request.plan.identity),
        "target": request.target.reviewValue, "dependencies": .string(request.dependencyDigest), "mode": .string(request.mode.rawValue),
        "tasks": .array(request.selectedTasks.map(ManifestValue.string)), "check_tasks": .bool(request.includeTasksInCheck),
        "conflict": .string(request.conflictPolicy.rawValue), "input_lease": request.inputLeaseID.map { .string($0.uuidString) } ?? .null])))
    #expect(previous != request.reviewIdentity)
    let guest = FakeGuest()
    let result = await ProvisioningSequencer().run(request, approval: .init(reviewIdentity: previous, persistentGrantAcknowledged: true), adapter: guest)
    #expect(result.primaryFailure == .approvalRequired)
    #expect(await guest.commands.isEmpty)
    let native = try #require(GuestOperation.updateSystem.nativeInvocation)
    #expect(native.arguments == ["bash", "-lc", "omarchy update -y"])
    #expect(native.requiresInteractiveTerminal && !native.acceptsNonterminalInput)
}

@Test func cancellationDoesNotInterruptCleanupAndConcurrentRunIsRejected() async throws {
    let fixture = try SequenceFixture(docker: true), request = try fixture.request(), gate = FakeGate()
    let guest = FakeGuest(pauseAt: .revokeGrant, gate: gate), sequencer = ProvisioningSequencer()
    let task = Task { await sequencer.run(request, approval: approval(request), adapter: guest) }
    await gate.waitForEntry()
    let duplicate = await sequencer.run(request, approval: approval(request), adapter: guest)
    #expect(duplicate.primaryFailure == .alreadyUsed && duplicate.outcome == .rejected)
    task.cancel(); await sequencer.requestCancellation()
    #expect(await guest.interrupts.isEmpty)
    await gate.release()
    #expect(await task.value.outcome == .cancelled)
    #expect((await guest.operations()).last == .removePayload)
    #expect(!(await guest.operations()).contains(.verifyOwnerDockerAccess))
}

@Test func timeoutAndPrimaryFailureSurviveCleanupFailure() async throws {
    let fixture = try SequenceFixture(), request = try fixture.request()
    let guest = FakeGuest([.configureRepository: [.fail(.timedOut)], .verifyGrantInactive: [.fail(.adapterFailed)]])
    let result = await ProvisioningSequencer().run(request, approval: approval(request), adapter: guest)
    #expect(result.outcome == .cleanupRequired && result.primaryFailure == .timedOut)
    #expect(result.cleanupFailures.contains(.adapterFailed))
}

@Test func publicReportsNeverSerializeBindingsInputsOrAdapterDiagnostics() async throws {
    let fixture = try SequenceFixture(), request = try fixture.request()
    let result = await ProvisioningSequencer().run(request, approval: approval(request), adapter: FakeGuest([
        .configureRepository: [.rawError], .verifyGrantInactive: [.fail(.adapterFailed)]
    ]))
    let encoded = String(decoding: try canonicalData(result), as: UTF8.self)
    for value in ["synthetic-secret-never-log", fixture.target.owner, hostPin, fixture.root.path] { #expect(!encoded.contains(value)) }
    #expect(result.primaryFailure == .adapterFailed)
    #expect(!String(reflecting: fixture.target).contains(hostPin))
    #expect(!encoded.contains("recovery"))
    #expect(!String(reflecting: try #require(result.recovery)).contains(hostPin))
    #expect(!String(reflecting: request).contains(fixture.root.path))
}

@Test func reviewBindsTargetModeTasksDependenciesAndInputLease() throws {
    let fixture = try SequenceFixture(tasks: true), request = try fixture.request()
    for mode in [ProvisioningMode.apply, .check] {
        let changed = try ProvisioningRequest(jobID: request.jobID, plan: request.plan, repository: fixture.root,
            target: request.target, dependencyDigest: toolPin, mode: mode, tasks: [], inputLeaseID: request.inputLeaseID)
        #expect(changed.reviewIdentity != request.reviewIdentity)
    }
    let changedTarget = try GuestBinding(vmID: request.target.vmID, sessionID: UUID(), owner: request.target.owner,
                                        ownerUID: request.target.ownerUID, hostKeyDigest: hostPin)
    for changed in [
        try ProvisioningRequest(jobID: request.jobID, plan: request.plan, repository: fixture.root,
            target: changedTarget, dependencyDigest: toolPin, inputLeaseID: request.inputLeaseID),
        try ProvisioningRequest(jobID: request.jobID, plan: request.plan, repository: fixture.root,
            target: request.target, dependencyDigest: String(repeating: "c", count: 64), inputLeaseID: request.inputLeaseID),
        try ProvisioningRequest(jobID: request.jobID, plan: request.plan, repository: fixture.root,
            target: request.target, dependencyDigest: toolPin, inputLeaseID: UUID()),
        try ProvisioningRequest(jobID: request.jobID, plan: request.plan, repository: fixture.root,
            target: request.target, dependencyDigest: toolPin, conflictPolicy: .backup, inputLeaseID: request.inputLeaseID)
    ] { #expect(changed.reviewIdentity != request.reviewIdentity) }
    #expect(throws: SequencingFailure.self) { try fixture.request(tasks: ["missing"]) }
    #expect(throws: SequencingFailure.self) { try fixture.request(checkTasks: true) }
    #expect(throws: SequencingFailure.self) { try GuestBinding(vmID: UUID(), sessionID: UUID(), owner: "root", ownerUID: 0, hostKeyDigest: hostPin) }
}

@Test func recoveryRefusesRetargetingAndDoesNotNeedOriginalInputs() async throws {
    let fixture = try SequenceFixture(), request = try fixture.request()
    let original = await ProvisioningSequencer().run(request, approval: approval(request), adapter: FakeGuest([.verifyGrantInactive: [.fail(.timedOut)]]))
    let ticket = try #require(original.recovery)
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("vm.yml"))
    let changedSession = try GuestBinding(vmID: request.target.vmID, sessionID: UUID(), owner: request.target.owner,
                                         ownerUID: request.target.ownerUID, hostKeyDigest: hostPin)
    let wrongGuest = FakeGuest([.verifyIdentity: [.wrongTarget(changedSession)]])
    let rejected = await ProvisioningSequencer().recover(ticket, adapter: wrongGuest)
    #expect(rejected.outcome == .cleanupRequired)
    #expect(await wrongGuest.operations().isEmpty)
    let correctGuest = FakeGuest()
    let recovered = await ProvisioningSequencer().recover(ticket, adapter: correctGuest)
    #expect(recovered.outcome == .cleanupConfirmed)
    #expect(!(await correctGuest.operations()).contains(.requestPersistentGrant))
}

@Test func preflightSourceAndIdentityFailuresNeverMutateGuest() async throws {
    let fixture = try SequenceFixture(), request = try fixture.request(), guest = FakeGuest()
    let wrong = try GuestBinding(vmID: UUID(), sessionID: request.target.sessionID, owner: request.target.owner,
                                ownerUID: request.target.ownerUID, hostKeyDigest: hostPin)
    let wrongGuest = FakeGuest([.verifyIdentity: [.wrongTarget(wrong)]])
    let identityFailure = await ProvisioningSequencer().run(request, approval: approval(request), adapter: wrongGuest)
    #expect(identityFailure.primaryFailure == .identityMismatch && identityFailure.recovery == nil)
    #expect(await wrongGuest.operations().isEmpty)
    try Data("changed".utf8).write(to: fixture.root.appendingPathComponent("vm.yml"))
    let sourceFailure = await ProvisioningSequencer().run(request, approval: approval(request), adapter: guest)
    #expect(sourceFailure.primaryFailure == .sourceChanged)
    #expect(await guest.commands.isEmpty)
}

@Test func postRevokeCheckFailureStillQuiescesAndRemovesPayload() async throws {
    let fixture = try SequenceFixture(docker: true), request = try fixture.request()
    let guest = FakeGuest([.verifyOwnerDockerAccess: [.fail(.adapterFailed)]])
    let result = await ProvisioningSequencer().run(request, approval: approval(request), adapter: guest)
    #expect(result.outcome == .failed && result.recovery == nil && result.primaryFailure == .adapterFailed)
    let operations = await guest.operations()
    #expect(operations.suffix(3) == [.verifyOwnerDockerAccess, .quiesceOwnedWork, .removePayload])
    #expect(try #require(operations.firstIndex(of: .verifyGrantInactive)) < #require(operations.firstIndex(of: .verifyOwnerDockerAccess)))
}

@Test func nativeGrantContractUsesGuestLoginShellAndNeverAutomatesPasswords() throws {
    let grant = try #require(GuestOperation.requestPersistentGrant.nativeInvocation)
    #expect(grant.arguments == ["bash", "-lc", "omarchy sudo passwordless permanent"])
    #expect(grant.requiresInteractiveTerminal && !grant.acceptsNonterminalInput)
    let revoked = try #require(GuestOperation.verifyGrantInactive.nativeInvocation)
    #expect(revoked.arguments == ["bash", "-lc", "omarchy sudo passwordless --disable && sudo -K && if omarchy sudo passwordless --active; then exit 1; else test \"$?\" -eq 1; fi"])
    #expect(!revoked.requiresInteractiveTerminal && !revoked.acceptsNonterminalInput)
    let active = try #require(GuestOperation.verifyGrantActive.nativeInvocation)
    #expect(active.arguments.last == "omarchy sudo passwordless --active && sudo -kn true")
    let docker = try #require(GuestOperation.configureDockerOwnerAccess.nativeInvocation)
    #expect(docker.requiresInteractiveTerminal && docker.arguments.last!.contains("OMARCHY_DEFER_REBOOT=1"))
    for operation in GuestOperation.allCases {
        if let invocation = operation.nativeInvocation {
            #expect(invocation.arguments.prefix(2) == ["bash", "-lc"])
            #expect(!invocation.acceptsNonterminalInput && !invocation.arguments.joined().contains("sudo -S"))
        }
    }
}

@Test func interactivePromptsShareTheSetupDeadline() {
    // Omarchy's passwordless-sudo and Docker owner prompts may wait for the
    // owner, so they get the same deadline as other setup operations.
    #expect(GuestOperation.requestPersistentGrant.bodyTimeoutSeconds == 3600)
    #expect(GuestOperation.configureDockerOwnerAccess.bodyTimeoutSeconds == 3600)
    #expect(GuestOperation.updateSystem.bodyTimeoutSeconds == 3600)
    #expect(GuestOperation.verifyIdentity.bodyTimeoutSeconds == 10)
    #expect(GuestOperation.verifyGrantActive.bodyTimeoutSeconds == 30)
}
