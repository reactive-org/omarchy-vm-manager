import Darwin
import Foundation
import Testing
@testable import DevVMProvisioningCore

private let transportPin = String(repeating: "d", count: 64)
private actor SessionAuthority: ProvisioningSessionAuthority {
    let binding: GuestBinding
    private var admitted = true
    private var gate: RunnerGate?
    init(_ binding: GuestBinding) { self.binding = binding }
    func invalidate() { admitted = false }
    func pauseNextValidation(_ gate: RunnerGate) { self.gate = gate }
    func revalidate(_ binding: GuestBinding, dependencyDigest: String) async throws {
        if let gate { self.gate = nil; await gate.pause() }
        guard admitted, binding == self.binding, dependencyDigest == transportPin else { throw SequencingFailure.identityMismatch }
    }
}
private actor RunnerGate {
    private var entered = false, interrupted = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryObservers: [CheckedContinuation<Void, Never>] = []
    private var interruptObservers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; entered = true
            for observer in entryObservers { observer.resume() }; entryObservers = []
        }
    }
    func waitEntered() async { if !entered { await withCheckedContinuation { entryObservers.append($0) } } }
    func recordInterrupt() {
        interrupted = true
        for observer in interruptObservers { observer.resume() }; interruptObservers = []
    }
    func waitInterrupted() async { if !interrupted { await withCheckedContinuation { interruptObservers.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}
private enum RunnerFault: Sendable { case status(Int32), timeout, cancelled, notStarted, wrongID, malformed, wrongOwner, wrongJob, oversized, capturedStream }
/// No executable is started. These are the only process runners used in tests.
private actor FakeProcessRunner: ProvisioningProcessRunner {
    private(set) var invocations: [ProvisioningProcessInvocation] = []
    private(set) var interrupts: [UUID] = []
    private var faults: [ProvisioningProcessPurpose: [RunnerFault]]
    private let gate: RunnerGate?
    private let pauseAt: ProvisioningProcessPurpose?
    private let hook: (@Sendable (ProvisioningProcessInvocation) throws -> Void)?
    private let asyncHook: (@Sendable (ProvisioningProcessInvocation) async -> Void)?
    private var cancelledIDs = Set<UUID>()
    init(_ faults: [ProvisioningProcessPurpose: [RunnerFault]] = [:], pauseAt: ProvisioningProcessPurpose? = nil, gate: RunnerGate? = nil,
         hook: (@Sendable (ProvisioningProcessInvocation) throws -> Void)? = nil,
         asyncHook: (@Sendable (ProvisioningProcessInvocation) async -> Void)? = nil) {
        self.faults = faults; self.pauseAt = pauseAt; self.gate = gate; self.hook = hook; self.asyncHook = asyncHook
    }
    func run(_ invocation: ProvisioningProcessInvocation) async -> ProvisioningProcessResult {
        invocations.append(invocation)
        do { try hook?(invocation) } catch { return ProvisioningProcessResult(invocationID: invocation.id, termination: .notStarted) }
        await asyncHook?(invocation)
        if invocation.purpose == pauseAt { await gate?.pause() }
        var status: Int32 = 0, reason = ProvisioningExitReason.normal, id = invocation.id, stdout = Data(), stderr = Data()
        var object: [String: ManifestValue] = ["protocol": .integer(1), "job": .string(invocation.context.jobID.uuidString.lowercased()),
            "payload": .string(invocation.context.payloadID.uuidString.lowercased()), "uid": .integer(1000)]
        switch invocation.purpose {
        case .identity: object = ["uid": .integer(1000), "owner": .string("owner"), "system": .string("Linux"), "architecture": .string("aarch64")]
        case .bootstrap: object["state"] = .string("staged")
        case .preparePayload: object["state"] = .string("ready")
        case .quiesce: object["state"] = .string("quiescent")
        case .remove: object["state"] = .string("absent")
        default: object = [:]
        }
        if !object.isEmpty { stdout = try! canonicalData(ManifestValue.object(object)) }
        if invocation.purpose == .packages, case .boundedCapture = invocation.output { status = 1 }
        if invocation.purpose == .native, invocation.arguments.last?.contains("docker.sock") == true { stdout = Data("synthetic-version".utf8) }
        if let fault = faults[invocation.purpose]?.first {
            faults[invocation.purpose]!.removeFirst()
            switch fault {
            case .status(let n): status = n
            case .timeout: reason = .timedOut; status = 143
            case .cancelled: reason = .cancelled; status = 143
            case .notStarted: return ProvisioningProcessResult(invocationID: id, termination: .notStarted)
            case .wrongID: id = UUID()
            case .malformed: stdout = Data("looks successful but is not a receipt".utf8)
            case .wrongOwner: object["uid"] = .integer(0); stdout = try! canonicalData(ManifestValue.object(object))
            case .wrongJob: object["job"] = .string(UUID().uuidString); stdout = try! canonicalData(ManifestValue.object(object))
            case .oversized: stderr = Data(repeating: 120, count: 32769)
            case .capturedStream: stderr = Data("synthetic-secret-never-log".utf8)
            }
        }
        if cancelledIDs.contains(invocation.id) { reason = .cancelled; status = 143 }
        return ProvisioningProcessResult(invocationID: id, termination: .exited(status: status, reason: reason), stdout: stdout, stderr: stderr)
    }
    func interrupt(invocationID: UUID) async {
        interrupts.append(invocationID); cancelledIDs.insert(invocationID); await gate?.recordInterrupt()
    }
}

private final class TransportFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let binding: GuestBinding
    let tools: ProvisioningTransportTools
    let connection: ProvisioningSSHConnection
    let authority: SessionAuthority
    let plan: SetupPlan
    let key: URL
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let wire = Data([0,0,0,11] + Array("ssh-ed25519".utf8) + [0,0,0,32] + Array(repeating: UInt8(7), count: 32))
        binding = try GuestBinding(vmID: UUID(), sessionID: UUID(), owner: "owner", ownerUID: 1000, hostKeyDigest: digest(wire))
        authority = SessionAuthority(binding)
        key = root.appendingPathComponent("owner key%h 'quoted'")
        try Data("synthetic-private-key-never-read".utf8).write(to: key); chmod(key.path, 0o600)
        connection = try ProvisioningSSHConnection(binding: binding, port: 22445, identity: ProvisioningIdentityFile(key), ed25519HostKey: wire)
        var pins: [ProvisioningExecutablePin] = []
        for name in ["ssh", "scp", "sftp", "ansible-playbook", "ansible-inventory"] {
            let path = root.appendingPathComponent(name); try Data("fake-runner-only".utf8).write(to: path); chmod(path.path, 0o700)
            pins.append(try ProvisioningExecutablePin(path))
        }
        tools = ProvisioningTransportTools(ssh: pins[0], scp: pins[1], sftp: pins[2], ansiblePlaybook: pins[3], ansibleInventory: pins[4])
        let repository = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: false)
        let manifest = """
        schema_version: 1
        id: fixture
        vm: {packages: ['pkg:chromium', 'pkg:claude-desktop', 'pkg:1password', 'pkg:1password-cli', 'pkg:jq', 'mise:uv']}
        setup:
          features: {enable: [workstation, cli, languages, docker]}
          options:
            docker: {access: sudoless}
            languages: {tools: {node: '24'}}
        dotfiles: [{source: config, target: ~/.config/fixture, mode: '0600'}]
        tasks: [{name: custom, file: tasks.yml}]
        vars: {secret: synthetic-secret-never-log}
        """
        try Data(manifest.utf8).write(to: repository.appendingPathComponent("vm.yml"))
        try Data("frozen-bytes".utf8).write(to: repository.appendingPathComponent("config"))
        try Data("not even valid YAML: [ {{ synthetic-secret-never-log }}".utf8).write(to: repository.appendingPathComponent("tasks.yml"))
        plan = try SetupPlanner.plan(repository: repository)
    }
    deinit { try? FileManager.default.removeItem(at: root) } // Synthetic UUID roots only.
    func request(check: Bool = false, checkTasks: Bool = false) throws -> ProvisioningRequest {
        try ProvisioningRequest(jobID: UUID(), plan: plan, repository: root.appendingPathComponent("source"), target: binding,
            dependencyDigest: transportPin, mode: check ? .check : .apply, includeTasksInCheck: checkTasks, inputLeaseID: check ? nil : UUID())
    }
    func adapter(_ runner: FakeProcessRunner) throws -> SSHAnsibleGuestAdapter {
        try SSHAnsibleGuestAdapter(connection: connection, tools: tools, authority: authority, runner: runner)
    }
}
private func reviewed(_ request: ProvisioningRequest) -> ProvisioningApproval {
    ProvisioningApproval(reviewIdentity: request.reviewIdentity, customTasksReviewed: true,
                         persistentGrantAcknowledged: true, dockerRootAccessAcknowledged: true)
}
private func jsonFile(_ url: URL) throws -> [String: ManifestValue] { try PlainDataParser.read(url).object! }

