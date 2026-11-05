import Darwin
@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private actor IdentityFixtureProbe: SSHReadinessChecking {
    struct Entry: Sendable { let request: VMStartRequest; let update: @Sendable (SSHReadinessObservation) async -> Void }
    private(set) var entries: [Entry] = []
    func monitor(_ request: VMStartRequest, update: @escaping @Sendable (SSHReadiness) async -> Void) async { Issue.record("Manager used readiness-only monitor") }
    func monitorAuthenticated(_ request: VMStartRequest, update: @escaping @Sendable (SSHReadinessObservation) async -> Void) async {
        entries.append(.init(request: request, update: update))
        while !Task.isCancelled { do { try await Task.sleep(for: .milliseconds(20)) } catch { return } }
    }
    func send(_ value: SSHReadinessObservation, index: Int = 0) async { await entries[index].update(value) }
}
private final class IdentityFixture: Sendable {
    let root: URL, manager: VMManager, runtime: FakeRuntime, profile: VMProfile, probe: IdentityFixtureProbe, request: VMStartRequest
    let provider: SessionFixtureProvider
    init() async throws {
        root = URL(fileURLWithPath: "/private/tmp/authenticated-identity-" + UUID().uuidString)
        var profile = VMProfile(id: UUID(), name: "Identity fixture", clipboardEnabled: false); profile.ssh = .init(hostPort: 22333); self.profile = profile
        probe = IdentityFixtureProbe(); runtime = FakeRuntime(initialEvents: [.ready])
        manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: root, hostMemoryMiB: 32768, logicalCPUs: 8, sshProbe: probe, portProbe: TransportFixturePorts())
        try await manager.start(profile.id)
        let manager = manager, probe = probe
        #expect(await eventually { await manager.snapshots().first?.state == .running })
        #expect(await eventually { await probe.entries.count == 1 })
        request = try #require(await probe.entries.first?.request)
        let target = try GuestBinding(vmID: profile.id, sessionID: request.sessionID, owner: "fixture_owner", ownerUID: 1007, hostKeyDigest: sessionFixtureHostKeyDigest)
        try seedTransportEndpoint(root: request.storageRoot, target: target, port: 22333)
        provider = try SessionFixtureProvider()
    }
    deinit { runtime.startedHandles.forEach { if $0.isRunning { $0.emit(.exited(status: 0)) } }; try? FileManager.default.removeItem(at: root) }
    func output(uid: Int = 1007) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["vmID": profile.id.uuidString.lowercased(), "sessionToken": request.sessionID.uuidString.lowercased(), "user": "fixture_owner", "uid": uid])
    }
    func evidence(uid: Int = 1007, now: ContinuousClock.Instant = .now) throws -> ProvisioningAuthenticatedIdentity {
        let challenge = try ProvisioningSSHIdentityChallenge(request: request, user: "fixture_owner")
        return try challenge.complete(.init(status: 0, output: output(uid: uid), hostKeyMismatch: false, failureKind: "empty"), now: now)
    }
    func publish(_ value: ProvisioningAuthenticatedIdentity) async {
        await probe.send(.init(readiness: .ready(user: "fixture_owner", command: "synthetic-command"), identity: value))
    }
    func close() async { await manager.shutDown(profile.id); runtime.startedHandles.forEach { $0.emit(.exited(status: 0)) } }
}

private actor IdentityMonitorRecorder {
    var arguments: [[String]] = [], observations: [SSHReadinessObservation] = []
    private var sleeps = 0
    func invoke(_ args: [String], bytes: Data) -> SSHProbeProcess.Result { arguments.append(args); return .init(status: 0, output: bytes, hostKeyMismatch: false, failureKind: "empty") }
    func observe(_ value: SSHReadinessObservation) { observations.append(value) }
    func pause(_ duration: Duration) throws {
        guard duration == .seconds(30), sleeps == 0 else { throw CancellationError() }
        sleeps += 1
    }
}

