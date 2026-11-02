import Darwin
@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

func helperTestExpectation(record: ProvisioningJobRecord? = nil, target: GuestBinding? = nil) throws -> ProvisioningRecoveryExpectation {
    let target = try target ?? GuestBinding(vmID: UUID(), sessionID: UUID(), owner: "fixture", ownerUID: 1000, hostKeyDigest: String(repeating: "a", count: 64))
    return .init(challenge: UUID(), jobID: record?.jobID ?? UUID(), vmID: record?.vmID ?? target.vmID,
        sessionID: record?.sessionID ?? target.sessionID, payloadID: record?.payloadID ?? UUID(), workerToken: record?.workerToken ?? UUID(),
        engineDigest: record?.engineDigest ?? String(repeating: "a", count: 64), dependencyDigest: record?.dependencyDigest ?? String(repeating: "b", count: 64),
        bindingDigest: try record?.bindingDigest ?? ProvisioningCoordinator.bindingIdentity(target), reviewDigest: record?.reviewDigest ?? String(repeating: "c", count: 64),
        checkpointDigest: record?.cleanupCheckpointSHA256 ?? String(repeating: "d", count: 64))
}
func helperChanged(_ value: ProvisioningRecoveryExpectation, key: String, text: String) throws -> ProvisioningRecoveryExpectation {
    var object = try JSONSerialization.jsonObject(with: helperJSON(value)) as! [String: Any]
    object[key] = text
    return try JSONDecoder().decode(ProvisioningRecoveryExpectation.self, from: JSONSerialization.data(withJSONObject: object))
}
actor IPCWorkerGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { entered = true; if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
actor IPCRecordingRunner: ProvisioningProcessRunner, ProvisioningLocalCleanupReconciling {
    enum ResultKind { case exited, uncertain, wrongID }
    private(set) var invocations: [UUID] = [], interrupts: [UUID] = [], reconciliations: [UUID] = []
    var result: ResultKind
    private let gate: IPCWorkerGate?
    private let releaseOnInterrupt: Bool
    private var cleanupProven = false
    init(result: ResultKind = .exited, gate: IPCWorkerGate? = nil, releaseOnInterrupt: Bool = true) {
        self.result = result; self.gate = gate; self.releaseOnInterrupt = releaseOnInterrupt
    }
    func proveCleanup() { cleanupProven = true }
    func run(_ invocation: ProvisioningProcessInvocation) async -> ProvisioningProcessResult {
        invocations.append(invocation.id)
        await gate?.wait()
        switch result {
        case .exited: return .init(invocationID: invocation.id, termination: .exited(status: 0, reason: .normal))
        case .uncertain: return .init(invocationID: invocation.id, termination: .cleanupUnconfirmed)
        case .wrongID: return .init(invocationID: UUID(), termination: .exited(status: 0, reason: .normal))
        }
    }
    func interrupt(invocationID: UUID) async { interrupts.append(invocationID); if releaseOnInterrupt { await gate?.release() } }
    func reconcileLocalCleanup(invocationID: UUID) -> Bool {
        reconciliations.append(invocationID)
        return cleanupProven && invocations.contains(invocationID)
    }
}
final class HelperIPCFixture: Sendable {
    let target: GuestBinding
    let scope: ProvisioningRecoveryExpectation
    let credentials: ProvisioningHelperCredentials
    let registry: ProvisioningHelperOwnershipRegistry
    let clientSocket: ProvisioningHelperSocket
    let clientFD: Int32
    let serverSocket: ProvisioningHelperSocket
    let server: ProvisioningHelperIPCServer
    let client: ProvisioningHelperIPCClient
    let task: Task<Void, Never>
    init(scope: ProvisioningRecoveryExpectation? = nil, target: GuestBinding? = nil, timeout: Duration = .seconds(3)) throws {
        self.target = try target ?? GuestBinding(vmID: UUID(), sessionID: UUID(), owner: "fixture", ownerUID: 1000, hostKeyDigest: String(repeating: "a", count: 64))
        self.scope = try scope ?? helperTestExpectation(target: self.target)
        credentials = try ProvisioningHelperCredentials(identity: .init(instanceID: UUID(), executableSHA256: String(repeating: "e", count: 64), packageLockSHA256: ProvisioningPackagePin.lockSHA256))
        registry = try ProvisioningHelperOwnershipRegistry(identity: credentials.identity)
        var fds = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
        clientFD = fds[0]
        clientSocket = try ProvisioningHelperSocket(taking: fds[0], timeout: timeout)
        serverSocket = try ProvisioningHelperSocket(taking: fds[1], timeout: timeout)
        server = try ProvisioningHelperIPCServer(socket: serverSocket, credentials: credentials, registry: registry)
        client = ProvisioningHelperIPCClient(socket: clientSocket, credentials: credentials)
        let server = server; task = Task.detached { await server.serve() }
    }
    deinit { client.disconnect(); server.stop() }
    func runner(_ backend: any ProvisioningProcessRunner) async throws -> ProvisioningFencedProcessRunner {
        let runner = try ProvisioningFencedProcessRunner(backend: backend, scope: scope, target: target, mode: .apply)
        try await registry.register(scope, runner: runner); return runner
    }
    func invocation(id: UUID = UUID()) -> ProvisioningProcessInvocation {
        .init(id: id, commandID: UUID(), context: .init(jobID: scope.jobID, payloadID: scope.payloadID, target: target, dependencyDigest: scope.dependencyDigest, mode: .apply),
            purpose: .native, executable: URL(fileURLWithPath: "/nonexistent/never-executed-fixture"), arguments: [], environment: [:],
            workingDirectory: URL(fileURLWithPath: "/private/tmp"), input: .closed, output: .boundedCapture, timeoutSeconds: 1)
    }
}

@Suite("Provisioning authenticated helper control — local fixtures only") struct ProvisioningHelperIPCTests {
    @Test func bootstrapAndFramesAreRedactedDirectionalAndReplayProtected() throws {
        let identity = ProvisioningHelperIdentity(instanceID: UUID(), executableSHA256: String(repeating: "a", count: 64), packageLockSHA256: ProvisioningPackagePin.lockSHA256)
        let credentials = try ProvisioningHelperCredentials(identity: identity)
        let restored = try ProvisioningHelperCredentials(privateBootstrap: credentials.privateBootstrap())
        #expect(String(reflecting: credentials) == "ProvisioningHelperCredentials(redacted)")
        var manager = ProvisioningHelperFrameCodec(credentials: credentials, role: .manager)
        var helper = ProvisioningHelperFrameCodec(credentials: restored, role: .helper)
        let frame = try manager.encode(Data("control".utf8))
        #expect(try helper.decode(frame) == Data("control".utf8))
        #expect(throws: Error.self) { _ = try helper.decode(frame) }
        #expect(throws: Error.self) { _ = try manager.decode(frame) }
        let reply = try helper.encode(Data("proof".utf8))
        #expect(try manager.decode(reply) == Data("proof".utf8))
        let different = try ProvisioningHelperCredentials(identity: identity)
        var other = ProvisioningHelperFrameCodec(credentials: different, role: .helper)
        #expect(throws: Error.self) { _ = try other.decode(frame) }
    }
    @Test(arguments: ["mac", "version", "field", "identity", "sequence", "channel", "duplicate", "large"])
    func malformedFramesNeverAuthenticate(kind: String) throws {
        let credentials = try ProvisioningHelperCredentials(identity: .init(instanceID: UUID(), executableSHA256: String(repeating: "e", count: 64), packageLockSHA256: ProvisioningPackagePin.lockSHA256))
        var manager = ProvisioningHelperFrameCodec(credentials: credentials, role: .manager)
        let original = try manager.encode(Data("fixture".utf8))
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        var signed = object["signed"] as! [String: Any]
        if kind == "mac" { object["mac"] = Data(repeating: 0, count: 32).base64EncodedString() }
        if kind == "version" { signed["version"] = 2 }
        if kind == "field" { signed["command"] = "apply" }
        if kind == "sequence" { signed["sequence"] = 2 }
        if kind == "channel" { signed["channelID"] = UUID().uuidString }
        if kind == "identity" {
            var identity = signed["identity"] as! [String: Any]; identity["instanceID"] = UUID().uuidString; signed["identity"] = identity
        }
        object["signed"] = signed
        var data = try JSONSerialization.data(withJSONObject: object)
        if kind == "duplicate" { data = Data("{\"mac\":\"\",\"mac\":\"\"}".utf8) }
        if kind == "large" { data = Data(repeating: 32, count: ProvisioningHelperFrameCodec.maximumFrameBytes + 1) }
        var helper = ProvisioningHelperFrameCodec(credentials: credentials, role: .helper)
        #expect(throws: Error.self) { _ = try helper.decode(data) }
        // A failed decode never advances sequence.
        #expect(try helper.decode(original) == Data("fixture".utf8))
    }
    @Test func ownershipReconciliationFencesBeforeWaitingForExactLocalExit() async throws {
        let f = try HelperIPCFixture(), gate = IPCWorkerGate(), backend = IPCRecordingRunner(gate: gate, releaseOnInterrupt: false)
        let runner = try await f.runner(backend), invocation = f.invocation()
        let work = Task { await runner.run(invocation) }
        #expect(await eventually { await gate.entered })
        let proof = Task { try await f.client.reconcile(f.scope) }
        #expect(await eventually { await backend.interrupts.contains(invocation.id) })
        await #expect(throws: ProvisioningHelperIPCFailure.unavailable) { _ = try await f.client.reconcile(f.scope) }
        await f.server.serve() // A second serve must not reset receive sequence.
        let attempted = await runner.run(f.invocation())
        if case .notStarted = attempted.termination {} else { Issue.record("Fenced runner admitted a launch") }
        #expect(await backend.invocations == [invocation.id])
        await gate.release(); _ = await work.value
        #expect(try await proof.value.priorWorker == .stoppedAndFenced)
        let next = try helperChanged(f.scope, key: "challenge", text: UUID().uuidString)
        #expect(try await f.client.reconcile(next).expectation == next)
        #expect(await backend.invocations.count == 1)
        f.client.disconnect(); await f.task.value
    }
    @Test(arguments: [IPCRecordingRunner.ResultKind.uncertain, .wrongID])
    func uncertainAndMismatchedReceiptsRetainOwnership(kind: IPCRecordingRunner.ResultKind) async throws {
        let f = try HelperIPCFixture(), backend = IPCRecordingRunner(result: kind), runner = try await f.runner(backend)
        let invocation = f.invocation()
        _ = await runner.run(invocation)
        #expect(try await f.client.reconcile(f.scope).priorWorker == .unknown)
        #expect(await backend.reconciliations == [invocation.id])
        await backend.proveCleanup()
        let next = try helperChanged(f.scope, key: "challenge", text: UUID().uuidString)
        #expect(try await f.client.reconcile(next).priorWorker == .stoppedAndFenced)
        #expect(await backend.invocations == [invocation.id])
    }
    @Test(arguments: ["jobID", "vmID", "sessionID", "payloadID", "workerToken", "engineDigest", "dependencyDigest", "bindingDigest", "reviewDigest", "checkpointDigest"])
    func wrongOwnershipScopeCannotFenceOrProveAnotherWorker(key: String) async throws {
        let f = try HelperIPCFixture(), backend = IPCRecordingRunner(), runner = try await f.runner(backend)
        let modified = try helperChanged(f.scope, key: key, text: key.hasSuffix("Digest") ? String(repeating: "f", count: 64) : UUID().uuidString)
        #expect(try await f.client.reconcile(modified).priorWorker == .unknown)
        #expect(await backend.interrupts.isEmpty)
        // A rejected foreign scope did not fence the actual registered worker.
        _ = await runner.run(f.invocation())
        #expect(await backend.invocations.count == 1)
    }
    @Test func missingOwnerStateIsUnknownAndRegistrationCannotBeReplaced() async throws {
        let f = try HelperIPCFixture()
        #expect(try await f.client.reconcile(f.scope).priorWorker == .unknown)
        let first = try await f.runner(IPCRecordingRunner())
        await #expect(throws: ProvisioningHelperIPCFailure.ownership) { try await f.registry.register(f.scope, runner: first) }
        #expect(try await f.client.reconcile(f.scope).priorWorker == .stoppedAndFenced)
    }
    @Test func disconnectFencesWorkWithoutClaimingGuestCleanup() async throws {
        let f = try HelperIPCFixture(), gate = IPCWorkerGate(), backend = IPCRecordingRunner(gate: gate)
        let runner = try await f.runner(backend), invocation = f.invocation()
        let task = Task { await runner.run(invocation) }
        #expect(await eventually { await gate.entered })
        f.client.disconnect()
        #expect(await eventually { await backend.interrupts == [invocation.id] })
        _ = await task.value; await f.task.value
        if case .notStarted = await runner.run(f.invocation()).termination {} else { Issue.record("Disconnect reopened launch gate") }
        let replacement = try ProvisioningFencedProcessRunner(backend: IPCRecordingRunner(), scope: f.scope, target: f.target, mode: .apply)
        await #expect(throws: ProvisioningHelperIPCFailure.ownership) { try await f.registry.register(f.scope, runner: replacement) }
        #expect(await backend.invocations == [invocation.id])
    }
    @Test func timeoutPoisonsClientButDoesNotForgetOutstandingWorker() async throws {
        let f = try HelperIPCFixture(timeout: .milliseconds(80)), gate = IPCWorkerGate(), backend = IPCRecordingRunner(gate: gate, releaseOnInterrupt: false)
        let runner = try await f.runner(backend), work = Task { await runner.run(f.invocation()) }
        #expect(await eventually { await gate.entered })
        await #expect(throws: ProvisioningHelperIPCFailure.authentication) { _ = try await f.client.reconcile(f.scope) }
        await #expect(throws: ProvisioningHelperIPCFailure.authentication) { _ = try await f.client.reconcile(f.scope) }
        #expect(await backend.invocations.count == 1)
        await gate.release(); _ = await work.value; await f.task.value
        #expect(await f.registry.reconcile(f.scope) == .stoppedAndFenced)
    }
    @Test func authenticatedUnsupportedCommandAndWrongKeyCloseChannel() async throws {
        for wrongKey in [false, true] {
            let f = try HelperIPCFixture()
            let credentials = try wrongKey ? ProvisioningHelperCredentials(identity: f.credentials.identity) : f.credentials
            var codec = ProvisioningHelperFrameCodec(credentials: credentials, role: .manager)
            let data = wrongKey ? try helperJSON(ProvisioningHelperReconcileRequest(requestID: UUID(), expectation: f.scope)) : Data("{\"command\":\"apply\",\"terminal\":\"never-echo-fixture\"}".utf8)
            try f.clientSocket.send(codec.encode(data))
            await f.task.value
            #expect(f.clientSocket.peerClosed)
        }
    }
    @Test(arguments: ["requestID", "challenge"])
    func clientRejectsAuthenticButUncorrelatedReply(kind: String) async throws {
        let f = try HelperIPCFixture(); f.server.stop(); await f.task.value
        var fds = [Int32](repeating: -1, count: 2); #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let clientSocket = try ProvisioningHelperSocket(taking: fds[0]), peer = try ProvisioningHelperSocket(taking: fds[1])
        let client = ProvisioningHelperIPCClient(socket: clientSocket, credentials: f.credentials)
        let responder = Task {
            var codec = ProvisioningHelperFrameCodec(credentials: f.credentials, role: .helper)
            let bytes = try await helperBlocking { try peer.receive() }
            let request = try ProvisioningHelperReconcileRequest.decode(codec.decode(bytes))
            let expectation = kind == "challenge" ? try helperChanged(request.expectation, key: "challenge", text: UUID().uuidString) : request.expectation
            let reply = ProvisioningHelperReconcileResponse(requestID: kind == "requestID" ? UUID() : request.requestID, expectation: expectation, priorWorker: .stoppedAndFenced)
            try peer.send(codec.encode(helperJSON(reply)))
        }
        await #expect(throws: ProvisioningHelperIPCFailure.authentication) { _ = try await client.reconcile(f.scope) }
        try await responder.value; peer.stop()
    }
    @Test(arguments: ["partial", "oversized", "eof"])
    func framingIsBoundedAndTruncationIsNotAProof(kind: String) async throws {
        var fds = [Int32](repeating: -1, count: 2); #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let reader = try ProvisioningHelperSocket(taking: fds[0], timeout: .milliseconds(60))
        defer { reader.stop(); Darwin.close(fds[1]) }
        let bytes: [UInt8] = kind == "oversized" ? [0, 1, 0, 0] : [0, 0, 0, 10, 1]
        _ = bytes.withUnsafeBytes { Darwin.send(fds[1], $0.baseAddress, $0.count, 0) }
        if kind == "eof" { _ = Darwin.shutdown(fds[1], SHUT_WR) }
        await #expect(throws: ProvisioningHelperIPCFailure.self) { _ = try await helperBlocking { try reader.receive() } }
    }
    @Test func onlyOwnedUnixStreamDescriptorsAreAccepted() throws {
        var fds = [Int32](repeating: -1, count: 2); #expect(pipe(&fds) == 0)
        defer { Darwin.close(fds[1]) }
        #expect(throws: ProvisioningHelperIPCFailure.authentication) { _ = try ProvisioningHelperSocket(taking: fds[0]) }
    }
    @Test func concurrentReconciliationSharesOneOwnedStopAndRetainsTombstone() async throws {
        let f = try HelperIPCFixture(), gate = IPCWorkerGate(), backend = IPCRecordingRunner(gate: gate, releaseOnInterrupt: false)
        let runner = try await f.runner(backend), invocation = f.invocation()
        let work = Task { await runner.run(invocation) }
        #expect(await eventually { await gate.entered })
        let first = Task { await f.registry.reconcile(f.scope) }
        #expect(await eventually { await backend.interrupts == [invocation.id] })
        let second = Task { await f.registry.reconcile(f.scope) }
        await gate.release(); _ = await work.value
        #expect(await first.value == .stoppedAndFenced)
        #expect(await second.value == .stoppedAndFenced)
        #expect(await backend.interrupts == [invocation.id])
        #expect(await f.registry.reconcile(f.scope) == .stoppedAndFenced)
        #expect(await backend.invocations.count == 1)
    }
}
