import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

@Suite("Guest Touch ID policy")
struct GuestTouchIDTests {
    @Test("old profiles default off; opted-in profiles round trip without storage")
    func profiles() throws {
        var profile = VMProfile(id: UUID(), name: "Fixture")
        let data = try JSONEncoder().encode(profile)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "guestTouchIDEnabled")
        #expect(try !JSONDecoder().decode(VMProfile.self, from: JSONSerialization.data(withJSONObject: object)).guestTouchIDEnabled)
        profile.guestTouchIDEnabled = true
        #expect(try JSONDecoder().decode(VMProfile.self, from: JSONEncoder().encode(profile)) == profile)
        #expect(GuestTouchIDRecord(VMSnapshot(profile: profile, state: .stopped)).hostBridge == "next-start")
        let running = GuestTouchIDRecord(VMSnapshot(profile: profile, state: .running, sessionID: UUID()))
        #expect(running.hostBridge == "requested" && running.guestPairing == "unknown")
    }

    @Test("CLI and config allow a boolean only, on create/update, with no host paths")
    func arguments() throws {
        for command in ["create", "update"] {
            let invocation = try GuestCLIInvocation.parse([command, "fixture", "--guest-touch-id", "on"])
            #expect(invocation.request?.config?.guestTouchID == true)
        }
        for args in [["create", "fixture", "--guest-touch-id", "yes"], ["get", "fixture", "--guest-touch-id", "on"],
                     ["update", "fixture", "--guest-touch-id", "on", "--guest-touch-id", "off"]] {
            #expect(throws: (any Error).self) { try GuestCLIInvocation.parse(args) }
        }
        #expect(try GuestConfigurationPatch.decodeStrict(Data(#"{"guestTouchID":true}"#.utf8)).guestTouchID == true)
        for value in [#"{"guestTouchID":null}"#, #"{"guestTouchID":1}"#, #"{"guestTouchID":"on"}"#, #"{"authenticationScope":"/tmp"}"#] {
            #expect(throws: (any Error).self) { try GuestConfigurationPatch.decodeStrict(Data(value.utf8)) }
        }
    }

    @Test("explicit bridges carry manager UUID/run identity only when opted in")
    func configuration() throws {
        var profile = VMProfile(id: UUID(), name: "Fixture")
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(profile.id.uuidString)
        let disabled = try TryOmarchyRuntime.configuration(for: VMStartRequest(profile: profile, storageRoot: root), guestIcon: nil)
        #expect(!disabled.bridges.contains(.authentication) && disabled.authenticationScope == nil)
        profile.guestTouchIDEnabled = true
        let request = VMStartRequest(profile: profile, storageRoot: root)
        let enabled = try TryOmarchyRuntime.configuration(for: request, guestIcon: nil)
        #expect(enabled.bridges == [.clipboard, .battery, .timezone, .authentication])
        #expect(enabled.authenticationScope == VMRunAuthenticationScope(vmID: profile.id, runID: request.sessionID))
        #expect(enabled.network == .shared)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("protocol 1 and owner compatibility cannot self-assert authentication support")
    func admission() throws {
        var fixture = try KitFixture(); defer { fixture.cleanup() }
        var profile = VMProfile(id: UUID(), name: "Fixture")
        try GuestTouchIDPolicy.validate(profile, lockData: Data())
        profile.guestTouchIDEnabled = true
        #expect(throws: VMFailure.self) { try GuestTouchIDPolicy.validate(profile, lockData: fixture.data) }
        fixture.lock.managedAuthenticationVersion = 2
        #expect(throws: VMFailure.self) { try fixture.inspect() }
        fixture.lock.managedAuthenticationVersion = 1
        #expect(throws: VMFailure.self) { try GuestTouchIDPolicy.validate(profile, lockData: fixture.data) }
        var object = try #require(JSONSerialization.jsonObject(with: fixture.data) as? [String: Any])
        var files = fixture.lock.files
        files[VMFactorySelection.packagePath] = VMGuestIntegrationContract.current.runtimePackageSHA256
        object["files"] = files
        try GuestTouchIDPolicy.validate(profile, lockData: JSONSerialization.data(withJSONObject: object))
    }

    @Test("setting persists only while stopped and errors retain the active session")
    func lifecycle() async throws {
        let files = try RegistryFixture(); defer { files.cleanup() }
        let registry = try RegistryStore(applicationSupport: files.support); _ = try registry.load()
        let profile = VMProfile(id: UUID(), name: "Fixture")
        try registry.save([profile])
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: files.support,
            hostMemoryMiB: 65536, logicalCPUs: 64, registry: registry)
        try await manager.update(profile.id, configuration: GuestConfigurationPatch(guestTouchID: true))
        #expect(await manager.snapshots().first?.profile.guestTouchIDEnabled == true)
        let registryData = try Data(contentsOf: files.support.appendingPathComponent("Omarchy VM Manager/registry.json"))
        let persisted = try #require(JSONSerialization.jsonObject(with: registryData) as? [String: Any])
        let persistedProfiles = try #require(persisted["profiles"] as? [[String: Any]])
        #expect(persistedProfiles.first?["guestTouchIDEnabled"] as? Bool == true)
        try await manager.start(profile.id)
        await #expect(throws: VMFailure.self) { try await manager.update(profile.id, configuration: GuestConfigurationPatch(guestTouchID: false)) }
        let session = try #require(await manager.snapshots().first?.sessionID)
        await manager.receive(.error(VMRunError(code: .launchFailed, message: "fixture")), vmID: profile.id, sessionID: session)
        #expect(await manager.snapshots().first?.sessionID == session)
        await #expect(throws: VMFailure.self) { try await manager.update(profile.id, configuration: GuestConfigurationPatch(guestTouchID: false)) }
        await manager.receive(.exited(status: 0), vmID: profile.id, sessionID: session)
        try await manager.update(profile.id, configuration: GuestConfigurationPatch(guestTouchID: false))
        #expect(await manager.snapshots().first?.profile.guestTouchIDEnabled == false)
    }
}

