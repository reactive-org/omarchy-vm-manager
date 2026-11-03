import CDevVMProcess
import Darwin
import Foundation
import Testing
@testable import DevVMProvisioningCore

private final class LocalFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dev-vm-local-test-" + UUID().uuidString)
    let executable: URL
    let launcher: ProvisioningExecutablePin
    let context: GuestJobContext
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        executable = root.appendingPathComponent("fixture with spaces")
        var directory = Bundle.module.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("DevVMProcessFixture").path) { break }
            directory.deleteLastPathComponent()
        }
        try FileManager.default.copyItem(at: directory.appendingPathComponent("DevVMProcessFixture"), to: executable)
        chmod(executable.path, 0o700)
        let launcherURL = root.appendingPathComponent("pty-launcher")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("dev-vm-process-host"), to: launcherURL)
        chmod(launcherURL.path, 0o700)
        launcher = try ProvisioningExecutablePin(launcherURL)
        let binding = try GuestBinding(vmID: UUID(), sessionID: UUID(), owner: "fixture", ownerUID: 1000, hostKeyDigest: String(repeating: "a", count: 64))
        context = GuestJobContext(jobID: UUID(), payloadID: UUID(), target: binding, dependencyDigest: String(repeating: "b", count: 64), mode: .apply)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func invocation(_ args: [String], input: ProvisioningProcessInput = .closed, output: ProvisioningProcessOutput = .boundedCapture,
                    timeout: Int = 5, id: UUID = UUID(), executable: URL? = nil) -> ProvisioningProcessInvocation {
        ProvisioningProcessInvocation(id: id, commandID: UUID(), context: context, purpose: .native,
            executable: executable ?? self.executable, arguments: args, environment: ["FIXTURE": "only-explicit-value", "LC_ALL": "C"],
            workingDirectory: root, input: input, output: output, timeoutSeconds: timeout)
    }
}
private func termination(_ result: ProvisioningProcessResult, status: Int32, reason: ProvisioningExitReason = .normal,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    guard case .exited(let actual, let failure) = result.termination else { Issue.record("No confirmed local exit", sourceLocation: sourceLocation); return }
    #expect(actual == status, sourceLocation: sourceLocation)
    #expect(failure == reason, sourceLocation: sourceLocation)
}
private func waitFor(_ terminal: ProvisioningTerminal, _ text: String) async throws {
    let end = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < end {
        let data = terminal.snapshot().frames.reduce(into: Data()) { $0.append($1.bytes) }
        if String(decoding: data, as: UTF8.self).contains(text) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw SequencingFailure.timedOut
}
private func noLiveFixtureChild(_ fixture: LocalFixture) throws {
    let text = try String(contentsOf: fixture.root.appendingPathComponent("child.pid"), encoding: .utf8)
    let pid = try #require(Int32(text))
    // Zombies cannot run or retain descriptors. launchd owns orphan reaping.
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    #expect(n == 0 || info.pbi_status == SZOMB)
}

@Test func localRunnerUsesExactArgvEnvironmentAndSeparateCapture() async throws {
    let fixture = try LocalFixture(), runner = LocalProvisioningProcessRunner()
    let literal = "quotes ' \" $HOME $(touch forbidden) ; \n ☃"
    let invocation = fixture.invocation(["exact", literal])
    let result = await runner.run(invocation)
    termination(result, status: 7)
    #expect(String(decoding: result.stdout, as: UTF8.self) == literal + "\nonly-explicit-value\nabsent\n")
    #expect(String(decoding: result.stderr, as: UTF8.self) == "separate-error")
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("forbidden").path))
    let replay = await runner.run(invocation)
    if case .notStarted = replay.termination {} else { Issue.record("Replayed invocation launched") }
}

@Test(arguments: [0, 60_000]) func localRunnerClosesStdinAndWritesBoundedBytes(count: Int) async throws {
    let fixture = try LocalFixture(), runner = LocalProvisioningProcessRunner()
    let result = await runner.run(fixture.invocation(["stdin"], input: count == 0 ? .closed : .bytes(Data(repeating: 120, count: count))))
    termination(result, status: 0)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "bytes=\(count)")
}