@Test func concreteAdapterBuildsPinnedPrivateSSHAndAnsibleInvocations() async throws {
    let fixture = try TransportFixture(), request = try fixture.request(), runner = FakeProcessRunner()
    let adapter = try fixture.adapter(runner)
    let result = await ProvisioningSequencer().run(request, approval: reviewed(request), adapter: adapter)
    #expect(result.outcome == .appliedRestartRequired && result.recovery == nil)
    let invocations = await runner.invocations
    let first = try #require(invocations.first), root = first.workingDirectory
    let config = try String(contentsOf: root.appendingPathComponent("ssh_config"), encoding: .utf8)
    for expected in ["HostName 127.0.0.1", "StrictHostKeyChecking yes", "IdentityAgent none", "ProxyCommand none", "ProxyJump none", "EscapeChar none", "BatchMode yes", "%%h", "ControlMaster no"] { #expect(config.contains(expected)) }
    #expect(!config.contains("synthetic-private-key-never-read"))
    let features = try #require(invocations.first { $0.purpose == .features })
    #expect(features.executable == fixture.tools.playbook.target)
    #expect(features.arguments.contains("--tags") && !features.arguments.contains("--check"))
    let variablePath = String(features.arguments[features.arguments.firstIndex(of: "--extra-vars")! + 1].dropFirst())
    let variables = try jsonFile(URL(fileURLWithPath: variablePath))
    #expect(variables["omarchy_languages"] == .object(["node": .string("24")]))
    #expect(variables["omarchy_defer_docker_access"] == .bool(true))
    let repository = try #require(invocations.first { $0.purpose == .repository })
    let setupVars = try jsonFile(URL(fileURLWithPath: String(repository.arguments[repository.arguments.firstIndex(of: "--extra-vars")! + 1].dropFirst())))
    #expect(setupVars["omarchy_setup_vars"] == .object(["secret": .string("synthetic-secret-never-log")]))
    let fixed = try jsonFile(URL(fileURLWithPath: String(repository.arguments.last!.dropFirst())))
    #expect(fixed["ansible_become"] == nil)
    #expect(fixed["ansible_user"] == .string("owner") && fixed["ansible_host_key_checking"] == .bool(true))
    #expect(fixed["ansible_shell_executable"]?.string?.hasSuffix("/managed-shell") == true)
    let copies = invocations.filter { $0.purpose == .copyPayload }
    #expect(copies.count == 1 && copies[0].arguments.last!.hasPrefix(fixture.connection.alias + ":/tmp/dev-vm-provisioning-"))
    #expect(copies[0].arguments.prefix(2) == ["-S", fixture.tools.ssh.entry.path])
    for invocation in invocations {
        #expect(invocation.context == first.context)
        #expect(!invocation.arguments.joined().contains("synthetic-secret-never-log"))
        #expect(invocation.environment["PYTHONPATH"] == nil && invocation.environment["SSH_AUTH_SOCK"] == nil)
        if case .terminalLease(let id) = invocation.input { #expect(id == request.inputLeaseID && invocation.arguments.contains("-tt")) }
        let info = try FileManager.default.attributesOfItem(atPath: invocation.workingDirectory.path)
        #expect((info[.posixPermissions] as! NSNumber).intValue == 0o700)
    }
    let installs = invocations.filter { $0.purpose == .packages && { if case .terminalStream = $0.output { true } else { false } }($0) }
    for expected in ["browser", "claude", "1password", "omarchy-pkg-add", "mise"] { #expect(installs.contains { $0.arguments.last!.contains(expected) }) }
}

@Test(arguments: [false, true]) func concreteCheckModeNeverRequestsGuestAuthorization(includeTasks: Bool) async throws {
    let fixture = try TransportFixture(), request = try fixture.request(check: true, checkTasks: includeTasks), runner = FakeProcessRunner()
    let adapter = try fixture.adapter(runner)
    let result = await ProvisioningSequencer().run(request, approval: reviewed(request), adapter: adapter)
    #expect(result.outcome == .checked)
    for invocation in await runner.invocations {
        #expect(invocation.purpose != .native && invocation.purpose != .packages)
        if [.features, .repository].contains(invocation.purpose) { #expect(invocation.arguments.last == "--check") }
        if invocation.purpose == .repository {
            let vars = try jsonFile(URL(fileURLWithPath: String(invocation.arguments[invocation.arguments.firstIndex(of: "--extra-vars")! + 1].dropFirst())))
            #expect(vars["omarchy_setup_tasks"]?.array?.count == (includeTasks ? 1 : 0))
        }
        if case .terminalLease = invocation.input { Issue.record("Check requested terminal input") }
    }
}

@Test(arguments: ["identity", "owner", "bootstrap", "large", "stream", "exit", "timeout", "start", "id"])
func processFailuresAndMalformedReceiptsCannotBecomeSuccess(kind: String) async throws {
    let fixture = try TransportFixture(), request = try fixture.request()
    let purpose: ProvisioningProcessPurpose = kind == "bootstrap" ? .bootstrap : (["stream", "exit", "timeout"].contains(kind) ? .features : .identity)
    let fault: RunnerFault
    switch kind {
    case "owner": fault = .wrongOwner
    case "bootstrap": fault = .wrongJob
    case "large": fault = .oversized
    case "stream": fault = .capturedStream
    case "exit": fault = .status(2)
    case "timeout": fault = .timeout
    case "start": fault = .notStarted
    case "id": fault = .wrongID
    default: fault = .malformed
    }
    let runner = FakeProcessRunner([purpose: [fault]]), adapter = try fixture.adapter(runner)
    let result = await ProvisioningSequencer().run(request, approval: reviewed(request), adapter: adapter)
    #expect(![.applied, .appliedRestartRequired, .checked].contains(result.outcome))
    #expect(!String(decoding: try canonicalData(result), as: UTF8.self).contains("synthetic-secret-never-log"))
}

@Test func toolReplacementAndSessionLossStopBeforeNextInvocation() async throws {
    let fixture = try TransportFixture(), request = try fixture.request(), runner = FakeProcessRunner()
    let adapter = try fixture.adapter(runner)
    try Data("replaced".utf8).write(to: fixture.root.appendingPathComponent("ansible-playbook"))
    let result = await ProvisioningSequencer().run(request, approval: reviewed(request), adapter: adapter)
    #expect(result.primaryFailure == .dependencyChanged)
    #expect(await runner.invocations.isEmpty)
    let other = try TransportFixture(), otherRequest = try other.request(), otherRunner = FakeProcessRunner()
    let otherAdapter = try other.adapter(otherRunner)
    await other.authority.invalidate()
    let denied = await ProvisioningSequencer().run(otherRequest, approval: reviewed(otherRequest), adapter: otherAdapter)
    #expect(denied.primaryFailure == .identityMismatch)
    #expect(await otherRunner.invocations.isEmpty)
}

@Test func copiedInputsStayFrozenAndSourceChangePreventsGrant() async throws {
    let fixture = try TransportFixture(), request = try fixture.request(), source = fixture.root.appendingPathComponent("source/config")
    let runner = FakeProcessRunner(hook: { invocation in
        if invocation.purpose == .bootstrap { try Data("changed-after-copy".utf8).write(to: source) }
    }), adapter = try fixture.adapter(runner)
    let result = await ProvisioningSequencer().run(request, approval: reviewed(request), adapter: adapter)
    #expect(result.primaryFailure == .sourceChanged)
    let calls = await runner.invocations
    #expect(!calls.contains { $0.purpose == .native })
    #expect(try Data(contentsOf: #require(calls.first).workingDirectory.appendingPathComponent("repository/config")) == Data("frozen-bytes".utf8))
}

@Test func localCancellationWaitsForMatchingExitBeforeCleanup() async throws {
    let fixture = try TransportFixture(), request = try fixture.request(), gate = RunnerGate()
    let runner = FakeProcessRunner(pauseAt: .features, gate: gate), adapter = try fixture.adapter(runner), sequencer = ProvisioningSequencer()
    let task = Task { await sequencer.run(request, approval: reviewed(request), adapter: adapter) }
    await gate.waitEntered(); task.cancel(); await gate.waitInterrupted()
    #expect((await runner.invocations).last?.purpose == .features)
    #expect(await sequencer.phase != .finished)
    #expect((await runner.interrupts).count == 1)
    await gate.release()
    let result = await task.value
    #expect(result.outcome == .cancelled && result.recovery == nil)
    #expect((await runner.invocations).contains { $0.purpose == .quiesce })
}

@Test func quiescenceMustBeStructuredAndPayloadRemovalIsNotAssumed() async throws {
    let fixture = try TransportFixture(), request = try fixture.request(), runner = FakeProcessRunner([.quiesce: [.status(1)]])
    let adapter = try fixture.adapter(runner)
    let result = await ProvisioningSequencer().run(request, approval: reviewed(request), adapter: adapter)
    #expect(result.outcome == .cleanupRequired && result.recovery != nil)
    #expect(!(await runner.invocations).contains { $0.purpose == .remove })
}

@Test func privateWorkspaceTamperingRequiresFreshPinnedRecovery() async throws {
    let fixture = try TransportFixture(), request = try fixture.request()
    let runner = FakeProcessRunner(hook: { invocation in
        if invocation.purpose == .preparePayload { try Data("Host *\n ProxyCommand unsafe\n".utf8).write(to: invocation.workingDirectory.appendingPathComponent("ssh_config")) }
    }), adapter = try fixture.adapter(runner)
    let result = await ProvisioningSequencer().run(request, approval: reviewed(request), adapter: adapter)
    #expect(result.outcome == .cleanupRequired)
    let recovery = try #require(result.recovery), recoveryRunner = FakeProcessRunner(), recoveryAdapter = try fixture.adapter(recoveryRunner)
    let cleaned = await ProvisioningSequencer().recover(recovery, adapter: recoveryAdapter)
    #expect(cleaned.outcome == .cleanupConfirmed)
    #expect(!(await recoveryRunner.invocations).contains { [.features, .repository, .bootstrap, .copyPayload].contains($0.purpose) })
}

@Test func bundledProvisioningResourcesMatchMaintainedSources() throws {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let base = source.appendingPathComponent("Sources/DevVMProvisioningCore/Resources/Provisioning")
    let inventory = try jsonFile(base.appendingPathComponent("inventory.json"))
    for (path, sha) in inventory {
        #expect(.string(digest(try Data(contentsOf: source.appendingPathComponent(path)))) == sha)
        #expect(try Data(contentsOf: source.appendingPathComponent(path)) == Data(contentsOf: base.appendingPathComponent(path)))
    }
}

@Test func executablePinsPreserveLauncherNamesAndRejectRetargeting() throws {
    let fixture = try TransportFixture()
    let entry = fixture.root.appendingPathComponent("ansible-alias")
    try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: fixture.root.appendingPathComponent("ansible-playbook"))
    let pin = try ProvisioningExecutablePin(entry)
    #expect(try pin.verify() == entry)
    try FileManager.default.removeItem(at: entry)
    try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: fixture.root.appendingPathComponent("ansible-inventory"))
    #expect(throws: SequencingFailure.self) { try pin.verify() }
    #expect(throws: SequencingFailure.self) { try ProvisioningIdentityFile(entry) }
}

@Test func partialStageCannotClaimCleanupWithoutSupervisorProof() async throws {
    let fixture = try TransportFixture(), request = try fixture.request()
    let runner = FakeProcessRunner([.bootstrap: [.timeout], .quiesce: [.status(1)]]), adapter = try fixture.adapter(runner)
    let result = await ProvisioningSequencer().run(request, approval: reviewed(request), adapter: adapter)
    #expect(result.outcome == .cleanupRequired && result.primaryFailure == .timedOut)
    let calls = await runner.invocations
    #expect(!calls.contains { [.native, .features, .repository, .remove, .copyPayload].contains($0.purpose) })
}

@Test func cancellationBetweenProcessesPreventsNextLaunch() async throws {
    let fixture = try TransportFixture(), request = try fixture.request(), gate = RunnerGate(), authority = fixture.authority
    let runner = FakeProcessRunner(asyncHook: { invocation in
        if invocation.purpose == .bootstrap { await authority.pauseNextValidation(gate) }
    }), adapter = try fixture.adapter(runner), sequencer = ProvisioningSequencer()
    let task = Task { await sequencer.run(request, approval: reviewed(request), adapter: adapter) }
    await gate.waitEntered()
    await sequencer.requestCancellation()
    #expect(await runner.interrupts.isEmpty) // The completed bootstrap is not killed again.
    await gate.release()
    #expect(await task.value.outcome == .cancelled)
    #expect(!(await runner.invocations).contains { [.copyPayload, .native, .features, .repository].contains($0.purpose) })
}
