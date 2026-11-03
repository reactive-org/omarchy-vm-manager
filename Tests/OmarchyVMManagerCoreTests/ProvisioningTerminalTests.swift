import Darwin
@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private final class TerminalFixture: @unchecked Sendable {
    let root = URL(fileURLWithPath: "/private/tmp/terminal-" + UUID().uuidString).standardizedFileURL
    let request: ProvisioningRequest
    let terminal: ProvisioningTerminal
    let hub: ProvisioningTerminalHub
    let context: GuestJobContext
    init(capacity: Int = 256 * 1024, input: Bool = true, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) throws {
        try PrivateFiles.directory(root, create: true)
        try Data("schema_version: 1\nid: terminal-fixture\n".utf8).write(to: root.appendingPathComponent("vm.yml"))
        let target = try GuestBinding(vmID: UUID(), sessionID: UUID(), owner: "fixture", ownerUID: 1000, hostKeyDigest: String(repeating: "a", count: 64))
        request = try .init(jobID: UUID(), plan: SetupPlanner.plan(repository: root), repository: root, target: target,
            dependencyDigest: String(repeating: "b", count: 64), inputLeaseID: input ? UUID() : nil)
        terminal = try ProvisioningTerminal(capacityBytes: capacity)
        hub = try ProvisioningTerminalHub(terminal: terminal, request: request, lifetime: .seconds(1), now: now)
        context = .init(jobID: request.jobID, payloadID: UUID(), target: target, dependencyDigest: request.dependencyDigest, mode: .apply)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func packet(_ operation: ProvisioningTerminalOperation, id: UUID? = nil, token: UUID? = nil, invocation: UUID? = nil, sequence: UInt64? = nil, bytes: Data? = nil, rows: Int? = nil, columns: Int? = nil) -> ProvisioningTerminalPacket {
        .init(version: 1, jobID: request.jobID, requestID: UUID(), operation: operation, attachmentID: id, ownershipID: token,
              invocationID: invocation, sequence: sequence, bytes: bytes, rows: rows, columns: columns)
    }
    func call(_ packet: ProvisioningTerminalPacket) async throws -> ProvisioningTerminalReply {
        let validated = try ProvisioningTerminalPacket.decode(helperJSON(packet))
        return try ProvisioningTerminalReply.decode(helperJSON(await hub.handle(validated)), request: packet)
    }
    func invocation(script: String = "exit 0", interactive: Bool = true, timeout: Int = 3) throws -> ProvisioningProcessInvocation {
        let path = root.appendingPathComponent(UUID().uuidString + ".sh")
        try Data(script.utf8).write(to: path)
        return .init(id: UUID(), commandID: UUID(), context: context, purpose: .native, executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [path.path], environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], workingDirectory: root.standardizedFileURL,
            input: interactive ? .terminalLease(request.inputLeaseID!) : .closed, output: .terminalStream, timeoutSeconds: timeout)
    }
    func launcher() throws -> ProvisioningExecutablePin {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = repo.appendingPathComponent(".build/provisioning-launcher/debug/dev-vm-process-host").resolvingSymlinksInPath()
        let destination = root.appendingPathComponent("process-host")
        try FileManager.default.copyItem(at: source, to: destination); chmod(destination.path, 0o700)
        return try ProvisioningExecutablePin(destination.standardizedFileURL)
    }
    func wait(_ text: String) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < end {
            if String(decoding: terminal.snapshot().frames.flatMap(\.bytes), as: UTF8.self).contains(text) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SequencingFailure.timedOut
    }
}
private final class TerminalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance() { lock.withLock { instant += .seconds(2) } }
}
private func terminalCredentials() throws -> ProvisioningHelperCredentials {
    try .init(identity: .init(instanceID: UUID(), executableSHA256: String(repeating: "a", count: 64), packageLockSHA256: String(repeating: "b", count: 64)))
}

