import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [VMRuntimeEvent] = []
    var all: [VMRuntimeEvent] { lock.withLock { events } }
    func record(_ event: VMRuntimeEvent) { lock.withLock { events.append(event) } }
}

@Suite("Real client with protocol stubs")
struct RuntimeAdapterTests {
    @Test("background intent reaches the helper and ignores display activation events") @MainActor
    func backgroundConfiguration() async throws {
        let fixture = try stub(#"""
        IFS= read -r configuration
        case "$configuration" in *'"launchIntent":"background"'*) ;; *) exit 22 ;; esac
        printf '%s\n' '{"version":1,"event":"display-ready","pid":12345,"startSeconds":100,"startMicroseconds":0}' '{"version":1,"event":"ready"}'
        IFS= read -r command
        """#)
        defer { fixture.cleanup() }
        let display = CleanupDisplay()
        let foreground = GuestLaunchForegrounding(intent: .background, probe: { _ in .ready }, activate: { _ in display.count += 1; return true })
        let recorder = EventRecorder()
        let handle = try TryOmarchyRuntime(protocolTestKit: fixture.kit, foreground: foreground).start(request(fixture), onEvent: recorder.record)
        #expect(await foregroundEventually { recorder.all.contains(.ready) })
        try await Task.sleep(for: .milliseconds(150))
        #expect(display.count == 0)
        handle.shutDown()
        #expect(await foregroundEventually { !handle.isRunning })
    }

    @Test("SDK transmits intent and lifecycle changes cancel delayed foregrounding", arguments: ["error", "stopping", "exited", "shutdown", "terminate", "pause", "sleep"])
    @MainActor func foregroundCleanup(_ boundary: String) async throws {
        let configuration = VMRunDisplayProcess(processIdentifier: 12345, startSeconds: 100, startMicroseconds: 10)
        let displayLine = String(decoding: try VMRunEvent.displayReady(configuration).encodedLine(), as: UTF8.self).trimmingCharacters(in: .newlines)
        let terminal: String
        switch boundary {
        case "error": terminal = #"{"version":1,"event":"error","code":"launch-failed","message":"synthetic"}"#
        case "stopping": terminal = #"{"version":1,"event":"stopping"}"#
        case "exited": terminal = #"{"version":1,"event":"exited","status":1}"#
        case "sleep": terminal = #"{"version":1,"event":"execution-state","state":"host-sleeping"}"#
        default: terminal = ""
        }
        let fixture = try stub("""
        IFS= read -r configuration
        case "$configuration" in *'"launchIntent":"foreground"'*) ;; *) exit 22 ;; esac
        printf '%s\\n' '\(displayLine)' '\(terminal.isEmpty ? #"{"version":1,"event":"ready"}"# : terminal)'
        \(boundary == "exited" ? "exit 1" : "IFS= read -r command")
        """)
        defer { fixture.cleanup() }
        let display = CleanupDisplay()
        let foreground = GuestLaunchForegrounding(intent: .foreground, probe: { _ in display.ready ? .ready : .waiting }, activate: { _ in display.count += 1; return true })
        let runtime = TryOmarchyRuntime(protocolTestKit: fixture.kit, foreground: foreground)
        let recorder = EventRecorder()
        let base = request(fixture)
        let handle = try runtime.start(VMStartRequest(profile: base.profile, storageRoot: base.storageRoot, launchIntent: .foreground), onEvent: recorder.record)
        #expect(await foregroundEventually { !recorder.all.isEmpty })
        if boundary == "shutdown" { handle.shutDown() }
        if boundary == "terminate" { handle.terminate() }
        if boundary == "pause" { try handle.pause() }
        display.ready = true
        try await Task.sleep(for: .milliseconds(150))
        #expect(display.count == 0)
        #expect(!recorder.all.contains { if case .displayReady = $0 { true } else { false } })
        handle.terminate()
        #expect(await foregroundEventually { !handle.isRunning })
    }

    @Test("synchronous launch failure cancels its foreground request") @MainActor
    func foregroundSynchronousFailure() async throws {
        let fixture = try stub("exit 0"); defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.kit.bundleURL.appendingPathComponent(TryOmarchyKit.helperPath))
        let display = CleanupDisplay(); display.ready = true
        let foreground = GuestLaunchForegrounding(intent: .foreground, probe: { _ in .ready }, activate: { _ in display.count += 1; return true })
        #expect(throws: VMRunError.self) {
            try TryOmarchyRuntime(protocolTestKit: fixture.kit, foreground: foreground).start(request(fixture)) { _ in }
        }
        foreground.displayReady(VMRunDisplayProcess(processIdentifier: 12345, startSeconds: 100, startMicroseconds: 0))
        try await Task.sleep(for: .milliseconds(150))
        #expect(display.count == 0)
    }

    private func stub(_ script: String) throws -> KitFixture {
        let fixture = try KitFixture()
        let helper = fixture.kit.bundleURL.appendingPathComponent(TryOmarchyKit.helperPath)
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return fixture
    }

    private func request(_ fixture: KitFixture) -> VMStartRequest {
        VMStartRequest(profile: POCProfiles.all[0], storageRoot: POCProfiles.root(for: POCProfiles.all[0], applicationSupport: fixture.folder))
    }

    @Test("two client instances report ordered events and accept graceful shutdown")
    func simultaneousClients() async throws {
        let fixture = try stub(#"""
        IFS= read -r configuration
        printf '%s\n' '{"version":1,"event":"progress","phase":"starting","percent":50}' '{"version":1,"event":"future-event"}' '{"version":1,"event":"ready"}'
        printf '%s\n' 'stub diagnostics' >&2
        IFS= read -r command
        case "$command" in
          *'"command":"shutdown"'*) printf '%s\n' '{"version":1,"event":"stopping"}' '{"version":1,"event":"exited","status":0}' ;;
          *) exit 2 ;;
        esac
        """#)
        defer { fixture.cleanup() }
        let runtime = TryOmarchyRuntime(protocolTestKit: fixture.kit)
        let a = EventRecorder(), b = EventRecorder()
        let first = try runtime.start(request(fixture), onEvent: a.record)
        let second = try runtime.start(request(fixture), onEvent: b.record)
        #expect(await eventually { a.all.contains(.ready) && b.all.contains(.ready) })
        #expect(first.isRunning && second.isRunning)
        first.shutDown()
        #expect(await eventually { a.all.last == .exited(status: 0) })
        #expect(second.isRunning)
        second.shutDown()
        #expect(await eventually { b.all.last == .exited(status: 0) })
        let expected: [VMRuntimeEvent] = [.progress(.starting, percent: 50), .ready, .stopping, .exited(status: 0)]
        #expect(a.all == expected && b.all == expected)
        #expect(first.recentStandardError.contains("stub diagnostics"))
        #expect(!first.isRunning && !second.isRunning)
    }

    @Test("real SDK sends Pause and Resume through the helper command pipe")
    func executionCommands() async throws {
        let fixture = try stub(#"""
        IFS= read -r configuration
        printf '%s\n' '{"version":1,"event":"ready"}'
        for expected in pause resume shutdown; do
          IFS= read -r command
          case "$command" in
            *\"command\":\"$expected\"*) ;;
            *) exit 2 ;;
          esac
          case "$expected" in
            pause) printf '%s\n' '{"version":1,"event":"execution-state","command":"pause","state":"paused"}' ;;
            resume) printf '%s\n' '{"version":1,"event":"execution-state","command":"resume","state":"running"}' ;;
            shutdown) printf '%s\n' '{"version":1,"event":"stopping"}' '{"version":1,"event":"exited","status":0}' ;;
          esac
        done
        """#)
        defer { fixture.cleanup() }
        let recorder = EventRecorder()
        let handle = try TryOmarchyRuntime(protocolTestKit: fixture.kit).start(request(fixture), onEvent: recorder.record)
        #expect(await eventually { recorder.all.contains(.ready) })
        try handle.pause()
        #expect(await eventually { recorder.all.contains(.executionState(.init(state: .paused, command: .pause))) })
        #expect(handle.isRunning)
        try handle.resume()
        #expect(await eventually { recorder.all.contains(.executionState(.init(state: .running, command: .resume))) })
        handle.shutDown()
        #expect(await eventually { recorder.all.last == .exited(status: 0) })
        #expect(!handle.isRunning)
    }

    @Test("malformed events produce an error and terminate the stub")
    func malformed() async throws {
        let fixture = try stub("IFS= read -r configuration\nprintf '%s\\n' 'not-json'\nIFS= read -r command")
        defer { fixture.cleanup() }
        let recorder = EventRecorder()
        let handle = try TryOmarchyRuntime(protocolTestKit: fixture.kit).start(request(fixture), onEvent: recorder.record)
        #expect(await eventually { !handle.isRunning })
        #expect(recorder.all.contains { if case .error = $0 { true } else { false } })
        #expect(recorder.all.contains { if case .exited = $0 { true } else { false } })
    }

    @Test("unexpected helper exit becomes a terminal event")
    func crash() async throws {
        let fixture = try stub("IFS= read -r configuration\nexit 23")
        defer { fixture.cleanup() }
        let recorder = EventRecorder()
        let handle = try TryOmarchyRuntime(protocolTestKit: fixture.kit).start(request(fixture), onEvent: recorder.record)
        #expect(await eventually { recorder.all.last == .exited(status: 23) })
        #expect(!handle.isRunning)
    }

    @Test("missing executable fails synchronously")
    func synchronousLaunchFailure() throws {
        let fixture = try stub("exit 0"); defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.kit.bundleURL.appendingPathComponent(TryOmarchyKit.helperPath))
        #expect(throws: VMRunError.self) {
            try TryOmarchyRuntime(protocolTestKit: fixture.kit).start(request(fixture)) { _ in }
        }
    }

    @Test("terminate stops a waiting helper and bounds stderr")
    func terminateAndBoundedStderr() async throws {
        let fixture = try stub(#"""
        IFS= read -r configuration
        /usr/bin/head -c 20000 /dev/zero | /usr/bin/tr '\000' x >&2
        printf '%s\n' '{"version":1,"event":"ready"}'
        IFS= read -r command
        """#)
        defer { fixture.cleanup() }
        let recorder = EventRecorder()
        let handle = try TryOmarchyRuntime(protocolTestKit: fixture.kit).start(request(fixture), onEvent: recorder.record)
        #expect(await eventually { recorder.all.contains(.ready) })
        #expect(handle.recentStandardError.utf8.count <= VMRunClient.errorTailBytes)
        handle.terminate()
        #expect(await eventually { !handle.isRunning })
    }
}

@MainActor private final class CleanupDisplay {
    var ready = false
    var count = 0
}
