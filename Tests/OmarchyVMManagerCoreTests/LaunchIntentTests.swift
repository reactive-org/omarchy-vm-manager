import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

@MainActor func foregroundEventually(_ predicate: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@MainActor private final class DisplayFixture {
    var readiness: GuestLaunchForegrounding.Readiness = .waiting
    var probes = 0
    var activations: [VMRunDisplayProcess] = []
    var accepted = true
    func controller(_ intent: VMLaunchIntent = .foreground, timeout: Duration = .seconds(2)) -> GuestLaunchForegrounding {
        GuestLaunchForegrounding(intent: intent, timeout: timeout, probe: { _ in
            self.probes += 1
            return self.readiness
        }, activate: { process in
            self.activations.append(process)
            return self.accepted
        })
    }
}

@Suite("Launch-scoped guest foreground requests")
struct LaunchIntentTests {
    let process = VMRunDisplayProcess(processIdentifier: 12345, startSeconds: 100, startMicroseconds: 10)

    @Test("background launch never probes or activates a display") @MainActor
    func background() async throws {
        let display = DisplayFixture(); display.readiness = .ready
        let controller = display.controller(.background)
        controller.displayReady(process)
        try await Task.sleep(for: .milliseconds(150))
        #expect(display.probes == 0 && display.activations.isEmpty)
    }

    @Test("delayed display readiness activates the exact identity only once") @MainActor
    func delayed() async throws {
        let display = DisplayFixture(), controller = display.controller()
        controller.displayReady(process)
        #expect(await foregroundEventually { display.probes > 0 })
        #expect(display.activations.isEmpty)
        display.readiness = .ready
        #expect(await foregroundEventually { display.activations == [process] })
        controller.displayReady(VMRunDisplayProcess(processIdentifier: 99999, startSeconds: 200, startMicroseconds: 0))
        try await Task.sleep(for: .milliseconds(150))
        #expect(display.activations == [process])
    }

    @Test("cancelled, exited, stale, timed-out and rejected requests never retry activation") @MainActor
    func failures() async throws {
        let cancelled = DisplayFixture(), cancellation = cancelled.controller()
        cancellation.displayReady(process); cancellation.cancel(); cancelled.readiness = .ready
        let stale = DisplayFixture(); stale.readiness = .gone
        let staleRequest = stale.controller(); staleRequest.displayReady(process)
        let timeout = DisplayFixture(), timed = timeout.controller(timeout: .milliseconds(250))
        timed.displayReady(process)
        let rejected = DisplayFixture(); rejected.readiness = .ready; rejected.accepted = false
        let refused = rejected.controller(); refused.displayReady(process)
        #expect(await foregroundEventually { rejected.activations.count == 1 && stale.probes > 0 && timeout.probes > 0 })
        try await Task.sleep(for: .milliseconds(350))
        timeout.readiness = .ready; stale.readiness = .ready
        for request in [cancellation, staleRequest, timed, refused] { request.displayReady(process) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(cancelled.activations.isEmpty && stale.activations.isEmpty && timeout.activations.isEmpty)
        #expect(rejected.activations == [process])
    }

    @Test("a recycled or nonexistent PID fails the native identity check without activation") @MainActor
    func nativeIdentity() async throws {
        let display = DisplayFixture()
        let controller = GuestLaunchForegrounding(intent: .foreground, activate: { process in
            display.activations.append(process); return true
        })
        controller.displayReady(VMRunDisplayProcess(processIdentifier: ProcessInfo.processInfo.processIdentifier, startSeconds: 1, startMicroseconds: 0))
        try await Task.sleep(for: .milliseconds(150))
        #expect(display.activations.isEmpty)
    }

    @Test("manager intent is per session and SDK configuration defaults to background")
    func propagation() async throws {
        let runtime = FakeRuntime(), profile = POCProfiles.all[0]
        let support = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: support)
        try await manager.start(profile.id, launchIntent: .foreground)
        let first = try #require(runtime.startRequests.first)
        #expect(first.launchIntent == .foreground)
        #expect(try TryOmarchyRuntime.configuration(for: first, guestIcon: nil).launchIntent == .foreground)
        runtime.startedHandles[0].emit(.exited(status: 1))
        #expect(await eventually { await manager.activeSessionCount == 0 })
        try await manager.start(profile.id)
        let next = try #require(runtime.startRequests.last)
        #expect(next.launchIntent == .background && first.sessionID != next.sessionID)
        #expect(try TryOmarchyRuntime.configuration(for: next, guestIcon: nil).launchIntent == .background)
        runtime.startedHandles[1].emit(.exited(status: 0))
        #expect(await eventually { await manager.activeSessionCount == 0 })
    }
}
