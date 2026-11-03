import Darwin
@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

actor EngineFixtureAuthority: ProvisioningSessionAuthority {
    var allowed = true
    func deny() { allowed = false }
    func revalidate(_ binding: GuestBinding, dependencyDigest: String) async throws {
        if !allowed { throw SequencingFailure.dependencyChanged }
    }
}
actor EngineFixtureGuest: ProvisioningGuestAdapter {
    private(set) var commands: [DevVMProvisioningCore.GuestCommand] = []
    private var interrupted = Set<UUID>()
    let gate: IPCWorkerGate?
    let failures: Set<GuestOperation>
    private var runner: ProvisioningFencedProcessRunner?
    let useProcess: Bool
    init(gate: IPCWorkerGate? = nil, failures: Set<GuestOperation> = [], useProcess: Bool = false) {
        self.gate = gate; self.failures = failures; self.useProcess = useProcess
    }
    func install(_ runner: ProvisioningFencedProcessRunner) { self.runner = runner }
    func perform(_ command: DevVMProvisioningCore.GuestCommand) async throws -> DevVMProvisioningCore.GuestReply {
        commands.append(command)
        if command.operation == .configureFeatures {
            await gate?.wait()
            if useProcess, let runner {
                let value = ProvisioningProcessInvocation(id: UUID(), commandID: command.id, context: command.context, purpose: .features,
                    executable: URL(fileURLWithPath: "/nonexistent/fake-only"), arguments: [], environment: [:], workingDirectory: URL(fileURLWithPath: "/private/tmp"),
                    input: .closed, output: .boundedCapture, timeoutSeconds: 1)
                _ = await runner.run(value)
            }
        }
        if interrupted.contains(command.id) { throw SequencingFailure.cancelled }
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
        return .init(commandID: command.id, jobID: command.context.jobID, target: command.context.target, dependencyDigest: command.context.dependencyDigest, proof: proof)
    }
    func interrupt(commandID: UUID, context: GuestJobContext) async { interrupted.insert(commandID); await gate?.release() }
}
actor EngineFixtureFactory: ProvisioningHelperEnginePreparing, ProvisioningDeliveredBackendPreparing {
    let request: ProvisioningRequest
    let approval: ProvisioningApproval
    let guest: EngineFixtureGuest
    let authority: any ProvisioningSessionAuthority
    let backend: IPCRecordingRunner
    let prepareGate: IPCWorkerGate?
    private(set) var prepares = 0
    init(request: ProvisioningRequest, approval: ProvisioningApproval, guest: EngineFixtureGuest, authority: any ProvisioningSessionAuthority,
         backend: IPCRecordingRunner = IPCRecordingRunner(), prepareGate: IPCWorkerGate? = nil) {
        self.request = request; self.approval = approval; self.guest = guest; self.authority = authority; self.backend = backend; self.prepareGate = prepareGate
    }
    func prepare(_ input: ProvisioningValidatedFrozenContext, registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperEngineContext {
        prepares += 1; await prepareGate?.wait()
        let request = input.request
        let runner = try ProvisioningFencedProcessRunner(backend: backend, scope: registration.scope, target: request.target, mode: request.mode)
        await guest.install(runner)
        return .init(request: request, approval: approval, adapter: guest, authority: authority, runner: runner)
    }
    func prepare(_ registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperEngineContext {
        prepares += 1; await prepareGate?.wait()
        let runner = try ProvisioningFencedProcessRunner(backend: backend, scope: registration.scope, target: request.target, mode: request.mode)
        await guest.install(runner)
        return .init(request: request, approval: approval, adapter: guest, authority: authority, runner: runner)
    }
}
/// Local IPC counterpart for manager tests; every backend is fake and no child
/// executable is launched. Preparation precedes the journal; serving begins only
/// at the manager's launch call, and activation has a distinct observe hook.
actor LocalEngineLauncher: ProvisioningHelperDispatching, ProvisioningFrozenHelperLaunching {
    let factory: EngineFixtureFactory
    private let observe: (@Sendable (ProvisioningHelperActivation) throws -> Void)?
    private var ticket: ProvisioningHelperLaunchTicket?
    private var client: ProvisioningHelperIPCClient?
    private var server: ProvisioningHelperIPCServer?
    private var serving: Task<Void, Never>?
    private var credentials: ProvisioningHelperCredentials?
    private var registry: ProvisioningHelperOwnershipRegistry?
    private var delivery: ProvisioningFrozenDeliverySource?
    private var inputParent: URL?
    private(set) var activations = 0
    var loseActivationReply = false
    var corruptStatus = false
    init(factory: EngineFixtureFactory, observe: (@Sendable (ProvisioningHelperActivation) throws -> Void)? = nil) { self.factory = factory; self.observe = observe }
    deinit { client?.disconnect(); server?.stop() }
    func loseReply() { loseActivationReply = true }
    func corruptReply() { corruptStatus = true }
    func prepare(_ original: ProvisioningHelperWorkerRegistration) throws -> ProvisioningHelperLaunchTicket {
        let identity = ProvisioningHelperIdentity(instanceID: UUID(), executableSHA256: String(repeating: "e", count: 64), packageLockSHA256: ProvisioningPackagePin.lockSHA256)
        var registration = original; registration.scope.helperIdentity = identity
        let value = ProvisioningHelperLaunchTicket(id: UUID(), identity: identity, registration: registration)
        ticket = value; credentials = try ProvisioningHelperCredentials(identity: identity, registration: registration)
        registry = try ProvisioningHelperOwnershipRegistry(identity: identity)
        return value
    }
    func prepare(_ original: ProvisioningHelperWorkerRegistration, delivery: ProvisioningFrozenDeliverySource) throws -> ProvisioningHelperLaunchTicket {
        guard original.delivery == delivery.receipt else { throw ProvisioningHelperIPCFailure.authentication }
        let ticket = try prepare(original); self.delivery = delivery; return ticket
    }
    func launch(_ ticket: ProvisioningHelperLaunchTicket) async throws -> ProvisioningHelperRegistrationReceipt {
        guard self.ticket == ticket, let credentials, let registry, client == nil else { throw ProvisioningHelperIPCFailure.ownership }
        var fds = [Int32](repeating: -1, count: 2); guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        let clientSocket = try ProvisioningHelperSocket(taking: fds[0]), serverSocket = try ProvisioningHelperSocket(taking: fds[1])
        var input: ProvisioningValidatedFrozenContext?
        var engineFactory: any ProvisioningHelperEnginePreparing = factory
        if let delivery {
            let parent = URL(fileURLWithPath: "/private/tmp/frozen-helper-test-" + UUID().uuidString)
            try PrivateFiles.directory(parent, create: true); inputParent = parent
            let validated = try ProvisioningValidatedFrozenContext.load(delivery.read(), registration: ticket.registration, parent: parent)
            input = validated; engineFactory = ProvisioningDeliveredEngineFactory(input: validated, backend: factory)
        }
        let server = try ProvisioningHelperIPCServer(socket: serverSocket, credentials: credentials, registry: registry, engineFactory: engineFactory, frozenInput: input)
        let client = ProvisioningHelperIPCClient(socket: clientSocket, credentials: credentials)
        self.server = server; self.client = client; serving = Task { await server.serve() }
        return try await client.awaitRegistration(ticket)
    }
    func dispatch(_ kind: ProvisioningHelperDispatchKind, activation: ProvisioningHelperActivation) async throws -> ProvisioningHelperWorkerSnapshot {
        guard let client else { throw ProvisioningHelperIPCFailure.unavailable }
        if kind == .activate { activations += 1; try observe?(activation) }
        let status = try await client.dispatch(kind, activation: activation)
        if kind == .activate, loseActivationReply { throw ProvisioningHelperIPCFailure.authentication }
        if kind == .status, corruptStatus {
            return .init(activationID: status.activationID, activationDigest: status.activationDigest, sequence: 0, phase: status.phase,
                operation: status.operation, commandID: status.commandID, outcome: status.outcome, primaryFailure: status.primaryFailure,
                cleanupFailures: status.cleanupFailures, cleanupRequired: status.cleanupRequired)
        }
        return status
    }
    func reconcile(_ expectation: ProvisioningRecoveryExpectation) async throws -> ProvisioningRecoveryPermit {
        guard let client else { throw ProvisioningHelperIPCFailure.unavailable }; return try await client.reconcile(expectation)
    }
    func abort(_ activation: ProvisioningHelperActivation) async { client?.disconnect() }
    func abandon(_ ticket: ProvisioningHelperLaunchTicket) async { client?.disconnect() }
    func releaseAfterCleanup(jobID: UUID, helperIdentity: ProvisioningHelperIdentity) async { client?.disconnect() }
    func close() async {
        client?.disconnect(); server?.stop(); await serving?.value
        if let inputParent { try? FileManager.default.removeItem(at: inputParent) }
    }
}
private final class EngineFixture: Sendable {
    let root: URL, request: ProvisioningRequest
    let authority = EngineFixtureAuthority()
    let guest: EngineFixtureGuest
    let factory: EngineFixtureFactory
    let launcher: LocalEngineLauncher
    let ticket: ProvisioningHelperLaunchTicket
    let activation: ProvisioningHelperActivation
    init(mode: ProvisioningMode = .apply, gate: IPCWorkerGate? = nil, prepareGate: IPCWorkerGate? = nil,
         failures: Set<GuestOperation> = [], uncertain: Bool = false) async throws {
        root = URL(fileURLWithPath: "/private/tmp/engine-dispatch-" + UUID().uuidString); try PrivateFiles.directory(root, create: true)
        try Data("schema_version: 1\nid: fixture\nsetup: {features: {enable: [cli]}}\nvars: {private: NEVER-PUBLISH-ENGINE-INPUT}\n".utf8).write(to: root.appendingPathComponent("vm.yml"))
        let plan = try SetupPlanner.plan(repository: root), target = try GuestBinding(vmID: UUID(), sessionID: UUID(), owner: "fixture", ownerUID: 1000, hostKeyDigest: String(repeating: "a", count: 64))
        request = try .init(jobID: UUID(), plan: plan, repository: root, target: target, dependencyDigest: String(repeating: "b", count: 64), mode: mode, inputLeaseID: mode == .apply ? UUID() : nil)
        guest = EngineFixtureGuest(gate: gate, failures: failures, useProcess: uncertain)
        factory = EngineFixtureFactory(request: request, approval: .init(reviewIdentity: request.reviewIdentity, customTasksReviewed: true, persistentGrantAcknowledged: true),
            guest: guest, authority: authority, backend: IPCRecordingRunner(result: uncertain ? .uncertain : .exited), prepareGate: prepareGate)
        launcher = LocalEngineLauncher(factory: factory)
        let scope = ProvisioningRecoveryExpectation(challenge: UUID(), jobID: request.jobID, vmID: target.vmID, sessionID: target.sessionID,
            payloadID: UUID(), workerToken: UUID(), engineDigest: try ProvisioningCoordinator.engineIdentity(plan), dependencyDigest: request.dependencyDigest,
            bindingDigest: try ProvisioningCoordinator.bindingIdentity(target), reviewDigest: request.reviewIdentity, checkpointDigest: String(repeating: "c", count: 64))
        ticket = try await launcher.prepare(.init(scope: scope, planDigest: plan.identity, inputDigest: plan.snapshot.identity, mode: mode))
        _ = try await launcher.launch(ticket)
        activation = .init(activationID: UUID(), registrationDigest: try ticket.registration.digest, scope: ticket.registration.scope,
            customTasksReviewed: true, persistentGrantAcknowledged: true, dockerRootAccessAcknowledged: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func terminal(_ value: ProvisioningHelperActivation? = nil) async throws -> ProvisioningHelperWorkerSnapshot {
        let selected = value ?? activation, end = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < end {
            let status = try await launcher.dispatch(.status, activation: selected)
            if status.terminal { return status }; try await Task.sleep(for: .milliseconds(10))
        }
        throw ProvisioningHelperIPCFailure.timeout
    }
}
@Suite("Helper-side engine dispatch — fake adapters only") struct ProvisioningHelperEngineTests {
    @Test(arguments: [ProvisioningMode.apply, .check])
    func sharedSequencerRunsOnceAndReportsPrivateTypedCompletion(mode: ProvisioningMode) async throws {
        let f = try await EngineFixture(mode: mode)
        _ = try await f.launcher.dispatch(.activate, activation: f.activation)
        _ = try await f.launcher.dispatch(.activate, activation: f.activation)
        let done = try await f.terminal()
        #expect(done.outcome == (mode == .apply ? .applied : .checked) && !done.cleanupRequired)
        #expect(await f.factory.prepares == 1)
        let commands = await f.guest.commands
        #expect(commands.allSatisfy { $0.context.payloadID == f.activation.scope.payloadID && $0.context.target == f.request.target })
        #expect(commands.contains { $0.operation == .requestPersistentGrant } == (mode == .apply))
        let json = String(decoding: try helperJSON(done), as: UTF8.self)
        #expect(!json.contains("NEVER-PUBLISH-ENGINE-INPUT") && !json.contains(f.root.path) && !json.contains("fixture_owner"))
        await f.launcher.close()
    }
    @Test func cancellationKeepsCleanupAndNeverReactivatesTheWorker() async throws {
        let gate = IPCWorkerGate(), f = try await EngineFixture(gate: gate)
        _ = try await f.launcher.dispatch(.activate, activation: f.activation)
        #expect(await eventually { await gate.entered })
        _ = try await f.launcher.dispatch(.cancel, activation: f.activation)
        let done = try await f.terminal(); #expect(done.outcome == .cancelled && !done.cleanupRequired)
        #expect(await f.guest.commands.contains { $0.operation == .revokeGrant })
        let changed = ProvisioningHelperActivation(activationID: UUID(), registrationDigest: f.activation.registrationDigest, scope: f.activation.scope)
        await #expect(throws: ProvisioningHelperDispatchDenial.activationConflict) { _ = try await f.launcher.dispatch(.activate, activation: changed) }
        #expect(await f.factory.prepares == 1); await f.launcher.close()
    }
    @Test func fencingBeforeActivationIsPermanentAndStartsNoFactory() async throws {
        let f = try await EngineFixture()
        #expect(try await f.launcher.reconcile(f.activation.scope).priorWorker == .stoppedAndFenced)
        await #expect(throws: ProvisioningHelperDispatchDenial.fenced) { _ = try await f.launcher.dispatch(.activate, activation: f.activation) }
        #expect(await f.factory.prepares == 0); #expect(await f.guest.commands.isEmpty); await f.launcher.close()
    }
    @Test(arguments: ["source", "consent", "scope"])
    func staleContextOrConsentCannotReachGuestWork(kind: String) async throws {
        let f = try await EngineFixture()
        var activation = f.activation
        if kind == "source" { try Data("changed".utf8).write(to: f.root.appendingPathComponent("vm.yml")) }
        if kind == "consent" { activation.persistentGrantAcknowledged = false }
        if kind == "scope" { activation = .init(activationID: UUID(), registrationDigest: String(repeating: "f", count: 64), scope: activation.scope) }
        if kind == "scope" {
            await #expect(throws: ProvisioningHelperDispatchDenial.ownership) { _ = try await f.launcher.dispatch(.activate, activation: activation) }
        } else {
            _ = try await f.launcher.dispatch(.activate, activation: activation)
            let done = try await f.terminal(activation)
            #expect(done.outcome == (kind == "consent" ? .rejected : .cleanupRequired))
        }
        #expect(await f.guest.commands.isEmpty); await f.launcher.close()
    }
    @Test func localUncertaintyOverridesCleanGuestResultAndRetainsExactRunner() async throws {
        let f = try await EngineFixture(uncertain: true)
        _ = try await f.launcher.dispatch(.activate, activation: f.activation)
        let done = try await f.terminal(); #expect(done.cleanupRequired && done.outcome == .cleanupRequired)
        #expect(try await f.launcher.reconcile(f.activation.scope).priorWorker == .unknown)
        await f.factory.backend.proveCleanup()
        #expect(try await f.launcher.reconcile(f.activation.scope).priorWorker == .stoppedAndFenced)
        #expect(await f.factory.prepares == 1); await f.launcher.close()
    }
    @Test func disconnectDuringPreparationPreventsAllBodyWork() async throws {
        let gate = IPCWorkerGate(), f = try await EngineFixture(prepareGate: gate)
        _ = try await f.launcher.dispatch(.activate, activation: f.activation)
        #expect(await eventually { await gate.entered })
        await f.launcher.abort(f.activation)
        await gate.release(); await f.launcher.close()
        #expect(await f.guest.commands.isEmpty)
    }
}