@Suite("Provisioning terminal — local fixtures only", .serialized) struct ProvisioningTerminalTests {
    @Test func separateMACDomainDirectionAndReplay() throws {
        let credentials = try terminalCredentials(), bytes = Data("synthetic-keystroke-canary".utf8)
        var sender = ProvisioningHelperFrameCodec(credentials: credentials.terminalCredentials(), role: .manager)
        var receiver = ProvisioningHelperFrameCodec(credentials: credentials.terminalCredentials(), role: .helper)
        let frame = try sender.encode(bytes)
        #expect(try receiver.decode(frame) == bytes)
        #expect(throws: ProvisioningHelperIPCFailure.self) { _ = try receiver.decode(frame) }
        for other in [credentials, credentials.sessionCredentials()] {
            var wrong = ProvisioningHelperFrameCodec(credentials: other, role: .helper)
            #expect(throws: ProvisioningHelperIPCFailure.self) { _ = try wrong.decode(frame) }
        }
        var reflected = ProvisioningHelperFrameCodec(credentials: credentials.terminalCredentials(), role: .manager)
        #expect(throws: ProvisioningHelperIPCFailure.self) { _ = try reflected.decode(frame) }
    }
    @Test(arguments: ["version", "unknown", "duplicate", "null", "input", "empty", "rows", "sequence", "claim-null", "reply-null", "bytes-null", "rows-null"])
    func strictTerminalDocuments(kind: String) throws {
        let f = try TerminalFixture()
        var request = f.packet(.input, id: UUID(), token: UUID(), invocation: UUID(), sequence: 1, bytes: Data([10]))
        var object = try #require(JSONSerialization.jsonObject(with: helperJSON(request)) as? [String: Any])
        switch kind {
        case "version": object["version"] = 2
        case "unknown": object["argv"] = ["forbidden"]
        case "duplicate":
            let bytes = try helperJSON(request)
            let text = String(decoding: bytes, as: UTF8.self).dropLast() + ",\"version\":1}"
            #expect(throws: (any Error).self) { _ = try ProvisioningTerminalPacket.decode(Data(text.utf8)) }; return
        case "null": object["ownershipID"] = NSNull()
        case "bytes-null": object["bytes"] = NSNull()
        case "rows-null": request = f.packet(.claim, id: UUID(), rows: 24, columns: 80); object = try #require(JSONSerialization.jsonObject(with: helperJSON(request)) as? [String: Any]); object["rows"] = NSNull()
        case "input": object["bytes"] = Data(repeating: 1, count: 4097).base64EncodedString()
        case "empty": object["bytes"] = ""
        case "rows": request = f.packet(.claim, id: UUID(), rows: 501, columns: 80); object = try #require(JSONSerialization.jsonObject(with: helperJSON(request)) as? [String: Any])
        case "sequence": object["sequence"] = 0
        case "claim-null":
            request = f.packet(.claim, id: UUID(), rows: 24, columns: 80)
            let reply: [String: Any] = ["version": 1, "jobID": request.jobID.uuidString, "requestID": request.requestID.uuidString, "operation": "claim", "attachmentID": request.attachmentID!.uuidString, "ownershipID": NSNull()]
            #expect(throws: (any Error).self) { _ = try ProvisioningTerminalReply.decode(JSONSerialization.data(withJSONObject: reply), request: request) }; return
        default:
            request = f.packet(.read, id: UUID())
            let reply: [String: Any] = ["version": 1, "jobID": request.jobID.uuidString, "requestID": request.requestID.uuidString, "operation": "read", "attachmentID": request.attachmentID!.uuidString, "page": NSNull()]
            #expect(throws: (any Error).self) { _ = try ProvisioningTerminalReply.decode(JSONSerialization.data(withJSONObject: reply), request: request) }; return
        }
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { _ = try ProvisioningTerminalPacket.decode(bytes) }
    }
    @Test func multipleViewersExplicitTransferAndStaleInputAreFenced() async throws {
        let f = try TerminalFixture(), invocation = try f.invocation()
        _ = try f.terminal.begin(invocation)
        let a = try #require(try await f.call(f.packet(.attach)).attachmentID)
        let b = try #require(try await f.call(f.packet(.attach)).attachmentID)
        #expect(!f.terminal.snapshot().acceptsInput)
        let owner = try #require(try await f.call(f.packet(.claim, id: a, rows: 24, columns: 80)).ownershipID)
        #expect(try await f.call(f.packet(.claim, id: b, rows: 30, columns: 90)).denial == .ownership)
        let valid = f.packet(.input, id: a, token: owner, invocation: invocation.id, sequence: 1, bytes: Data("never-echo".utf8))
        #expect(try await f.call(valid).denial == nil)
        #expect(try await f.call(valid).denial == .ownership)
        #expect(try await f.call(f.packet(.input, id: b, token: owner, invocation: invocation.id, sequence: 2, bytes: Data([10]))).denial == .ownership)
        #expect(try await f.call(f.packet(.resize, id: a, token: owner, invocation: UUID(), sequence: 2, rows: 50, columns: 120)).denial == .ownership)
        _ = try await f.call(f.packet(.detach, id: a))
        #expect(!f.terminal.snapshot().acceptsInput)
        let second = try #require(try await f.call(f.packet(.claim, id: b, rows: 32, columns: 100)).ownershipID)
        #expect(second != owner)
        #expect(try await f.call(f.packet(.input, id: b, token: owner, invocation: invocation.id, sequence: 1, bytes: Data([10]))).denial == .ownership)
        #expect(try await f.call(f.packet(.input, id: b, token: second, invocation: invocation.id, sequence: 1, bytes: Data([10]))).denial == nil)
        await f.hub.finish()
        #expect(!f.terminal.snapshot().acceptsInput)
        #expect(try await f.call(f.packet(.claim, id: b, rows: 24, columns: 80)).denial == .ownership)
        f.terminal.end(invocation.id)
    }
    @Test func viewerQuotaExpiryAndCrossJobCannotClaimInput() async throws {
        let clock = TerminalClock(), f = try TerminalFixture(now: { clock.now() })
        var ids: [UUID] = []
        for _ in 0..<8 { ids.append(try #require(try await f.call(f.packet(.attach)).attachmentID)) }
        #expect(try await f.call(f.packet(.attach)).denial == .bounds)
        _ = try await f.call(f.packet(.claim, id: ids[0], rows: 24, columns: 80))
        clock.advance(); await f.hub.expire()
        #expect(try await f.call(f.packet(.heartbeat, id: ids[0])).denial == .attachment)
        let next = try #require(try await f.call(f.packet(.attach)).attachmentID)
        #expect(try await f.call(f.packet(.claim, id: next, rows: 24, columns: 80)).denial == nil)
        let wrong = ProvisioningTerminalPacket(version: 1, jobID: UUID(), requestID: UUID(), operation: .attach)
        #expect(await f.hub.handle(wrong).denial == .unavailable)
    }
    @Test func droppedOutputRequiresExplicitResetAndLateViewersCannotInventScreen() async throws {
        let f = try TerminalFixture(capacity: 8192, input: false), invocation = try f.invocation(interactive: false)
        let id = try #require(try await f.call(f.packet(.attach)).attachmentID)
        _ = try f.terminal.begin(invocation)
        for _ in 0..<20 { f.terminal.publish(invocation.id, channel: .stdout, bytes: Data(repeating: 120, count: 8192)) }
        let gap = try #require(try await f.call(f.packet(.read, id: id)).page)
        #expect(gap.resetRequired && gap.frames.isEmpty)
        #expect(try await f.call(f.packet(.read, id: id)).page?.resetRequired == true)
        #expect(try await f.call(f.packet(.reset, id: id)).page?.resetRequired == false)
        let raw = Data("\u{1b}[32mnext\u{1b}[0m\r☃".utf8)
        f.terminal.publish(invocation.id, channel: .stderr, bytes: raw)
        let page = try #require(try await f.call(f.packet(.read, id: id)).page)
        #expect(page.frames.first?.bytes == raw && page.frames.first?.channel == "stderr")
        #expect(!page.resetRequired && f.terminal.snapshot().frames.reduce(0, { $0 + $1.bytes.count }) <= 8192)
        let late = try #require(try await f.call(f.packet(.attach)).attachmentID)
        #expect(try await f.call(f.packet(.read, id: late)).page?.resetRequired == true)
        f.terminal.end(invocation.id)
    }
    @Test func authenticatedSocketPreservesSplitUTF8ANSIAndMaximumFrames() async throws {
        let f = try TerminalFixture(input: false), credentials = try terminalCredentials(), (parent, child) = try sessionFixtureSockets()
        let server = ProvisioningTerminalServer(socket: child, credentials: credentials, hub: f.hub)
        let task = Task { await server.serve() }
        let client = ProvisioningTerminalClient(socket: parent, credentials: credentials, jobID: f.request.jobID)
        let viewer = try await ProvisioningTerminalAttachment.attach(client: client)
        let invocation = try f.invocation(interactive: false); _ = try f.terminal.begin(invocation)
        let bytes = Data("\u{1b}[32mworking\u{1b}[0m\r☃\n".utf8)
        for byte in bytes { f.terminal.publish(invocation.id, channel: .stdout, bytes: Data([byte])) }
        var output = Data()
        for _ in 0..<bytes.count { output.append(contentsOf: try await viewer.poll().frames.flatMap(\.bytes)) }
        #expect(output == bytes)
        f.terminal.publish(invocation.id, channel: .stderr, bytes: Data(repeating: 65, count: 8192))
        #expect(try await viewer.poll().frames.first?.bytes.count == 8192)
        #expect(!String(reflecting: try await viewer.poll()).contains("working"))
        await viewer.detach(); client.disconnect(); await task.value
        #expect(f.terminal.snapshot().activeInvocationID == invocation.id) // detach is not cancellation
        f.terminal.end(invocation.id)
    }
    @Test func attachmentCanResetGapAndDeliberatelyReclaimWithNewOwnerGeneration() async throws {
        let f = try TerminalFixture(capacity: 8192), credentials = try terminalCredentials(), (parent, child) = try sessionFixtureSockets()
        let server = ProvisioningTerminalServer(socket: child, credentials: credentials, hub: f.hub)
        let serving = Task { await server.serve() }, client = ProvisioningTerminalClient(socket: parent, credentials: credentials, jobID: f.request.jobID)
        let viewer = try await ProvisioningTerminalAttachment.attach(client: client)
        try await viewer.claimInput(size: ProvisioningTerminalSize(rows: 24, columns: 80))
        let invocation = try f.invocation(); _ = try f.terminal.begin(invocation)
        for _ in 0..<3 { f.terminal.publish(invocation.id, channel: .pty, bytes: Data(repeating: 120, count: 8192)) }
        #expect(try await viewer.poll().resetRequired)
        #expect(!f.terminal.snapshot().acceptsInput)
        #expect(!(try await viewer.acknowledgeReset()).resetRequired)
        try await viewer.claimInput(size: ProvisioningTerminalSize(rows: 32, columns: 110))
        try await viewer.send(Data([10]), invocationID: invocation.id)
        #expect(f.terminal.snapshot().acceptsInput)
        await viewer.detach(); client.disconnect(); await serving.value; f.terminal.end(invocation.id)
    }
    @Test func malformedTerminalCannotFenceControlWorkerOrBlockCancellation() async throws {
        let f = try TerminalFixture(), control = try HelperIPCFixture(), gate = IPCWorkerGate()
        let backend = IPCRecordingRunner(gate: gate)
        let runner = try await control.runner(backend), invocation = control.invocation()
        let process = Task { await runner.run(invocation) }
        let end = ContinuousClock.now + .seconds(2)
        while !(await gate.entered), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        let (parent, child) = try sessionFixtureSockets()
        let server = ProvisioningTerminalServer(socket: child, credentials: control.credentials, hub: f.hub)
        let serving = Task { await server.serve() }
        // A valid control-domain MAC is deliberately invalid on the stream.
        var wrong = ProvisioningHelperFrameCodec(credentials: control.credentials, role: .manager)
        try parent.send(wrong.encode(helperJSON(f.packet(.attach))))
        await serving.value
        #expect(await backend.interrupts.isEmpty)
        #expect(try await control.client.reconcile(control.scope).priorWorker == .stoppedAndFenced)
        #expect(await backend.interrupts == [invocation.id])
        _ = await process.value
        parent.stop(); control.client.disconnect(); await control.task.value
    }
    @Test func fencingAnInertWorkerRevokesReservedStreamInput() async throws {
        let f = try TerminalFixture(), credentials = try terminalCredentials()
        let id = try #require(try await f.call(f.packet(.attach)).attachmentID)
        _ = try await f.call(f.packet(.claim, id: id, rows: 24, columns: 80))
        let scope = ProvisioningRecoveryExpectation(challenge: UUID(), jobID: f.request.jobID, vmID: f.request.target.vmID,
            sessionID: f.request.target.sessionID, payloadID: UUID(), workerToken: UUID(),
            engineDigest: try ProvisioningCoordinator.engineIdentity(f.request.plan), dependencyDigest: f.request.dependencyDigest,
            bindingDigest: try ProvisioningCoordinator.bindingIdentity(f.request.target), reviewDigest: f.request.reviewIdentity,
            checkpointDigest: String(repeating: "c", count: 64), helperIdentity: credentials.identity)
        let registration = ProvisioningHelperWorkerRegistration(scope: scope, planDigest: f.request.plan.identity, inputDigest: f.request.plan.snapshot.identity, mode: .apply)
        let worker = ProvisioningHelperEngineWorker(registration: registration, terminalHub: f.hub, bodyAllowed: { true })
        #expect(await worker.fenceAndReconcile() == .stoppedAndFenced)
        #expect(!(try await f.call(f.packet(.read, id: id))).page!.ownsInput)
        #expect(try await f.call(f.packet(.claim, id: id, rows: 24, columns: 80)).denial == .ownership)
    }
    @Test func observedGapRevokesTypingUntilResetAndExplicitReclaim() async throws {
        let f = try TerminalFixture(capacity: 8192), invocation = try f.invocation()
        let id = try #require(try await f.call(f.packet(.attach)).attachmentID)
        let token = try #require(try await f.call(f.packet(.claim, id: id, rows: 24, columns: 80)).ownershipID)
        _ = try f.terminal.begin(invocation)
        for _ in 0..<3 { f.terminal.publish(invocation.id, channel: .pty, bytes: Data(repeating: 120, count: 8192)) }
        #expect(try await f.call(f.packet(.input, id: id, token: token, invocation: invocation.id, sequence: 1, bytes: Data([10]))).denial == .resetRequired)
        #expect(!f.terminal.snapshot().acceptsInput)
        _ = try await f.call(f.packet(.reset, id: id))
        let next = try #require(try await f.call(f.packet(.claim, id: id, rows: 24, columns: 80)).ownershipID)
        #expect(next != token && f.terminal.snapshot().acceptsInput)
        f.terminal.end(invocation.id)
    }
    @Test func socketEOFRevokesOwnerWithoutStoppingProcessOrGrantingReconnect() async throws {
        let f = try TerminalFixture(), credentials = try terminalCredentials(), (parent, child) = try sessionFixtureSockets()
        let server = ProvisioningTerminalServer(socket: child, credentials: credentials, hub: f.hub)
        let serving = Task { await server.serve() }, client = ProvisioningTerminalClient(socket: parent, credentials: credentials, jobID: f.request.jobID)
        let viewer = try await ProvisioningTerminalAttachment.attach(client: client)
        try await viewer.claimInput(size: ProvisioningTerminalSize(rows: 24, columns: 80))
        let invocation = try f.invocation(); _ = try f.terminal.begin(invocation)
        #expect(f.terminal.snapshot().acceptsInput)
        client.disconnect(); await serving.value
        #expect(!f.terminal.snapshot().acceptsInput && f.terminal.snapshot().activeInvocationID == invocation.id)
        #expect(try await f.call(f.packet(.attach)).denial == .unavailable)
        f.terminal.end(invocation.id)
    }
    @Test func disposablePTYPromptResizeDetachReattachAndHiddenInput() async throws {
        let f = try TerminalFixture(), credentials = try terminalCredentials(), (parent, child) = try sessionFixtureSockets()
        let server = ProvisioningTerminalServer(socket: child, credentials: credentials, hub: f.hub)
        let serving = Task { await server.serve() }, client = ProvisioningTerminalClient(socket: parent, credentials: credentials, jobID: f.request.jobID)
        let first = try await ProvisioningTerminalAttachment.attach(client: client)
        try await first.claimInput(size: ProvisioningTerminalSize(rows: 32, columns: 110))
        let runner = LocalProvisioningProcessRunner(terminal: f.terminal, ptyLauncher: try f.launcher())
        let invocation = try f.invocation(script: "printf '\\033[32mREADY\\033[0m\\n'\nIFS= read -r value\nprintf 'SIZE '; /bin/stty size\nprintf '\\rDONE ☃\\n'\n")
        let process = Task { await runner.run(invocation) }
        do {
            try await f.wait("READY")
            await first.detach()
            #expect(!f.terminal.snapshot().acceptsInput)
            let second = try await ProvisioningTerminalAttachment.attach(client: client)
            #expect(!(try await second.poll()).ownsInput)
            await #expect(throws: ProvisioningTerminalDenial.self) { try await second.send(Data([10]), invocationID: invocation.id) }
            try await second.claimInput(size: ProvisioningTerminalSize(rows: 40, columns: 120))
            try await second.resize(ProvisioningTerminalSize(rows: 45, columns: 125), invocationID: invocation.id)
            try await second.send(Data("synthetic-password-canary\n".utf8), invocationID: invocation.id)
            let result = await process.value
            if case .exited(status: 0, reason: .normal) = result.termination {} else { Issue.record("Disposable PTY did not exit cleanly") }
            let output = String(decoding: f.terminal.snapshot().frames.flatMap(\.bytes), as: UTF8.self)
            #expect(output.contains("SIZE 45 125") && output.contains("DONE ☃") && output.contains("\u{1b}[32m"))
            #expect(!output.contains("synthetic-password-canary") && result.stdout.isEmpty && result.stderr.isEmpty)
            await second.detach()
        } catch { await runner.interrupt(invocationID: invocation.id); _ = await process.value; client.disconnect(); await serving.value; throw error }
        client.disconnect(); await serving.value
    }
    @Test func detachedFloodCannotBlockRunnerAndCancellationStillReaps() async throws {
        let f = try TerminalFixture(capacity: 8192, input: false)
        let runner = LocalProvisioningProcessRunner(terminal: f.terminal)
        let flood = try f.invocation(script: "i=0; while [ $i -lt 10000 ]; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n'; i=$((i+1)); done\n", interactive: false)
        let result = await runner.run(flood)
        if case .exited(status: 0, reason: .normal) = result.termination {} else { Issue.record("Detached flood blocked runner") }
        #expect(f.terminal.snapshot().gap && f.terminal.snapshot().frames.reduce(0, { $0 + $1.bytes.count }) <= 8192)
        let waiting = try f.invocation(script: "printf 'WAITING\\n'; /bin/sleep 10\n", interactive: false)
        let process = Task { await runner.run(waiting) }
        try await f.wait("WAITING"); await runner.interrupt(invocationID: waiting.id)
        if case .exited(_, reason: .cancelled) = await process.value.termination {} else { Issue.record("Owned local cancellation did not reap") }
    }
    @Test(arguments: ["success", "throw", "cancel"])
    func localTTYRestoresOnEveryScopedExit(kind: String) async throws {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw ProvisioningTerminalDenial.unavailable }
        defer { close(master); close(slave) }
        var before = termios(); #expect(tcgetattr(slave, &before) == 0)
        let descriptor = slave
        let task = Task {
            try await ProvisioningLocalTerminal.withRaw(descriptor: descriptor) {
                var raw = termios(); #expect(tcgetattr(descriptor, &raw) == 0)
                #expect(raw.c_lflag & tcflag_t(ECHO | ICANON) == 0)
                if kind == "throw" { throw ProvisioningTerminalDenial.unavailable }
                if kind == "cancel" { try await Task.sleep(for: .seconds(3)) }
            }
        }
        if kind == "cancel" { try await Task.sleep(for: .milliseconds(30)); task.cancel() }
        do { try await task.value; #expect(kind == "success") } catch { #expect(kind != "success") }
        var after = termios(); #expect(tcgetattr(slave, &after) == 0)
        #expect(before.c_iflag == after.c_iflag && before.c_oflag == after.c_oflag && before.c_cflag == after.c_cflag)
        // Darwin sets the transient PENDIN status bit when ICANON is
        // restored. It is not a lost user setting; compare all actual flags.
        #expect(before.c_lflag & ~tcflag_t(PENDIN) == after.c_lflag & ~tcflag_t(PENDIN))
        #expect(withUnsafeBytes(of: before.c_cc) { Data($0) } == withUnsafeBytes(of: after.c_cc) { Data($0) })
    }
}
