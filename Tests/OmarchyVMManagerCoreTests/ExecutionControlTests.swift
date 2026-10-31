import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

private actor ExecutionProbe: SSHReadinessChecking {
    var callbacks: [@Sendable (SSHReadiness) async -> Void] = []
    func monitor(_ request: VMStartRequest, update: @escaping @Sendable (SSHReadiness) async -> Void) async {
        callbacks.append(update)
        await update(.connecting)
        do { try await Task.sleep(for: .seconds(30)) } catch {}
    }
    func count() -> Int { callbacks.count }
    func publish(_ index: Int) async { await callbacks[index](.ready(user: "owner", command: "synthetic command")) }
}

@Suite("Manual execution lifecycle")
struct ExecutionControlTests {
    let profile = VMProfile(id: UUID(), name: "Pause fixture")
    let support = URL(fileURLWithPath: "/private/tmp/pause-fixture-never-created")

    private func running() async throws -> (VMManager, FakeRuntimeHandle) {
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: support)
        try await manager.start(profile.id)
        let handle = try #require(runtime.startedHandles.first)
        handle.emit(.ready)
        #expect(await eventually { await manager.snapshots()[0].state == .running })
        return (manager, handle)
    }

    @Test("pause acknowledgement retains allocation and rejects edits until terminal exit")
    func pauseRetainsSession() async throws {
        let (manager, handle) = try await running()
        let session = await manager.snapshots()[0].sessionID
        let task = Task { try await manager.pause(profile.id) }
        #expect(await eventually { handle.pauseCount == 1 })
        #expect(await manager.snapshots()[0].state == .pausing)
        handle.emit(.executionState(.init(state: .paused, command: .pause)))
        try await task.value
        #expect(await manager.snapshots()[0].state == .paused)
        #expect(await manager.activeSessionCount == 1)
        #expect(await manager.allocatedMemoryMiB == 4096)
        #expect(await manager.snapshots()[0].sessionID == session)
        await #expect(throws: VMFailure.self) { try await manager.configure(profile) }
        await #expect(throws: VMFailure.self) { try await manager.deletionRequest(profile.id) }
        await manager.shutDown(profile.id)
        #expect(handle.shutdownCount == 1)
        #expect(await manager.activeSessionCount == 1)
        handle.emit(.executionState(.init(state: .running, command: .resume)))
        #expect(await manager.snapshots()[0].state == .stopping)
        handle.emit(.exited(status: 0))
        #expect(await eventually { await manager.activeSessionCount == 0 })
    }

    @Test("timeout remains active and rejects a second command until its late acknowledgement")
    func lateReply() async throws {
        let (manager, handle) = try await running()
        await #expect(throws: VMFailure.self) { try await manager.pause(profile.id, timeout: .milliseconds(20)) }
        #expect(await manager.snapshots()[0].state == .executionUnknown)
        #expect(await manager.activeSessionCount == 1)
        await #expect(throws: VMFailure.self) { try await manager.pause(profile.id) }
        #expect(handle.pauseCount == 1)
        handle.emit(.executionState(.init(state: .paused, command: .pause)))
        #expect(await eventually { await manager.snapshots()[0].state == .paused })
        let resume = Task { try await manager.resume(profile.id) }
        #expect(await eventually { handle.resumeCount == 1 })
        handle.emit(.executionState(.init(state: .running, command: .resume)))
        try await resume.value
        #expect(await manager.snapshots()[0].state == .running)
        handle.emit(.exited(status: 0))
    }

    @Test("shutdown cancels a pending control and ignores its late reply", arguments: [false, true])
    func stoppingWins(force: Bool) async throws {
        let (manager, handle) = try await running()
        let task = Task { try await manager.pause(profile.id) }
        #expect(await eventually { handle.pauseCount == 1 })
        if force { try await manager.forceStop(profile.id, confirmed: true) }
        else { await manager.shutDown(profile.id) }
        await #expect(throws: VMFailure.self) { try await task.value }
        handle.emit(.executionState(.init(state: .paused, command: .pause)))
        #expect(await manager.snapshots()[0].state == .stopping)
        #expect(await manager.activeSessionCount == 1)
        #expect(await manager.allocatedMemoryMiB == 4096)
        handle.emit(.exited(status: 0))
        #expect(await eventually { await manager.activeSessionCount == 0 })
    }

    @Test("control rejection is nonfatal and can be retried")
    func rejection() async throws {
        let (manager, handle) = try await running()
        let task = Task { try await manager.pause(profile.id) }
        #expect(await eventually { handle.pauseCount == 1 })
        handle.emit(.executionState(.init(state: .running, command: .pause, failure: .init(code: .launchFailed, message: "synthetic rejection", reportedCode: "execution-control-failed"))))
        await #expect(throws: VMFailure.self) { try await task.value }
        #expect(await manager.snapshots()[0].state == .running)
        #expect(await manager.snapshots()[0].lastFailure == nil)
        let retry = Task { try await manager.pause(profile.id) }
        #expect(await eventually { handle.pauseCount == 2 })
        handle.emit(.executionState(.init(state: .paused, command: .pause)))
        try await retry.value
        #expect(await manager.snapshots()[0].notice == nil)
        handle.emit(.exited(status: 0))
    }

    @Test("early controls are refused, and exit completes a pending caller")
    func readinessAndExit() async throws {
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: support)
        await #expect(throws: VMFailure.self) { try await manager.pause(profile.id) }
        try await manager.start(profile.id)
        let handle = try #require(runtime.startedHandles.first)
        await #expect(throws: VMFailure.self) { try await manager.pause(profile.id) }
        #expect(handle.pauseCount == 0)
        handle.emit(.ready)
        #expect(await eventually { await manager.snapshots()[0].state == .running })
        let task = Task { try await manager.pause(profile.id) }
        #expect(await eventually { handle.pauseCount == 1 })
        handle.emit(.exited(status: 1))
        await #expect(throws: VMFailure.self) { try await task.value }
        #expect(await eventually { await manager.activeSessionCount == 0 })
    }

    @Test("host sleep is separate from manual pause and application quit holds both sessions")
    func hostSleepAndQuit() async throws {
        let runtime = FakeRuntime()
        let other = VMProfile(id: UUID(), name: "Second pause fixture")
        let manager = VMManager(runtime: runtime, profiles: [profile, other], applicationSupport: support)
        try await manager.start(profile.id); try await manager.start(other.id)
        let first = runtime.startedHandles[0], second = runtime.startedHandles[1]
        first.emit(.ready); second.emit(.ready)
        #expect(await eventually { await manager.snapshots().allSatisfy { $0.state == .running } })
        let pause = Task { try await manager.pause(profile.id) }
        #expect(await eventually { first.pauseCount == 1 })
        first.emit(.executionState(.init(state: .paused, command: .pause))); try await pause.value
        // Progress and duplicate ready events cannot undo the acknowledged pause.
        first.emit(.progress(.starting, percent: 100)); first.emit(.ready)
        second.emit(.executionState(.init(state: .hostSleeping)))
        #expect(await eventually { await manager.snapshots()[1].state == .hostSleeping })
        #expect(await manager.snapshots()[0].state == .paused)
        await #expect(throws: VMFailure.self) { try await manager.resume(other.id) }
        second.emit(.executionState(.init(state: .running)))
        #expect(await eventually { await manager.snapshots()[1].state == .running })
        #expect(!(await manager.beginApplicationShutdown()))
        #expect(first.shutdownCount == 1 && second.shutdownCount == 1)
        #expect(await manager.allocatedMemoryMiB == 8192)
        first.emit(.exited(status: 0))
        #expect(await eventually { await manager.activeSessionCount == 1 })
        #expect(!(await manager.isIdle))
        second.emit(.exited(status: 0))
        #expect(await eventually { await manager.isIdle })
    }

    @Test("paused probes cannot publish stale SSH readiness after resume")
    func probeGeneration() async throws {
        var sshProfile = profile; sshProfile.ssh = SSHOptions(hostPort: 23981)
        let runtime = FakeRuntime(), probe = ExecutionProbe()
        let manager = VMManager(runtime: runtime, profiles: [sshProfile], applicationSupport: support, sshProbe: probe)
        try await manager.start(profile.id)
        let handle = try #require(runtime.startedHandles.first); handle.emit(.ready)
        #expect(await eventually { await probe.count() == 1 })
        #expect(await eventually { await manager.snapshots()[0].state == .running })
        let task = Task { try await manager.pause(profile.id) }
        #expect(await eventually { handle.pauseCount == 1 })
        handle.emit(.executionState(.init(state: .paused, command: .pause))); try await task.value
        await probe.publish(0)
        #expect(await manager.snapshots()[0].sshReadiness == .paused)
        let resumed = Task { try await manager.resume(profile.id) }
        #expect(await eventually { handle.resumeCount == 1 })
        handle.emit(.executionState(.init(state: .running, command: .resume))); try await resumed.value
        #expect(await eventually { await probe.count() == 2 })
        await probe.publish(0)
        #expect(await manager.snapshots()[0].sshReadiness != .ready(user: "owner", command: "synthetic command"))
        await probe.publish(1)
        #expect(await manager.snapshots()[0].sshReadiness == .ready(user: "owner", command: "synthetic command"))
        handle.emit(.exited(status: 0))
    }
}