@Test func localCaptureOverflowCannotBecomeSuccess() async throws {
    let fixture = try LocalFixture(), runner = LocalProvisioningProcessRunner()
    let result = await runner.run(fixture.invocation(["flood"]))
    guard case .exited(_, let reason) = result.termination else { Issue.record("Overflow did not reap"); return }
    #expect(reason == .outputLimit)
    #expect(result.stdout.count + result.stderr.count == 32 * 1024)
    #expect(!String(reflecting: result).contains(String(repeating: "x", count: 100)))
}

@Test func localStreamingPreservesBytesWithoutStructuredOutput() async throws {
    let fixture = try LocalFixture(), terminal = try ProvisioningTerminal(), runner = LocalProvisioningProcessRunner(terminal: terminal)
    let result = await runner.run(fixture.invocation(["ansi"], output: .terminalStream))
    termination(result, status: 0)
    #expect(result.stdout.isEmpty && result.stderr.isEmpty)
    let bytes = terminal.snapshot().frames.reduce(into: Data()) { $0.append($1.bytes) }
    #expect(bytes == Data("\u{1b}[32mworking\u{1b}[0m\rprogress ☃\n".utf8))
    #expect(!terminal.snapshot().gap)
}

@Test func localSlowViewersHaveBoundedMemoryAndExplicitGaps() async throws {
    let fixture = try LocalFixture(), terminal = try ProvisioningTerminal(capacityBytes: 8192), runner = LocalProvisioningProcessRunner(terminal: terminal)
    let result = await runner.run(fixture.invocation(["flood"], output: .terminalStream))
    termination(result, status: 0)
    let snapshot = terminal.snapshot()
    #expect(snapshot.gap)
    #expect(snapshot.frames.reduce(0) { $0 + $1.bytes.count } <= 8192)
    #expect(result.stdout.isEmpty && result.stderr.isEmpty)
    #expect(terminal.snapshot(after: snapshot.lastSequence).frames.isEmpty)
}

@Test func localPTYHasControllingTerminalResizeAndNoInputEcho() async throws {
    let fixture = try LocalFixture(), terminal = try ProvisioningTerminal(), lease = UUID()
    let size = try ProvisioningTerminalSize(rows: 32, columns: 110)
    try Data("schema_version: 1\nid: fixture\n".utf8).write(to: fixture.root.appendingPathComponent("vm.yml"))
    let plan = try SetupPlanner.plan(repository: fixture.root)
    let request = try ProvisioningRequest(jobID: fixture.context.jobID, plan: plan, repository: fixture.root,
        target: fixture.context.target, dependencyDigest: fixture.context.dependencyDigest, inputLeaseID: lease)
    try terminal.grantInput(for: request, size: size)
    let runner = LocalProvisioningProcessRunner(terminal: terminal, ptyLauncher: fixture.launcher)
    let invocation = fixture.invocation(["tty"], input: .terminalLease(lease), output: .terminalStream)
    let task = Task { await runner.run(invocation) }
    do {
        try await waitFor(terminal, "READY 32 110 noecho")
        #expect(terminal.snapshot().activeInvocationID == invocation.id && terminal.snapshot().acceptsInput)
        try terminal.resize(leaseID: lease, invocationID: invocation.id, sequence: 1, size: ProvisioningTerminalSize(rows: 45, columns: 120))
        // Wake the fixture's interrupted read and let it report SIGWINCH.
        try terminal.sendInput(leaseID: lease, invocationID: invocation.id, sequence: 2, bytes: Data("s".utf8))
        try await waitFor(terminal, "SIZE 45 120")
        #expect(throws: SequencingFailure.self) { try terminal.sendInput(leaseID: UUID(), invocationID: invocation.id, sequence: 3, bytes: Data("forbidden".utf8)) }
        #expect(throws: SequencingFailure.self) { try terminal.sendInput(leaseID: lease, invocationID: invocation.id, sequence: 2, bytes: Data("replay".utf8)) }
        try terminal.sendInput(leaseID: lease, invocationID: invocation.id, sequence: 3, bytes: Data("ynthetic-secret-never-echo\n".utf8))
        let result = await task.value
        termination(result, status: 0)
        let bytes = terminal.snapshot().frames.reduce(into: Data()) { $0.append($1.bytes) }
        #expect(!String(decoding: bytes, as: UTF8.self).contains("synthetic-secret"))
        #expect(result.stdout.isEmpty && result.stderr.isEmpty)
        #expect(throws: SequencingFailure.self) { try terminal.sendInput(leaseID: lease, invocationID: invocation.id, sequence: 4, bytes: Data([10])) }
    } catch {
        task.cancel()
        let failed = await task.value
        if case .exited(let status, _) = failed.termination { Issue.record("PTY fixture exit status \(status)") }
        else if case .notStarted = failed.termination { Issue.record("PTY fixture did not start") }
        else { Issue.record("PTY fixture cleanup unconfirmed") }
        throw error
    }
}