@Suite("Authenticated provisioning identity — fake SSH replies and runtimes") struct ProvisioningIdentityTests {
    @Test func managedMonitorPublishesAuthenticatedRefreshWithoutDroppingReadiness() async throws {
        let f = try await IdentityFixture(), recorder = IdentityMonitorRecorder(), bytes = try f.output()
        let storage = ManagedSSHStorage(root: f.request.storageRoot)
        try PrivateFiles.write(Data("synthetic-host-private".utf8), name: "host_ed25519", in: storage.bootstrap)
        try PrivateFiles.write(Data(("ssh-ed25519 " + sessionFixtureHostKey.base64EncodedString() + "\n").utf8), name: "host_ed25519.pub", in: storage.bootstrap)
        let shell = f.request.storageRoot.appendingPathComponent("shell"); try PrivateFiles.directory(shell, create: true)
        let report: [String: Any] = ["receivedAt": ISO8601DateFormatter().string(from: Date()), "report": ["managedSSH": ["schemaVersion": 1, "vmID": f.profile.id.uuidString, "sessionToken": f.request.sessionID.uuidString, "state": "configured", "owner": "fixture_owner"]]]
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: report), name: "guest-status.json", in: shell)
        let probe = ManagedSSHProbe(runIdentity: { await recorder.invoke($0, bytes: bytes) }, pause: { try await recorder.pause($0) })
        await probe.monitorAuthenticated(f.request) { await recorder.observe($0) }
        let observations = await recorder.observations, arguments = await recorder.arguments
        #expect(observations.count == 3 && observations.first?.readiness == .connecting)
        #expect(observations.dropFirst().allSatisfy { $0.identity?.connection.binding.ownerUID == 1007 })
        #expect(arguments.count == 2 && arguments.allSatisfy { $0.contains("StrictHostKeyChecking=yes") && $0.contains("IdentityAgent=none") && $0.last == "/usr/lib/try-omarchy/managed-ssh-identity" })
        #expect(FileManager.default.fileExists(atPath: storage.clientConfig.path))
        await f.close()
    }
    @Test func onlyAuthenticatedEvidenceResolvesUIDAndPinnedHostForTheExactSession() async throws {
        let f = try await IdentityFixture(), evidence = try f.evidence()
        await f.probe.send(.init(readiness: .ready(user: "fixture_owner", command: "synthetic-command")))
        await #expect(throws: ProvisioningJobFailure.targetChanged) { _ = try await f.manager.resolveProvisioningTarget(vmID: f.profile.id, sessionID: f.request.sessionID) }
        await f.publish(evidence)
        let binding = try await f.manager.resolveProvisioningTarget(vmID: f.profile.id, sessionID: f.request.sessionID)
        #expect(binding.ownerUID == 1007 && binding.hostKeyDigest == sessionFixtureHostKeyDigest)
        await #expect(throws: Error.self) { _ = try await f.manager.resolveProvisioningTarget(vmID: UUID(), sessionID: f.request.sessionID) }
        await #expect(throws: Error.self) { _ = try await f.manager.resolveProvisioningTarget(vmID: f.profile.id, sessionID: UUID()) }
        #expect(!String(reflecting: evidence).contains("fixture_owner")); #expect(!String(reflecting: evidence).contains(f.root.path))
        #expect(f.provider.builds == 0 && f.runtime.startRequests.count == 1)
        await f.close()
    }
    @Test(arguments: ["vm", "session", "user", "uid-root", "uid-high", "uid-string", "uid-bool", "uid-float", "unknown", "duplicate", "oversized", "failure", "host-mismatch", "null"])
    func strictAuthenticationReplyCannotBecomeEvidence(kind: String) async throws {
        let f = try await IdentityFixture(), challenge = try ProvisioningSSHIdentityChallenge(request: f.request, user: "fixture_owner")
        var fields = try JSONSerialization.jsonObject(with: f.output()) as! [String: Any]
        switch kind {
        case "vm": fields["vmID"] = UUID().uuidString
        case "session": fields["sessionToken"] = UUID().uuidString
        case "user": fields["user"] = "another_fixture"
        case "uid-root": fields["uid"] = 0
        case "uid-high": fields["uid"] = 60000
        case "uid-string": fields["uid"] = "1007"
        case "uid-bool": fields["uid"] = true
        case "uid-float": fields["uid"] = 1007.5
        case "unknown": fields["command"] = "never-run"
        case "null": fields["uid"] = NSNull()
        default: break
        }
        var bytes = try JSONSerialization.data(withJSONObject: fields)
        if kind == "duplicate" { bytes = Data("{\"uid\":1007,".utf8) + bytes.dropFirst() }
        if kind == "oversized" { bytes = Data(repeating: 32, count: 4097) }
        #expect(throws: Error.self) { _ = try challenge.complete(.init(status: kind == "failure" ? 255 : 0, output: bytes, hostKeyMismatch: kind == "host-mismatch", failureKind: "empty")) }
        await #expect(throws: Error.self) { _ = try await f.manager.resolveProvisioningTarget(vmID: f.profile.id, sessionID: f.request.sessionID) }
        #expect(f.provider.builds == 0); await f.close()
    }
    @Test(arguments: ["known-hosts", "manifest", "bootstrap", "key", "root"])
    func pinsChangingDuringAuthenticationOrAfterObservationAreRefused(kind: String) async throws {
        let f = try await IdentityFixture(), challenge = try ProvisioningSSHIdentityChallenge(request: f.request, user: "fixture_owner"), evidence = try f.evidence()
        await f.publish(evidence)
        let storage = ManagedSSHStorage(root: f.request.storageRoot)
        switch kind {
        case "known-hosts": try Data("changed".utf8).write(to: storage.knownHosts)
        case "manifest": try Data("{}".utf8).write(to: storage.root.appendingPathComponent(ManagedSSHStorage.manifestName))
        case "bootstrap": try Data("{}".utf8).write(to: storage.bootstrap.appendingPathComponent("manifest.json"))
        case "key":
            try FileManager.default.moveItem(at: storage.clientKey, to: storage.directory.appendingPathComponent("old-client"))
            try PrivateFiles.write(Data("replacement-fixture".utf8), name: "client", in: storage.directory, exclusively: true)
        default:
            let old = storage.root.deletingLastPathComponent().appendingPathComponent("old-" + UUID().uuidString)
            try FileManager.default.moveItem(at: storage.root, to: old); try FileManager.default.createSymbolicLink(at: storage.root, withDestinationURL: old)
        }
        #expect(throws: Error.self) { _ = try challenge.complete(.init(status: 0, output: f.output(), hostKeyMismatch: false, failureKind: "empty")) }
        await #expect(throws: Error.self) { _ = try await f.manager.resolveProvisioningTarget(vmID: f.profile.id, sessionID: f.request.sessionID) }
        #expect(f.provider.builds == 0); await f.close()
    }
    @Test func sameIdentityRefreshPreservesLeaseAndChangedUIDOrLostEvidenceInvalidatesIt() async throws {
        let f = try await IdentityFixture(), evidence = try f.evidence(), owner = UUID()
        await f.publish(evidence)
        try await f.manager.installProvisioningCoordinator(owner, blocked: [])
        let lease = try await f.manager.reserveProvisioning(owner: owner, jobID: UUID(), target: evidence.connection.binding, cancel: { _ in })
        await f.publish(try f.evidence())
        try await f.manager.validateProvisioning(lease, cleanup: false)
        await f.publish(try f.evidence(uid: 1010))
        await #expect(throws: Error.self) { try await f.manager.validateProvisioning(lease, cleanup: false) }
        #expect(try await f.manager.resolveProvisioningTarget(vmID: f.profile.id, sessionID: f.request.sessionID).ownerUID == 1010)
        await f.probe.send(.init(readiness: .connecting))
        await #expect(throws: Error.self) { _ = try await f.manager.resolveProvisioningTarget(vmID: f.profile.id, sessionID: f.request.sessionID) }
        await f.close()
    }
    @Test func expiredOrFutureEvidenceAndAReadinessOnlyRefreshGrantNoAuthority() async throws {
        let f = try await IdentityFixture(), now = ContinuousClock.now
        for instant in [now - .seconds(46), now + .seconds(10)] {
            await f.publish(try f.evidence(now: instant))
            await #expect(throws: Error.self) { _ = try await f.manager.resolveProvisioningTarget(vmID: f.profile.id, sessionID: f.request.sessionID) }
        }
        let evidence = try f.evidence(now: now)
        #expect(throws: Error.self) { try evidence.verify(now: now + .seconds(46)) }
        await f.publish(evidence)
        await f.probe.send(.init(readiness: .ready(user: "fixture_owner", command: "no-identity")))
        await #expect(throws: Error.self) { _ = try await f.manager.resolveProvisioningTarget(vmID: f.profile.id, sessionID: f.request.sessionID) }
        await f.close()
    }
    @Test func lateProbeCannotRestoreEvidenceAfterRetryAndShutdown() async throws {
        let f = try await IdentityFixture(), evidence = try f.evidence()
        await f.publish(evidence)
        await f.manager.retrySSH(f.profile.id)
        let probe = f.probe
        #expect(await eventually { await probe.entries.count == 2 })
        await f.probe.send(.init(readiness: .ready(user: "fixture_owner", command: "old-generation"), identity: evidence), index: 0)
        await #expect(throws: Error.self) { _ = try await f.manager.resolveProvisioningTarget(vmID: f.profile.id, sessionID: f.request.sessionID) }
        await f.probe.send(.init(readiness: .ready(user: "fixture_owner", command: "new-generation"), identity: evidence), index: 1)
        #expect(try await f.manager.resolveProvisioningTarget(vmID: f.profile.id, sessionID: f.request.sessionID) == evidence.connection.binding)
        await f.manager.shutDown(f.profile.id)
        await f.probe.send(.init(readiness: .ready(user: "fixture_owner", command: "stale"), identity: evidence), index: 1)
        await #expect(throws: Error.self) { _ = try await f.manager.resolveProvisioningTarget(vmID: f.profile.id, sessionID: f.request.sessionID) }
        #expect(f.runtime.startedHandles.first?.shutdownCount == 1)
        await f.close()
    }
    @Test func recoveryFactoryUsesOnlyAdmittedTransportAndFakeRunnerAfterAuthority() async throws {
        let f = try await IdentityFixture(), identity = try f.evidence()
        await f.publish(identity)
        let admission = try await f.manager.admitProvisioningTransport(target: identity.connection.binding, report: f.provider.admittedReport(), policy: .fixture(f.provider.root))
        let authority = ProvisioningRecoveryTransportAuthority(manager: f.manager, admission: admission, admitPackage: {})
        let runner = SessionFixtureRunner()
        let adapter = try ProvisioningOperationalBackends.recovery(admission: admission, authority: authority, admitPackage: {}, makeRunner: { runner })
        #expect(await runner.invocations.isEmpty)
        let context = GuestJobContext(jobID: UUID(), payloadID: UUID(), target: identity.connection.binding, dependencyDigest: admission.dependencyDigest, mode: .apply)
        _ = try await adapter.perform(.init(id: UUID(), context: context, operation: .verifyIdentity, mode: .apply, inputLeaseID: nil, timeoutSeconds: 10, plan: nil, tasks: [], conflictPolicy: .fail))
        #expect(await runner.invocations.count == 1)
        await f.probe.send(.init(readiness: .connecting))
        await #expect(throws: Error.self) { _ = try await adapter.perform(.init(id: UUID(), context: context, operation: .quiesceOwnedWork, mode: .apply, inputLeaseID: nil, timeoutSeconds: 10, plan: nil, tasks: [], conflictPolicy: .fail)) }
        #expect(await runner.invocations.count == 1)
        #expect(ProvisioningProductExecution.enabled == (AppChannel.current == .development))
        await f.close()
    }
    @Test func operationalAuthorityRejectsBindingAndDigestChangesBeforeAnyFakeCommand() async throws {
        let f = try await IdentityFixture(), identity = try f.evidence()
        await f.publish(identity)
        let admission = try await f.manager.admitProvisioningTransport(target: identity.connection.binding, report: f.provider.admittedReport(), policy: .fixture(f.provider.root))
        let authority = ProvisioningRecoveryTransportAuthority(manager: f.manager, admission: admission, admitPackage: {})
        await #expect(throws: Error.self) { try await authority.revalidate(identity.connection.binding, dependencyDigest: String(repeating: "a", count: 64)) }
        let changed = try GuestBinding(vmID: f.profile.id, sessionID: f.request.sessionID, owner: "fixture_owner", ownerUID: 1011, hostKeyDigest: sessionFixtureHostKeyDigest)
        await #expect(throws: Error.self) { try await authority.revalidate(changed, dependencyDigest: admission.dependencyDigest) }
        await f.publish(try f.evidence(uid: 1011))
        await #expect(throws: Error.self) { try await authority.revalidate(identity.connection.binding, dependencyDigest: admission.dependencyDigest) }
        try Data("changed tool".utf8).write(to: f.provider.root.appendingPathComponent("ssh"))
        #expect(throws: Error.self) { _ = try ProvisioningOperationalBackends.recovery(admission: admission, authority: authority, admitPackage: {}, makeRunner: { throw ProvisioningServiceFailure.unavailable }) }
        #expect(f.provider.builds == 0); await f.close()
    }
}
