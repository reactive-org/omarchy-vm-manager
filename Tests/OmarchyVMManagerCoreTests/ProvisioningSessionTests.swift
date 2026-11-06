import Darwin
@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

let sessionFixtureHostKey = Data([0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32] + Array(repeating: UInt8(42), count: 32))
let sessionFixtureHostKeyDigest = KitVerifier.sha256(sessionFixtureHostKey)
func sessionFixtureSockets(timeout: Duration = .seconds(3)) throws -> (ProvisioningHelperSocket, ProvisioningHelperSocket) {
    var fds = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
    return try (ProvisioningHelperSocket(taking: fds[0], timeout: timeout), ProvisioningHelperSocket(taking: fds[1], timeout: timeout))
}
actor SessionFixtureRunner: ProvisioningProcessRunner, ProvisioningLocalCleanupReconciling {
    private(set) var invocations: [ProvisioningProcessInvocation] = []
    private(set) var interrupts: [UUID] = []
    let gate: IPCWorkerGate?
    private let uncertainFeatures: Bool
    private var cleanupProved = false
    private var interrupted = Set<UUID>()
    init(gate: IPCWorkerGate? = nil, uncertainFeatures: Bool = false) { self.gate = gate; self.uncertainFeatures = uncertainFeatures }
    func run(_ invocation: ProvisioningProcessInvocation) async -> ProvisioningProcessResult {
        invocations.append(invocation)
        if invocation.purpose == .features { await gate?.wait(); if uncertainFeatures { return .init(invocationID: invocation.id, termination: .cleanupUnconfirmed) } }
        var object: [String: Any] = ["protocol": 1, "job": invocation.context.jobID.uuidString.lowercased(), "payload": invocation.context.payloadID.uuidString.lowercased(), "uid": invocation.context.target.ownerUID]
        switch invocation.purpose {
        case .identity: object = ["uid": invocation.context.target.ownerUID, "owner": invocation.context.target.owner, "system": "Linux", "architecture": "aarch64"]
        case .bootstrap: object["state"] = "staged"
        case .preparePayload: object["state"] = "ready"
        case .quiesce: object["state"] = "quiescent"
        case .remove: object["state"] = "absent"
        default: object = [:]
        }
        var stdout = object.isEmpty ? Data() : try! JSONSerialization.data(withJSONObject: object)
        if invocation.purpose == .native, invocation.arguments.last?.contains("docker.sock") == true { stdout = Data("fixture-version".utf8) }
        let reason: ProvisioningExitReason = interrupted.contains(invocation.id) ? .cancelled : .normal
        return .init(invocationID: invocation.id, termination: .exited(status: interrupted.contains(invocation.id) ? 143 : 0, reason: reason), stdout: stdout)
    }
    func interrupt(invocationID: UUID) async { interrupts.append(invocationID); interrupted.insert(invocationID); await gate?.release() }
    func proveCleanup() { cleanupProved = true }
    func reconcileLocalCleanup(invocationID: UUID) -> Bool { cleanupProved && invocations.contains { $0.id == invocationID } }
}
final class SessionFixtureProvider: ProvisioningHelperTransportProviding, @unchecked Sendable {
    let root: URL
    let runner: SessionFixtureRunner
    let tools: ProvisioningTransportTools
    let identity: ProvisioningIdentityFile
    let wrongBinding: Bool, wrongDependencies: Bool
    private let lock = NSLock()
    private var factoryCount = 0, resourceCount = 0
    var builds: Int { lock.withLock { factoryCount } }
    var preparations: Int { lock.withLock { resourceCount } }
    init(runner: SessionFixtureRunner = SessionFixtureRunner(), wrongBinding: Bool = false, wrongDependencies: Bool = false) throws {
        self.runner = runner; self.wrongBinding = wrongBinding; self.wrongDependencies = wrongDependencies
        root = URL(fileURLWithPath: "/private/tmp/session-provider-" + UUID().uuidString)
        try PrivateFiles.directory(root, create: true)
        let key = root.appendingPathComponent("synthetic-identity").standardizedFileURL; try Data("not-a-credential".utf8).write(to: key); chmod(key.path, 0o600)
        identity = try ProvisioningIdentityFile(key.standardizedFileURL)
        let directory = root
        func pin(_ name: String) throws -> ProvisioningExecutablePin {
            let url = directory.appendingPathComponent(name).standardizedFileURL; try Data("fixture-only-never-execute".utf8).write(to: url); chmod(url.path, 0o700)
            return try ProvisioningExecutablePin(url.standardizedFileURL)
        }
        tools = try .init(ssh: pin("ssh"), scp: pin("scp"), sftp: pin("sftp"), ansiblePlaybook: pin("ansible-playbook"), ansibleInventory: pin("ansible-inventory"))
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func makeAdmittedRunner() -> any ProvisioningProcessRunner { lock.withLock { factoryCount += 1 }; return runner }
    func admittedReport() throws -> ProvisioningToolReport {
        for name in ["brew", "bash"] {
            let url = root.appendingPathComponent(name)
            if !PrivateFiles.exists(url) { try Data("fixture-only-never-execute".utf8).write(to: url); chmod(url.path, 0o700) }
        }
        let bin = root.appendingPathComponent("bin"); try PrivateFiles.directory(bin, create: true)
        for name in ["ansible-playbook", "ansible-inventory"] {
            let url = bin.appendingPathComponent(name)
            if !PrivateFiles.exists(url) { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent(name)) }
        }
        let files = LocalProvisioningToolFiles(), installation = try #require(files.directory(root.path)).identity
        let values = try ProvisioningTransportToolAdmission.required.map { tool -> ProvisioningToolResult in
            let path = root.appendingPathComponent([ProvisioningTool.ansiblePlaybook, .ansibleInventory].contains(tool) ? "bin/" + tool.rawValue : tool.rawValue)
            let executable = try #require(files.executable(path.path)).identity
            let ansible = [ProvisioningTool.ansiblePlaybook, .ansibleInventory].contains(tool)
            return .init(tool: tool, status: .available,
                version: ansible ? "2.21.5" : tool == .brew ? "7.0.0" : tool == .bash ? "3.2.57" : tool == .ssh ? "10.3p1" : nil,
                executable: executable, provider: ansible ? "homebrew" : tool == .brew ? "host" : "macOS", reason: "Synthetic local fixture", installation: ansible ? installation : nil)
        }
        return .init(tools: values)
    }
    func resources(for input: ProvisioningValidatedFrozenContext, registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperTransportResources {
        lock.withLock { resourceCount += 1 }
        let target = input.request.target
        let binding = try wrongBinding ? GuestBinding(vmID: UUID(), sessionID: target.sessionID, owner: target.owner, ownerUID: target.ownerUID, hostKeyDigest: target.hostKeyDigest) : target
        let connection = try ProvisioningSSHConnection(binding: binding, port: 22222, identity: identity, ed25519HostKey: sessionFixtureHostKey)
        return .init(connection: connection, tools: tools, dependencyDigest: wrongDependencies ? String(repeating: "e", count: 64) : input.request.dependencyDigest,
            makeProcessRunner: { [self] in lock.withLock { factoryCount += 1 }; return runner })
    }
}
actor SessionFixtureChecks {
    private(set) var requests: [ProvisioningSessionRequest] = []
    var gate: IPCWorkerGate?
    var decision: ProvisioningSessionDecision = .allowed
    var beforeFeatures: (@Sendable () async -> Void)?
    func deny(_ value: ProvisioningSessionDecision) { decision = value }
    func pause(_ gate: IPCWorkerGate) { self.gate = gate }
    func interceptFeatures(_ hook: @escaping @Sendable () async -> Void) { beforeFeatures = hook }
    func check(_ request: ProvisioningSessionRequest) async throws {
        requests.append(request)
        if request.boundary == .invocation, request.operation == .configureFeatures, let hook = beforeFeatures { beforeFeatures = nil; await hook() }
        if request.boundary == .invocation, request.operation == .configureFeatures, let gate { self.gate = nil; await gate.wait() }
        switch decision {
        case .allowed: return
        case .bodyStopped: if !request.cleanup { throw SequencingFailure.cancelled }
        case .targetChanged: throw SequencingFailure.identityMismatch
        case .unavailable: throw ProvisioningHelperIPCFailure.unavailable
        }
    }
}
/// No child process or executable is started. Both directions use actual local
/// framed/MACed sockets, while the adapter receives only the fake process runner.
actor LocalTransportLauncher: ProvisioningServiceLaunching {
    let provider: SessionFixtureProvider
    let checks = SessionFixtureChecks()
    let bypassGuest = EngineFixtureGuest()
    let bypassAuthority: Bool
    let processRunner: (any ProvisioningProcessRunner)?
    let executionAdmission: ProvisioningExecutionAdmission
    private var ticket: ProvisioningHelperLaunchTicket?
    private var credentials: ProvisioningHelperCredentials?
    private var delivery: ProvisioningFrozenDeliverySource?
    private var transportHandoff: ProvisioningTransportHandoff?
    private var client: ProvisioningHelperIPCClient?
    private var controlServer: ProvisioningHelperIPCServer?
    private var sessionServer: ProvisioningManagerSessionServer?
    private var sessionClient: ProvisioningSessionClient?
    private var controlTask: Task<Void, Never>?, sessionTask: Task<Void, Never>?
    private var parent: URL?
    private var helperExited = false
    private(set) var activations = 0
    init(provider: SessionFixtureProvider, bypassAuthority: Bool = false, processRunner: (any ProvisioningProcessRunner)? = nil, executionAdmission: ProvisioningExecutionAdmission = .fixture) { self.provider = provider; self.bypassAuthority = bypassAuthority; self.processRunner = processRunner; self.executionAdmission = executionAdmission }
    func prepare(_ registration: ProvisioningHelperWorkerRegistration) throws -> ProvisioningHelperLaunchTicket { throw ProvisioningJobFailure.invalidRequest }
    func prepare(_ original: ProvisioningHelperWorkerRegistration, delivery: ProvisioningFrozenDeliverySource) throws -> ProvisioningHelperLaunchTicket {
        guard original.sessionAuthorityVersion == 1 else { throw ProvisioningJobFailure.invalidRequest }
        let identity = ProvisioningHelperIdentity(instanceID: UUID(), executableSHA256: String(repeating: "e", count: 64), packageLockSHA256: ProvisioningPackagePin.lockSHA256)
        var registration = original; registration.scope.helperIdentity = identity
        let ticket = ProvisioningHelperLaunchTicket(id: UUID(), identity: identity, registration: registration)
        credentials = try .init(identity: identity, registration: registration); self.ticket = ticket; self.delivery = delivery; return ticket
    }
    func prepare(_ original: ProvisioningHelperWorkerRegistration, delivery: ProvisioningFrozenDeliverySource, transport: ProvisioningTransportHandoff) throws -> ProvisioningHelperLaunchTicket {
        try transport.verify(original)
        let ticket = try prepare(original, delivery: delivery); transportHandoff = transport; return ticket
    }
    func launch(_ ticket: ProvisioningHelperLaunchTicket) async throws -> ProvisioningHelperRegistrationReceipt {
        guard self.ticket == ticket, let credentials, let delivery, client == nil else { throw ProvisioningHelperIPCFailure.ownership }
        let parent = URL(fileURLWithPath: "/private/tmp/session-input-" + UUID().uuidString); self.parent = parent; try PrivateFiles.directory(parent, create: true)
        let input = try ProvisioningValidatedFrozenContext.load(delivery.read(), registration: ticket.registration, parent: parent)
        let (managerControl, helperControl) = try sessionFixtureSockets(), (helperSession, managerSession) = try sessionFixtureSockets()
        let sessionServer = try ProvisioningManagerSessionServer(socket: managerSession, credentials: credentials)
        let sessionClient = ProvisioningSessionClient(socket: helperSession, credentials: credentials)
        self.sessionServer = sessionServer; self.sessionClient = sessionClient
        sessionTask = Task { await sessionServer.serve() }
        let admitted = try transportHandoff.map { try ProvisioningValidatedTransport.load($0.bytes, registration: ticket.registration, input: input, policy: .fixture(provider.root)) }
        let backend: any ProvisioningDeliveredBackendPreparing
        if let admitted { backend = ProvisioningHelperTransportBackend(provider: ProvisioningDeliveredTransportProvider(transport: admitted, makeProcessRunner: { [provider, processRunner] in processRunner ?? provider.makeAdmittedRunner() }), client: sessionClient, admitPackage: {}, executionAdmission: executionAdmission) }
        else if bypassAuthority { backend = EngineFixtureFactory(request: input.request, approval: input.approval, guest: bypassGuest, authority: EngineFixtureAuthority()) }
        else { backend = ProvisioningHelperTransportBackend(provider: provider, client: sessionClient, admitPackage: {}, executionAdmission: executionAdmission) }
        let factory = ProvisioningDeliveredEngineFactory(input: input, backend: backend)
        let registry = try ProvisioningHelperOwnershipRegistry(identity: credentials.identity)
        let server = try ProvisioningHelperIPCServer(socket: helperControl, credentials: credentials, registry: registry,
            engineFactory: factory, frozenInput: input, transport: admitted, sessionConnected: { sessionClient.connected })
        client = ProvisioningHelperIPCClient(socket: managerControl, credentials: credentials); controlServer = server
        controlTask = Task { await server.serve(); self.recordExit() }; return try await client!.awaitRegistration(ticket)
    }
    func bindSessionAuthority(_ activation: ProvisioningHelperActivation, check: @escaping ProvisioningManagerSessionCheck) async throws {
        guard let sessionServer else { throw ProvisioningHelperIPCFailure.unavailable }
        let checks = checks
        try await sessionServer.bind(activation) { request in try await checks.check(request); try await check(request) }
    }
    func dispatch(_ kind: ProvisioningHelperDispatchKind, activation: ProvisioningHelperActivation) async throws -> ProvisioningHelperWorkerSnapshot {
        guard let client else { throw ProvisioningHelperIPCFailure.unavailable }
        if kind == .activate { activations += 1 }
        return try await client.dispatch(kind, activation: activation)
    }
    func reconcile(_ scope: ProvisioningRecoveryExpectation) async throws -> ProvisioningRecoveryPermit {
        guard let client else { throw ProvisioningHelperIPCFailure.unavailable }; return try await client.reconcile(scope)
    }
    func breakSessionChannel() { sessionServer?.stop() }
    func abort(_ activation: ProvisioningHelperActivation) async { client?.disconnect(); sessionServer?.stop() }
    func abandon(_ ticket: ProvisioningHelperLaunchTicket) async { client?.disconnect(); sessionServer?.stop() }
    func releaseAfterCleanup(jobID: UUID, helperIdentity: ProvisioningHelperIdentity) async { client?.disconnect(); sessionServer?.stop() }
    private func recordExit() { helperExited = true }
    func waitForExit(jobID: UUID, identity: ProvisioningHelperIdentity, timeout: Duration) async -> Bool {
        guard ticket?.registration.scope.jobID == jobID, ticket?.identity == identity else { return false }
        let end = ContinuousClock.now + timeout
        while !helperExited, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
        return helperExited
    }
    func close() async {
        client?.disconnect(); sessionServer?.stop(); await controlTask?.value; await sessionTask?.value
        if let parent { try? FileManager.default.removeItem(at: parent) }
    }
}

private func sessionRegistration() throws -> (ProvisioningHelperCredentials, ProvisioningHelperWorkerRegistration) {
    let identity = ProvisioningHelperIdentity(instanceID: UUID(), executableSHA256: String(repeating: "e", count: 64), packageLockSHA256: ProvisioningPackagePin.lockSHA256)
    var scope = try helperTestExpectation(); scope.helperIdentity = identity
    let pin = String(repeating: "b", count: 64)
    let receipt = ProvisioningFrozenDeliveryReceipt(format: 1, sha256: pin, byteCount: 100, metadataSHA256: pin, archiveSHA256: pin)
    let registration = ProvisioningHelperWorkerRegistration(scope: scope, planDigest: pin, inputDigest: pin, mode: .apply, delivery: receipt, sessionAuthorityVersion: 1)
    return (try .init(identity: identity, registration: registration), registration)
}
private func sessionQuery(_ registration: ProvisioningHelperWorkerRegistration, cleanup: Bool = false) throws -> ProvisioningSessionRequest {
    .init(requestID: UUID(), registrationDigest: try registration.digest, scope: registration.scope,
          boundary: cleanup ? .command : .preparation, mode: registration.mode, cleanup: cleanup,
          commandID: cleanup ? UUID() : nil, operation: cleanup ? .revokeGrant : nil, invocationID: nil, purpose: nil)
}
@Suite("Manager session authority — private local channels only") struct ProvisioningSessionTests {
    @Test func bootstrapFourIsStrictAndSessionMACsCannotCrossTheControlChannel() throws {
        let (credentials, registration) = try sessionRegistration()
        let data = try credentials.privateBootstrap(), restored = try ProvisioningHelperCredentials(privateBootstrap: data)
        #expect(restored.registration == registration)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["version"] as? Int == 4)
        object["version"] = 3
        #expect(throws: Error.self) { _ = try ProvisioningHelperCredentials(privateBootstrap: JSONSerialization.data(withJSONObject: object)) }
        var control = ProvisioningHelperFrameCodec(credentials: credentials, role: .helper)
        var receiver = ProvisioningHelperFrameCodec(credentials: credentials.sessionCredentials(), role: .manager)
        let body = try helperJSON(sessionQuery(registration)), wrong = try control.encode(body)
        #expect(throws: ProvisioningHelperIPCFailure.authentication) { _ = try receiver.decode(wrong) }
        var session = ProvisioningHelperFrameCodec(credentials: credentials.sessionCredentials(), role: .helper)
        let frame = try session.encode(body)
        #expect(try receiver.decode(frame) == body)
        #expect(throws: ProvisioningHelperIPCFailure.authentication) { _ = try receiver.decode(frame) }
    }
    @Test func aBindingIsOneShotAndBodyRevocationStillAllowsFreshCleanup() async throws {
        let (credentials, registration) = try sessionRegistration(), (helper, manager) = try sessionFixtureSockets()
        let server = try ProvisioningManagerSessionServer(socket: manager, credentials: credentials)
        let task = Task { await server.serve() }, client = ProvisioningSessionClient(socket: helper, credentials: credentials), checks = SessionFixtureChecks()
        await #expect(throws: SequencingFailure.adapterFailed) { try await client.authorize(sessionQuery(registration)) }
        let activation = ProvisioningHelperActivation(activationID: UUID(), registrationDigest: try registration.digest, scope: registration.scope)
        try await server.bind(activation) { try await checks.check($0) }
        try await client.authorize(sessionQuery(registration))
        await checks.deny(.bodyStopped)
        await #expect(throws: SequencingFailure.cancelled) { try await client.authorize(sessionQuery(registration)) }
        try await client.authorize(sessionQuery(registration, cleanup: true))
        let changed = ProvisioningHelperActivation(activationID: UUID(), registrationDigest: try registration.digest, scope: registration.scope)
        await #expect(throws: ProvisioningHelperIPCFailure.ownership) { try await server.bind(changed) { _ in } }
        #expect(await checks.requests.count == 3)
        client.stop(); server.stop(); await task.value
    }
    @Test(arguments: ["nonce", "mac", "timeout", "truncated"])
    func aBadOrLostReplyPermanentlyPoisonsTheAuthorityChannel(kind: String) async throws {
        let (credentials, registration) = try sessionRegistration(), (helper, manager) = try sessionFixtureSockets(timeout: .milliseconds(150))
        let request = try sessionQuery(registration), client = ProvisioningSessionClient(socket: helper, credentials: credentials)
        let task = Task { try? await helperBlocking {
            var codec = ProvisioningHelperFrameCodec(credentials: credentials.sessionCredentials(), role: .manager)
            _ = try codec.decode(manager.receive())
            if kind == "timeout" { return }
            if kind == "truncated" { manager.stop(); return }
            let selected = kind == "nonce" ? try sessionQuery(registration) : request
            if kind == "mac" { codec = .init(credentials: credentials, role: .manager) }
            try manager.send(codec.encode(helperJSON(ProvisioningSessionResponse(request: selected, decision: .allowed))))
        } }
        await #expect(throws: ProvisioningHelperIPCFailure.authentication) { try await client.authorize(request) }
        await #expect(throws: ProvisioningHelperIPCFailure.authentication) { try await client.authorize(sessionQuery(registration, cleanup: true)) }
        client.stop(); manager.stop(); await task.value
    }
    @Test(arguments: ["scope", "mode", "unknown", "null", "cleanup-grant", "purpose"])
    func malformedOrCrossWorkerQueriesCannotReachTheManagerCheck(kind: String) async throws {
        let (credentials, registration) = try sessionRegistration(), (helper, manager) = try sessionFixtureSockets(timeout: .milliseconds(200))
        let server = try ProvisioningManagerSessionServer(socket: manager, credentials: credentials), checks = SessionFixtureChecks()
        let activation = ProvisioningHelperActivation(activationID: UUID(), registrationDigest: try registration.digest, scope: registration.scope)
        try await server.bind(activation) { try await checks.check($0) }
        let task = Task { await server.serve() }
        var object = try JSONSerialization.jsonObject(with: helperJSON(sessionQuery(registration))) as! [String: Any]
        if kind == "scope" { var scope = object["scope"] as! [String: Any]; scope["workerToken"] = UUID().uuidString; object["scope"] = scope }
        if kind == "mode" { object["mode"] = "check" }
        if kind == "unknown" { object["command"] = "never-execute" }
        if kind == "null" { object["commandID"] = NSNull() }
        if kind == "cleanup-grant" { object["boundary"] = "command"; object["cleanup"] = true; object["commandID"] = UUID().uuidString; object["operation"] = "requestPersistentGrant" }
        if kind == "purpose" { object["boundary"] = "invocation"; object["commandID"] = UUID().uuidString; object["operation"] = "revokeGrant"; object["invocationID"] = UUID().uuidString; object["purpose"] = "bootstrap"; object["cleanup"] = true }
        var codec = ProvisioningHelperFrameCodec(credentials: credentials.sessionCredentials(), role: .helper)
        try helper.send(codec.encode(JSONSerialization.data(withJSONObject: object)))
        await #expect(throws: Error.self) { _ = try await helperBlocking { try helper.receive() } }
        #expect(await checks.requests.isEmpty)
        helper.stop(); server.stop(); await task.value
    }
}