@Test func localLeaseRevocationDiscardsPendingInputAndDoesNotCancelJob() async throws {
    let fixture = try LocalFixture(), terminal = try ProvisioningTerminal(), lease = UUID()
    try terminal.grantInput(leaseID: lease, context: fixture.context, size: ProvisioningTerminalSize(rows: 24, columns: 80))
    let runner = LocalProvisioningProcessRunner(terminal: terminal, ptyLauncher: fixture.launcher)
    let invocation = fixture.invocation(["tty"], input: .terminalLease(lease), output: .terminalStream, timeout: 1)
    let task = Task { await runner.run(invocation) }
    do {
        try await waitFor(terminal, "READY")
        terminal.revokeInput(leaseID: lease)
        #expect(throws: SequencingFailure.self) { try terminal.sendInput(leaseID: lease, invocationID: invocation.id, sequence: 1, bytes: Data([10])) }
        let result = await task.value
        guard case .exited(_, let reason) = result.termination else { Issue.record("Revoked PTY did not exit"); return }
        #expect(reason == .timedOut)
        #expect(throws: SequencingFailure.self) { try terminal.grantInput(leaseID: lease, context: fixture.context, size: ProvisioningTerminalSize(rows: 24, columns: 80)) }
    } catch { task.cancel(); _ = await task.value; throw error }
}

@Test(arguments: [false, true]) func localCancellationKillsOnlyMatchingOwnedGroup(taskCancellation: Bool) async throws {
    let fixture = try LocalFixture(), terminal = try ProvisioningTerminal(), runner = LocalProvisioningProcessRunner(terminal: terminal)
    let invocation = fixture.invocation(["linger"], output: .terminalStream)
    let task = Task { await runner.run(invocation) }
    do {
        try await waitFor(terminal, "RUNNING")
        await runner.interrupt(invocationID: UUID())
        if taskCancellation { task.cancel() } else { await runner.interrupt(invocationID: invocation.id) }
        let result = await task.value
        guard case .exited(_, let reason) = result.termination else { Issue.record("Cancellation did not confirm exit"); return }
        #expect(reason == .cancelled)
        try noLiveFixtureChild(fixture)
        let next = await runner.run(fixture.invocation(["exit"]))
        termination(next, status: 0)
    } catch { task.cancel(); _ = await task.value; throw error }
}

@Test func localTimeoutAndParentExitCleanLingeringDescendants() async throws {
    for mode in ["linger", "parent-exit"] {
        let fixture = try LocalFixture(), runner = LocalProvisioningProcessRunner()
        let result = await runner.run(fixture.invocation([mode], timeout: 1))
        guard case .exited(_, let reason) = result.termination else { Issue.record("Descendants not cleaned"); continue }
        #expect(reason == (mode == "linger" ? .timedOut : .ioFailure))
        try noLiveFixtureChild(fixture)
    }
}