extension GuestTouchIDTests {
    @Test("command creation and status preserve explicit opt-in without creating VM storage")
    func commandCreation() async throws {
        let files = try RegistryFixture(); defer { files.cleanup() }
        let registry = try RegistryStore(applicationSupport: files.support); _ = try registry.load()
        let manager = VMManager(runtime: FakeRuntime(), profiles: [], applicationSupport: files.support,
            hostMemoryMiB: 65536, logicalCPUs: 64, registry: registry)
        let service = GuestCommandService(manager: manager, applicationSupport: files.support)
        let request = try #require(try GuestCLIInvocation.parse(["create", "Fixture", "--guest-touch-id", "on", "--ssh", "off", "--owner-defaults", "off"]).request)
        let result = await service.execute(request)
        #expect(result.ok)
        let record = try #require(result.guest)
        #expect(record.guestTouchID.enabled && record.guestTouchID.hostBridge == "next-start" && record.guestTouchID.guestPairing == "unknown")
        let roundTrip = try JSONDecoder().decode(GuestCommandResponse.self, from: JSONEncoder().encode(result))
        #expect(roundTrip.guest?.guestTouchID.enabled == true)
        let root = ManagerStorage(applicationSupport: files.support).root(for: try #require(await manager.snapshots().first?.profile))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let update = await service.execute(GuestCommandRequest(command: .update, selector: record.id.uuidString, config: GuestConfigurationPatch(guestTouchID: false)))
        #expect(update.ok && update.guest?.guestTouchID.enabled == false)
    }
}

private struct DiagnosticRuntime: VMRuntime {
    func preflight() -> VMRunError? { nil }
    func start(_ request: VMStartRequest, onEvent: @escaping @Sendable (VMRuntimeEvent) -> Void) throws -> any VMRuntimeHandle { DiagnosticHandle() }
}

private final class DiagnosticHandle: VMRuntimeHandle, @unchecked Sendable {
    var isRunning: Bool { true }
    var recentStandardError: String { VMGuestAuthenticationDiagnostic.prefix + "focus-before\n" }
    func pause() throws {}
    func resume() throws {}
    func shutDown() {}
    func terminate() {}
}

extension GuestTouchIDTests {
    @Test("only complete whitelisted host diagnostics are displayed and approval clears the old denial")
    func diagnostics() {
        let prefix = VMGuestAuthenticationDiagnostic.prefix
        #expect(VMGuestAuthenticationDiagnostic.latest(in: prefix + "focus-before\n") == .focusBefore)
        #expect(VMGuestAuthenticationDiagnostic.latest(in: prefix + "focus-before\n" + prefix + "approved") == .focusBefore)
        #expect(VMGuestAuthenticationDiagnostic.latest(in: prefix + "focus-before\n" + prefix + "approved\n")?.explanation == nil)
        for line in ["untrusted guest text", prefix + "unknown", prefix + "focus-before synthetic-secret"] {
            #expect(VMGuestAuthenticationDiagnostic.latest(in: line + "\n") == nil)
        }
    }

    @Test("an authentication denial is a notice and keeps the active client and resources until exit")
    func diagnosticLifecycle() async throws {
        let files = try RegistryFixture(); defer { files.cleanup() }
        var profile = VMProfile(id: UUID(), name: "Fixture")
        profile.guestTouchIDEnabled = true
        let manager = VMManager(runtime: DiagnosticRuntime(), profiles: [profile], applicationSupport: files.support,
            hostMemoryMiB: 65536, logicalCPUs: 64)
        try await manager.start(profile.id)
        let snapshot = try #require(await manager.snapshots().first)
        #expect(snapshot.notice == VMGuestAuthenticationDiagnostic.focusBefore.explanation)
        #expect(snapshot.lastFailure == nil)
        #expect(await manager.activeSessionCount == 1)
        #expect(await manager.allocatedMemoryMiB == profile.memoryMiB)
        await manager.receive(.exited(status: 0), vmID: profile.id, sessionID: try #require(snapshot.sessionID))
        #expect(await manager.activeSessionCount == 0)
        #expect(await manager.allocatedMemoryMiB == 0)
    }
}
