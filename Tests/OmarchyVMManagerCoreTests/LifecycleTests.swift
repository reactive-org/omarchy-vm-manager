import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

func eventually(_ predicate: @escaping () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Suite("Manager lifecycle")
struct LifecycleTests {
    let profile = POCProfiles.all[0]
    let root = URL(fileURLWithPath: "/private/tmp/manager-lifecycle-fixture")

    @Test("errors retain the session and allocation until terminal exit")
    func retainsUntilExit() async throws {
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: root)
        try await manager.start(profile.id)
        let handle = try #require(runtime.startedHandles.first)
        handle.emit(.ready)
        #expect(await eventually { await manager.snapshots()[0].state == .running })
        handle.emit(.error(VMRunError(code: .launchFailed, message: "Test failure")))
        #expect(await eventually { await manager.snapshots()[0].lastFailure != nil })
        #expect(await manager.activeSessionCount == 1)
        #expect(await manager.allocatedMemoryMiB == 4096)
        #expect(await manager.snapshots()[0].state == .running)
        handle.emit(.exited(status: 1))
        #expect(await eventually { await manager.activeSessionCount == 0 })
        #expect(await manager.allocatedMemoryMiB == 0)
        guard case .failed(let error) = await manager.snapshots()[0].state else {
            Issue.record("Expected a stopped failure after exit"); return
        }
        #expect(error.message == "Test failure")
    }

    @Test("ordered synchronous callbacks cannot outrun session retention")
    func synchronousEvents() async throws {
        let runtime = FakeRuntime(initialEvents: [.progress(.downloading, percent: 25), .ready, .stopping, .exited(status: 0)])
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: root)
        try await manager.start(profile.id)
        #expect(await eventually { await manager.activeSessionCount == 0 })
        #expect(await manager.snapshots()[0].state == .stopped)
    }

    @Test("duplicate commands do not create sessions or repeat shutdown")
    func duplicateCommands() async throws {
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: root)
        try await manager.start(profile.id)
        await #expect(throws: VMFailure.self) { try await manager.start(profile.id) }
        #expect(runtime.startedHandles.count == 1)
        await manager.shutDown(profile.id)
        await manager.shutDown(profile.id)
        #expect(runtime.startedHandles[0].shutdownCount == 1)
        #expect(await manager.snapshots()[0].state == .stopping)
        runtime.startedHandles[0].emit(.ready)
        runtime.startedHandles[0].emit(.progress(.starting, percent: nil))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await manager.snapshots()[0].state == .stopping)
        #expect(await manager.activeSessionCount == 1)
        runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(await eventually { await manager.activeSessionCount == 0 })
    }

    @Test("stale session IDs cannot change a restarted VM")
    func staleEvents() async throws {
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: root)
        try await manager.start(profile.id)
        let old = try #require(await manager.snapshots()[0].sessionID)
        await manager.receive(.exited(status: 0), vmID: profile.id, sessionID: old)
        try await manager.start(profile.id)
        let current = try #require(await manager.snapshots()[0].sessionID)
        #expect(current != old)
        await manager.receive(.error(VMRunError(code: .launchFailed, message: "stale")), vmID: profile.id, sessionID: old)
        await manager.receive(.exited(status: 1), vmID: profile.id, sessionID: old)
        #expect(await manager.activeSessionCount == 1)
        #expect(await manager.snapshots()[0].lastFailure == nil)
        #expect(await manager.snapshots()[0].sessionID == current)
        await manager.receive(.exited(status: 0), vmID: profile.id, sessionID: current)
    }

    @Test("synchronous start failure releases all allocation")
    func synchronousFailure() async throws {
        let runtime = FakeRuntime(startFailure: VMRunError(code: .launchFailed, message: "Cannot exec"))
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: root)
        await #expect(throws: VMFailure.self) { try await manager.start(profile.id) }
        #expect(await manager.activeSessionCount == 0)
        #expect(await manager.allocatedMemoryMiB == 0)
        #expect(await manager.snapshots()[0].state.canStart)
    }

    @Test("force stop requires confirmation and still retains the handle")
    func forceStop() async throws {
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: root)
        try await manager.start(profile.id)
        await #expect(throws: VMFailure.self) { try await manager.forceStop(profile.id, confirmed: false) }
        #expect(runtime.startedHandles[0].terminationCount == 0)
        try await manager.forceStop(profile.id, confirmed: true)
        try await manager.forceStop(profile.id, confirmed: true)
        #expect(runtime.startedHandles[0].terminationCount == 1)
        #expect(await manager.activeSessionCount == 1)
        runtime.startedHandles[0].emit(.exited(status: 137))
        #expect(await eventually { await manager.activeSessionCount == 0 })
    }

    @Test("quit waits for every matching exit", arguments: [0, 1, 2])
    func quit(count: Int) async throws {
        let runtime = FakeRuntime()
        let profiles = Array(POCProfiles.all.prefix(count))
        let manager = VMManager(runtime: runtime, profiles: profiles, applicationSupport: root)
        for profile in profiles { try await manager.start(profile.id) }
        #expect(await manager.beginApplicationShutdown() == (count == 0))
        for handle in runtime.startedHandles { #expect(handle.shutdownCount == 1) }
        for (index, handle) in runtime.startedHandles.enumerated() {
            handle.emit(.exited(status: 0))
            #expect(await eventually { await manager.activeSessionCount == count - index - 1 })
        }
        #expect(await manager.activeSessionCount == 0)
    }

    @Test("completed unpacking clears its percentage during final disk preparation")
    func preparationCompletion() async throws {
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: root)
        try await manager.start(profile.id)
        let sessionID = try #require(await manager.snapshots()[0].sessionID)
        for percent in [49, 100] {
            await manager.receive(.progress(.preparing, percent: percent), vmID: profile.id, sessionID: sessionID)
            #expect(await manager.snapshots()[0].state == .starting(phase: .preparing, percent: percent))
        }
        await manager.receive(.progress(.finishing, percent: nil), vmID: profile.id, sessionID: sessionID)
        #expect(await manager.snapshots()[0].state == .starting(phase: .finishing, percent: nil))
        #expect(await manager.activeSessionCount == 1)
        await manager.receive(.ready, vmID: profile.id, sessionID: sessionID)
        #expect(await manager.snapshots()[0].state == .running)
        await manager.receive(.exited(status: 0), vmID: profile.id, sessionID: sessionID)
        #expect(await manager.activeSessionCount == 0)
    }

    @Test("progress and notice preserve independent VM state")
    func independentSessions() async throws {
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: POCProfiles.all, applicationSupport: root)
        for profile in POCProfiles.all { try await manager.start(profile.id) }
        runtime.startedHandles[0].emit(.progress(.downloading, percent: 30))
        runtime.startedHandles[1].emit(.ready)
        runtime.startedHandles[0].emit(.notice(VMRunNotice(code: .bridgedNetworkUnavailable, message: "notice")))
        #expect(await eventually { await manager.snapshots()[0].notice == "notice" })
        let states = await manager.snapshots().map(\.state)
        #expect(states == [.downloading(phase: .downloading, percent: 30), .running])
        for handle in runtime.startedHandles { handle.emit(.exited(status: 0)) }
        #expect(await eventually { await manager.activeSessionCount == 0 })
    }

    @Test("production adapter cannot start a real kit in this milestone")
    func realLaunchDisabled() throws {
        let runtime = TryOmarchyRuntime(kit: TryOmarchyKit(bundleURL: root))
        let request = VMStartRequest(profile: profile, storageRoot: POCProfiles.root(for: profile, applicationSupport: root))
        #expect(throws: VMFailure.self) { try runtime.start(request) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: request.storageRoot.path))
    }

    @Test("prepared configuration is explicit, NAT and restricted")
    func configuration() throws {
        let request = VMStartRequest(profile: profile, storageRoot: POCProfiles.root(for: profile, applicationSupport: root))
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        let icon = fixture.support.appendingPathComponent("OmarchyGuest.png")
        try Data("synthetic-icon-file".utf8).write(to: icon)
        let config = try TryOmarchyRuntime.configuration(for: request, guestIcon: icon)
        #expect(config.iconPath == icon.path)
        #expect(config.bridges == [.clipboard, .battery, .timezone])
        #expect(config.network == .shared)
        #expect(config.storageRoot?.hasSuffix(profile.id.uuidString) == true)
        #expect(VMRunClient.cleanEnvironment(["OMARCHY_TEST": "bad", "TRYOMARCHY_X": "bad", "SDL_X": "bad", "PATH": "ok"]) == ["PATH": "ok"])
    }
}

private final class EphemeralRuntime: VMRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: FakeRuntimeHandle?
    var handle: FakeRuntimeHandle? { lock.withLock { stored } }
    func preflight() -> VMRunError? { nil }
    func start(_ request: VMStartRequest,
               onEvent: @escaping @Sendable (VMRuntimeEvent) -> Void) throws -> any VMRuntimeHandle {
        let handle = FakeRuntimeHandle(onEvent: onEvent)
        lock.withLock { stored = handle }
        return handle
    }
}

@Test("manager owns the handle through error and releases it after exit")
func strongHandleOwnership() async throws {
    let runtime = EphemeralRuntime()
    let profile = POCProfiles.all[0]
    let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: URL(fileURLWithPath: "/private/tmp/ownership-fixture"))
    try await manager.start(profile.id)
    #expect(runtime.handle != nil)
    runtime.handle?.emit(.error(VMRunError(code: .launchFailed, message: "diagnostic")))
    #expect(await eventually { await manager.snapshots()[0].lastFailure != nil })
    #expect(runtime.handle != nil)
    runtime.handle?.emit(.exited(status: 1))
    #expect(await eventually { runtime.handle == nil })
    #expect(await manager.activeSessionCount == 0)
}