@Test func localLaunchFailuresMissingLeaseAndInvalidInputNeverLaunch() async throws {
    let fixture = try LocalFixture(), runner = LocalProvisioningProcessRunner()
    let cases = [fixture.invocation(["exit"], executable: fixture.root.appendingPathComponent("missing")),
                 fixture.invocation(["exit"], timeout: 0), fixture.invocation(["exact", "invalid\0argv"]),
                 fixture.invocation(["stdin"], input: .bytes(Data(repeating: 0, count: 65537))),
                 fixture.invocation(["tty"], input: .terminalLease(UUID()), output: .terminalStream)]
    for invocation in cases {
        let result = await runner.run(invocation)
        if case .notStarted = result.termination {} else { Issue.record("Invalid request launched") }
    }
    let terminal = try ProvisioningTerminal(), attached = LocalProvisioningProcessRunner(terminal: terminal)
    let result = await attached.run(fixture.invocation(["tty"], input: .terminalLease(UUID()), output: .terminalStream))
    if case .notStarted = result.termination {} else { Issue.record("Missing input owner launched") }
    let signal = await runner.run(fixture.invocation(["signal"]))
    termination(signal, status: 128 + SIGTERM)
}

@Test func localConcurrentInvocationIsRefusedAndStaleInterruptCannotRetarget() async throws {
    let fixture = try LocalFixture(), terminal = try ProvisioningTerminal(), runner = LocalProvisioningProcessRunner(terminal: terminal)
    let invocation = fixture.invocation(["wait"], output: .terminalStream)
    let task = Task { await runner.run(invocation) }
    do {
        try await waitFor(terminal, "RUNNING")
        let denied = await runner.run(fixture.invocation(["exit"]))
        if case .notStarted = denied.termination {} else { Issue.record("Concurrent launch admitted") }
        let otherRunner = LocalProvisioningProcessRunner()
        let sameSession = await otherRunner.run(fixture.invocation(["exit"]))
        if case .notStarted = sameSession.termination {} else { Issue.record("Fresh runner bypassed session ownership") }
        await runner.interrupt(invocationID: invocation.id); _ = await task.value
        await runner.interrupt(invocationID: invocation.id)
        let next = await runner.run(fixture.invocation(["exit"]))
        termination(next, status: 0)
        termination(await otherRunner.run(fixture.invocation(["exit"])), status: 0)
    } catch { task.cancel(); _ = await task.value; throw error }
}

@Test func localPreCancelledInvocationDoesNotEscapeCancellation() async throws {
    let fixture = try LocalFixture(), runner = LocalProvisioningProcessRunner()
    let task = Task { await runner.run(fixture.invocation(["wait"])) }
    task.cancel()
    let result = await task.value
    switch result.termination {
    case .notStarted: break
    case .exited(_, let reason): #expect(reason == .cancelled)
    case .cleanupUnconfirmed: Issue.record("Pre-cancelled local process was lost")
    }
}

@Test func localDescriptorsAreClosedAndLauncherAdmissionIsRechecked() async throws {
    let fixture = try LocalFixture(), runner = LocalProvisioningProcessRunner()
    let fd = open(fixture.executable.path, O_RDONLY)
    #expect(fd >= 0)
    let inherited = fcntl(fd, F_DUPFD, 1024); close(fd)
    #expect(inherited >= 1024)
    defer { if inherited >= 0 { close(inherited) } }
    let result = await runner.run(fixture.invocation(["fdcheck", String(inherited)]))
    termination(result, status: 0)
    let terminal = try ProvisioningTerminal(), lease = UUID()
    try terminal.grantInput(leaseID: lease, context: fixture.context, size: ProvisioningTerminalSize(rows: 24, columns: 80))
    let attached = LocalProvisioningProcessRunner(terminal: terminal, ptyLauncher: fixture.launcher)
    try Data("changed launcher".utf8).write(to: fixture.root.appendingPathComponent("pty-launcher"))
    let changed = await attached.run(fixture.invocation(["tty"], input: .terminalLease(lease), output: .terminalStream))
    if case .notStarted = changed.termination {} else { Issue.record("Changed launcher executed") }
    #expect(terminal.snapshot().activeInvocationID == nil)
    #expect(throws: SequencingFailure.self) { _ = try ProvisioningTerminalSize(rows: 0, columns: 80) }
}

@Test func localUncertainPipeRetainsOwnershipUntilExactCleanup() async throws {
    let fixture = try LocalFixture(), runner = LocalProvisioningProcessRunner()
    let invocation = fixture.invocation(["detached-pipe"])
    let result = await runner.run(invocation)
    guard case .cleanupUnconfirmed = result.termination else { Issue.record("Detached pipe was falsely confirmed exited"); return }
    #expect(await runner.reconcileLocalCleanup(invocationID: UUID()) == false)
    let fresh = LocalProvisioningProcessRunner()
    let blocked = await fresh.run(fixture.invocation(["exit"]))
    if case .notStarted = blocked.termination {} else { Issue.record("Uncertain ownership bypassed") }
    let deadline = ContinuousClock.now + .seconds(6)
    var reconciled = false
    while ContinuousClock.now < deadline {
        if await runner.reconcileLocalCleanup(invocationID: invocation.id) { reconciled = true; break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(reconciled)
    try noLiveFixtureChild(fixture)
    termination(await fresh.run(fixture.invocation(["exit"])), status: 0)
}

@Test func localReservedInputNeedsExplicitLiveOwnerAndSuspendDiscardsPendingBytes() throws {
    let fixture = try LocalFixture(), terminal = try ProvisioningTerminal(), lease = UUID()
    try Data("schema_version: 1\nid: fixture\n".utf8).write(to: fixture.root.appendingPathComponent("vm.yml"))
    let request = try ProvisioningRequest(jobID: fixture.context.jobID, plan: SetupPlanner.plan(repository: fixture.root), repository: fixture.root,
        target: fixture.context.target, dependencyDigest: fixture.context.dependencyDigest, inputLeaseID: lease)
    try terminal.reserveInput(for: request)
    let invocation = fixture.invocation(["tty"], input: .terminalLease(lease), output: .terminalStream)
    _ = try terminal.begin(invocation)
    defer { terminal.end(invocation.id) }
    #expect(!terminal.snapshot().acceptsInput)
    #expect(throws: SequencingFailure.self) { try terminal.sendInput(leaseID: lease, invocationID: invocation.id, sequence: 1, bytes: Data([10])) }
    let size = try ProvisioningTerminalSize(rows: 35, columns: 100)
    try terminal.resumeInput(leaseID: lease, size: size)
    try terminal.sendInput(leaseID: lease, invocationID: invocation.id, sequence: 1, bytes: Data("stale-keystroke-canary\n".utf8))
    try terminal.resize(leaseID: lease, invocationID: invocation.id, sequence: 2, size: ProvisioningTerminalSize(rows: 50, columns: 130))
    terminal.suspendInput(leaseID: lease)
    var master: Int32 = -1, slave: Int32 = -1
    guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw SequencingFailure.invalidRequest }
    defer { close(master); close(slave) }
    #expect(fcntl(slave, F_SETFL, O_NONBLOCK) == 0)
    try terminal.resumeInput(leaseID: lease, size: size)
    #expect(terminal.flushInput(invocation.id, fd: master))
    var buffer = [UInt8](repeating: 0, count: 64)
    #expect(read(slave, &buffer, buffer.count) == -1 && errno == EAGAIN)
    try terminal.sendInput(leaseID: lease, invocationID: invocation.id, sequence: 3, bytes: Data("fresh".utf8))
    #expect(terminal.flushInput(invocation.id, fd: master))
    usleep(10_000)
    let count = read(slave, &buffer, buffer.count)
    #expect(count == 5 && Data(buffer.prefix(max(0, count))) == Data("fresh".utf8))
    terminal.revokeInput(leaseID: lease)
    #expect(throws: SequencingFailure.self) { try terminal.resumeInput(leaseID: lease, size: size) }
}

@Test func localRunnerAcceptsCanonicalAdapterWorkspaceWithoutExecutingTransports() async throws {
    let fixture = try LocalFixture(), workspace = try TransportWorkspace(), runner = LocalProvisioningProcessRunner()
    #expect(workspace.root.path == workspace.root.standardizedFileURL.path)
    let invocation = ProvisioningProcessInvocation(id: UUID(), commandID: UUID(), context: fixture.context, purpose: .native,
        executable: fixture.executable, arguments: ["exit"], environment: [:], workingDirectory: workspace.root,
        input: .closed, output: .boundedCapture, timeoutSeconds: 2)
    termination(await runner.run(invocation), status: 0)
    try workspace.verify()
}
