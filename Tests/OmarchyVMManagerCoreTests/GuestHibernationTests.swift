import Darwin
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private func powerCapability(kernel: GuestHibernationCapability.KernelSupport = .supported, disk: Bool = true, swap: Bool = true, resume: Bool = true, permission: Bool = true) -> GuestHibernationCapability {
    .init(kernel: "7.2.8-test", kernelSupport: kernel, diskStateAvailable: disk, persistentSwap: swap, resumeConfigured: resume, nonInteractivePermission: permission)
}
private struct PowerSSH: SSHReadinessChecking {
    func monitor(_ request: VMStartRequest, update: @escaping @Sendable (SSHReadiness) async -> Void) async {
        await update(.ready(user: "owner", command: "synthetic"))
        do { try await Task.sleep(for: .seconds(60)) } catch {}
    }
}
private actor PowerGuest: GuestHibernating {
    let available: GuestHibernationCapability
    let result: GuestRestoreResult
    var requests = 0
    var verificationFails = false
    func failVerification(_ value: Bool) { verificationFails = value }
    var proof: GuestSuspendProof?
    var pausePreparation = false
    var preparation: CheckedContinuation<Void, Never>?
    func blockPreparation() { pausePreparation = true }
    func releasePreparation() { preparation?.resume(); preparation = nil }
    var isPreparing: Bool { preparation != nil }
    var pauseVerification = false
    var verification: CheckedContinuation<Void, Never>?
    func blockVerification() { pauseVerification = true }
    func releaseVerification() { verification?.resume(); verification = nil }
    var isVerifying: Bool { verification != nil }
    init(capability: GuestHibernationCapability = powerCapability(), result: GuestRestoreResult = .restored) { available = capability; self.result = result }
    func capability(_ request: VMStartRequest, user: String) async throws -> GuestHibernationCapability { available }
    func prepare(_ request: VMStartRequest, user: String, token: UUID) async throws -> GuestSuspendProof {
        if pausePreparation { await withCheckedContinuation { preparation = $0 } }
        let value = GuestSuspendProof(token: token, bootID: UUID(), kernel: available.kernel); proof = value; return value
    }
    func hibernate(_ request: VMStartRequest, user: String) async throws { requests += 1 }
    func verifyRestore(_ request: VMStartRequest, user: String, origin: UUID, proof: GuestSuspendProof) async throws -> GuestRestoreResult {
        if pauseVerification { await withCheckedContinuation { verification = $0 } }
        if verificationFails { throw SSHGuestHibernation.failure() }
        return result
    }
}
private struct PowerPorts: HostPortProbing { func isAvailable(_ port: Int) -> Bool { true } }

@Suite("Experimental guest hibernation")
struct GuestHibernationTests {
    private func fixture(_ f: RegistryFixture, guest: PowerGuest) async throws -> (VMManager, VMProfile, FakeRuntime, FakeRuntimeHandle) {
        var profile = f.profile(); profile.ssh = SSHOptions(hostPort: 22222)
        let root = try f.storage.prepare(profile)
        try PrivateFiles.directory(root.appendingPathComponent("shell"), create: true)
        try PrivateFiles.write(Data(repeating: 0, count: 4096), name: "disk.img", in: root.appendingPathComponent("shell"))
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: f.support, sshProbe: PowerSSH(), portProbe: PowerPorts(), hibernation: guest)
        try await manager.start(profile.id)
        let handle = try #require(runtime.startedHandles.first); handle.emit(.ready)
        #expect(await eventually { await manager.snapshots()[0].hibernation != nil })
        return (manager, profile, runtime, handle)
    }
    @Test("kernel support alone never makes an attempt available")
    func requirements() {
        #expect(powerCapability().canAttempt)
        for value in [powerCapability(kernel: .unsupported), powerCapability(kernel: .unknown), powerCapability(disk: false), powerCapability(swap: false), powerCapability(resume: false), powerCapability(permission: false)] {
            #expect(!value.canAttempt)
            #expect(!value.detail.isEmpty)
        }
    }
    @Test("unsupported kernel and missing opt-in never send a power request")
    func rejection() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let guest = PowerGuest(capability: powerCapability(kernel: .unsupported, disk: false))
        let (manager, profile, _, handle) = try await fixture(f, guest: guest)
        await #expect(throws: VMFailure.self) { try await manager.experimentalSuspend(profile.id, confirmed: false) }
        await #expect(throws: VMFailure.self) { try await manager.experimentalSuspend(profile.id, confirmed: true) }
        #expect(await guest.requests == 0)
        #expect(await manager.snapshots()[0].suspension == nil)
        handle.emit(.exited(status: 0)); #expect(await eventually { await manager.isIdle })
    }
    @Test("exit releases allocation, durable protection survives reopening, and only memory proof unlocks it")
    func restored() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let guest = PowerGuest()
        let (manager, profile, _, handle) = try await fixture(f, guest: guest)
        try await manager.experimentalSuspend(profile.id, confirmed: true)
        #expect(await guest.requests == 1)
        #expect(await manager.activeSessionCount == 1)
        #expect(await manager.allocatedMemoryMiB == 4096)
        #expect(try ExperimentalSuspendStore(root: f.storage.root(for: profile)).load(vmID: profile.id)?.stage == .requested)
        handle.emit(.error(.init(code: .launchFailed, message: "diagnostic")))
        #expect(await manager.activeSessionCount == 1)
        handle.emit(.exited(status: 0)); #expect(await eventually { await manager.isIdle })
        #expect(await manager.allocatedMemoryMiB == 0)
        await #expect(throws: VMFailure.self) { try await manager.start(profile.id) }
        await #expect(throws: VMFailure.self) { try await manager.configure(profile) }
        await #expect(throws: VMFailure.self) { try await manager.deletionRequest(profile.id) }
        let runtime = FakeRuntime()
        let reopened = VMManager(runtime: runtime, profiles: [profile], applicationSupport: f.support, sshProbe: PowerSSH(), portProbe: PowerPorts(), hibernation: guest)
        #expect(await reopened.snapshots()[0].suspension?.stage == .restorePending)
        try await reopened.restoreExperimentalSuspension(profile.id, confirmed: true)
        let restored = try #require(runtime.startedHandles.first); restored.emit(.ready)
        #expect(await eventually { await reopened.snapshots()[0].suspension == nil })
        #expect(await reopened.activeSessionCount == 1)
        #expect(try ExperimentalSuspendStore(root: f.storage.root(for: profile)).load(vmID: profile.id) == nil)
        restored.emit(.exited(status: 0)); #expect(await eventually { await reopened.isIdle })
    }
    @Test("cold boot is a failure requiring acknowledgement, not a successful restore", arguments: [true, false])
    func coldBoot(acknowledge: Bool) async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let guest = PowerGuest(result: .coldBoot)
        let (manager, profile, runtime, handle) = try await fixture(f, guest: guest)
        try await manager.experimentalSuspend(profile.id, confirmed: true)
        handle.emit(.exited(status: 0)); #expect(await eventually { await manager.isIdle })
        try await manager.restoreExperimentalSuspension(profile.id, confirmed: true)
        let next = try #require(runtime.startedHandles.last); next.emit(.ready)
        #expect(await eventually { await manager.snapshots()[0].suspension?.stage == .coldBootDetected })
        if !acknowledge {
            next.emit(.exited(status: 0)); #expect(await eventually { await manager.isIdle })
            #expect(await manager.snapshots()[0].suspension?.stage == .coldBootDetected)
            #expect(!(await manager.snapshots()[0].canRestoreExperimentalSuspension))
            await #expect(throws: VMFailure.self) { try await manager.restoreExperimentalSuspension(profile.id, confirmed: true) }
            return
        }
        await #expect(throws: VMFailure.self) { try await manager.acceptExperimentalColdBoot(profile.id, confirmed: false) }
        await #expect(throws: VMFailure.self) { try await manager.acceptExperimentalColdBoot(profile.id, confirmed: true) }
        try await manager.acceptExperimentalColdBoot(profile.id, confirmed: true, guestImageCleared: true)
        #expect(await manager.snapshots()[0].suspension == nil)
        next.emit(.exited(status: 0)); #expect(await eventually { await manager.isIdle })
    }
    @Test("a stuck request retains handles and reservations; quit does not interrupt it")
    func timeout() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let (manager, profile, _, handle) = try await fixture(f, guest: PowerGuest())
        try await manager.experimentalSuspend(profile.id, confirmed: true, exitTimeout: .milliseconds(20))
        #expect(await eventually { await manager.snapshots()[0].suspension?.stage == .recoveryRequired })
        #expect(await manager.activeSessionCount == 1)
        #expect(await manager.allocatedMemoryMiB == 4096)
        #expect(!(await manager.beginApplicationShutdown()))
        #expect(handle.shutdownCount == 0 && handle.terminationCount == 0)
        await #expect(throws: VMFailure.self) { try await manager.pause(profile.id) }
        try await manager.forceStop(profile.id, confirmed: true)
        #expect(await manager.activeSessionCount == 1)
        handle.emit(.exited(status: 0)); #expect(await eventually { await manager.isIdle })
        #expect(await manager.snapshots()[0].suspension?.stage == .recoveryRequired)
    }
    @Test("altered disk, runtime, unsafe metadata and changed settings cannot restore automatically", arguments: ["disk", "firmware", "runtime", "settings", "malformed", "permissions", "symlink"])
    func changed(kind: String) async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let guest = PowerGuest(); let (manager, profile, _, handle) = try await fixture(f, guest: guest)
        try await manager.experimentalSuspend(profile.id, confirmed: true)
        handle.emit(.exited(status: 0)); #expect(await eventually { await manager.isIdle })
        let root = f.storage.root(for: profile), store = ExperimentalSuspendStore(root: f.storage.root(for: profile))
        if kind == "firmware" { try PrivateFiles.write(Data([1]), name: "efi-vars.fd", in: root.appendingPathComponent("shell")) }
        if kind == "disk" { try Data([1]).write(to: root.appendingPathComponent("shell/disk.img")) }
        if kind == "settings" { try PrivateFiles.write(Data("{}".utf8), name: "settings.json", in: root) }
        if kind == "runtime" {
            let data = try PrivateFiles.read(root.appendingPathComponent(".manager-suspension.json"))
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]; object["runtimeDigest"] = "different"
            try PrivateFiles.write(JSONSerialization.data(withJSONObject: object), name: ".manager-suspension.json", in: root)
        }
        if kind == "permissions" { chmod(root.appendingPathComponent(".manager-suspension.json").path, 0o644) }
        if kind == "symlink" {
            try FileManager.default.removeItem(at: root.appendingPathComponent(".manager-suspension.json"))
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".manager-suspension.json").path, withDestinationPath: "/dev/null")
        }
        if kind == "malformed" { try PrivateFiles.write(Data("{}".utf8), name: ".manager-suspension.json", in: root) }
        let reopened = VMManager(runtime: FakeRuntime(), profiles: [profile], applicationSupport: f.support, hibernation: guest)
        await #expect(throws: (any Error).self) { try await reopened.restoreExperimentalSuspension(profile.id, confirmed: true) }
        await #expect(throws: (any Error).self) { try await reopened.start(profile.id) }
        #expect(PrivateFiles.exists(root.appendingPathComponent(".manager-suspension.json")))
        _ = store
    }
    @Test("late preparation cannot hibernate a stopped or replacement session")
    func latePreparation() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let guest = PowerGuest(); let (manager, profile, runtime, handle) = try await fixture(f, guest: guest)
        await guest.blockPreparation()
        let attempt = Task { try await manager.experimentalSuspend(profile.id, confirmed: true) }
        #expect(await eventually { await guest.isPreparing })
        await manager.shutDown(profile.id); handle.emit(.exited(status: 0))
        #expect(await eventually { await manager.isIdle })
        try await manager.start(profile.id)
        let next = try #require(runtime.startedHandles.last); next.emit(.ready)
        await guest.releasePreparation()
        await #expect(throws: VMFailure.self) { try await attempt.value }
        #expect(await guest.requests == 0)
        #expect(await manager.snapshots()[0].suspension == nil)
        next.emit(.exited(status: 0)); #expect(await eventually { await manager.isIdle })
    }

    @Test("newly appeared suspension metadata is preserved before any power request")
    func appearedMetadata() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let guest = PowerGuest(); let (manager, profile, _, handle) = try await fixture(f, guest: guest)
        await guest.blockPreparation()
        let attempt = Task { try await manager.experimentalSuspend(profile.id, confirmed: true) }
        #expect(await eventually { await guest.isPreparing })
        let root = f.storage.root(for: profile)
        try PrivateFiles.write(Data("{}".utf8), name: ".manager-suspension.json", in: root)
        await guest.releasePreparation()
        await #expect(throws: (any Error).self) { try await attempt.value }
        #expect(await guest.requests == 0)
        #expect(try PrivateFiles.read(root.appendingPathComponent(".manager-suspension.json")) == Data("{}".utf8))
        #expect(await manager.snapshots()[0].suspensionMetadataUnsafe)
        handle.emit(.exited(status: 0)); #expect(await eventually { await manager.isIdle })
    }

    @Test("late restore replies cannot clear protection after exit or trigger another unsafe boot")
    func lateRestore() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let guest = PowerGuest(); let (manager, profile, runtime, handle) = try await fixture(f, guest: guest)
        try await manager.experimentalSuspend(profile.id, confirmed: true)
        handle.emit(.exited(status: 0)); #expect(await eventually { await manager.isIdle })
        await guest.blockVerification()
        try await manager.restoreExperimentalSuspension(profile.id, confirmed: true)
        let next = try #require(runtime.startedHandles.last); next.emit(.ready)
        #expect(await eventually { await guest.isVerifying })
        await manager.shutDown(profile.id); next.emit(.exited(status: 0))
        #expect(await eventually { await manager.isIdle })
        await guest.releaseVerification()
        await #expect(throws: VMFailure.self) { try await manager.restoreExperimentalSuspension(profile.id, confirmed: true) }
        await #expect(throws: VMFailure.self) { try await manager.start(profile.id) }
        #expect(await manager.snapshots()[0].suspension != nil)
        #expect(runtime.startedHandles.count == 2)
    }
    @Test("host sleep acknowledgements retain the disk guard and wake never boots a saved guest")
    func hostSleep() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let (manager, profile, runtime, handle) = try await fixture(f, guest: PowerGuest())
        try await manager.experimentalSuspend(profile.id, confirmed: true)
        handle.emit(.executionState(.init(state: .hostSleeping)))
        #expect(await eventually { await manager.snapshots()[0].state == .hostSleeping })
        #expect(await manager.allocatedMemoryMiB == 4096)
        #expect(await manager.snapshots()[0].suspension?.stage == .requested)
        handle.emit(.executionState(.init(state: .running)))
        #expect(await eventually { await manager.snapshots()[0].state == .running })
        handle.emit(.exited(status: 0)); #expect(await eventually { await manager.isIdle })
        handle.emit(.executionState(.init(state: .running)))
        #expect(await manager.activeSessionCount == 0)
        #expect(runtime.startedHandles.count == 1)
        #expect(await manager.snapshots()[0].suspension?.stage == .restorePending)
    }

    @Test("an unreachable restore can recheck proof without another VM boot")
    func retryReadOnlyVerification() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let guest = PowerGuest(); let (manager, profile, runtime, handle) = try await fixture(f, guest: guest)
        try await manager.experimentalSuspend(profile.id, confirmed: true)
        handle.emit(.exited(status: 0)); #expect(await eventually { await manager.isIdle })
        await guest.failVerification(true)
        try await manager.restoreExperimentalSuspension(profile.id, confirmed: true, verificationTimeout: .milliseconds(20))
        let next = try #require(runtime.startedHandles.last); next.emit(.ready)
        #expect(await eventually { await manager.snapshots()[0].suspension?.stage == .recoveryRequired })
        #expect(await manager.activeSessionCount == 1)
        await guest.failVerification(false)
        try await manager.retryExperimentalRestoreVerification(profile.id)
        #expect(await eventually { await manager.snapshots()[0].suspension == nil })
        #expect(runtime.startedHandles.count == 2)
        next.emit(.exited(status: 0)); #expect(await eventually { await manager.isIdle })
    }

    @Test("power reports are bound to a pinned VM/session/user and reject malformed kernel strings")
    func reports() throws {
        let profile = VMProfile(id: UUID(), name: "Power report fixture")
        let request = VMStartRequest(profile: profile, storageRoot: URL(fileURLWithPath: "/private/tmp/power-never-created"))
        var identity: [String: Any] = ["vmID": profile.id.uuidString, "sessionToken": request.sessionID.uuidString, "user": "owner", "uid": 1000]
        func data(_ capability: GuestHibernationCapability) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["identity": identity, "capability": JSONSerialization.jsonObject(with: JSONEncoder().encode(capability))])
        }
        #expect(try SSHGuestHibernation.decodeCapability(data(powerCapability()), request: request, user: "owner").canAttempt)
        for key in ["vmID", "sessionToken", "user", "uid"] {
            let original = identity[key]; identity[key] = key == "uid" ? 0 : key == "user" ? "root" : UUID().uuidString
            #expect(throws: (any Error).self) { try SSHGuestHibernation.decodeCapability(data(powerCapability()), request: request, user: "owner") }; identity[key] = original
        }
        #expect(!SSHGuestHibernation.validKernel("7.2\nprivate"))
        #expect(!SSHGuestHibernation.validKernel(String(repeating: "x", count: 129)))
        let proof = GuestSuspendProof(token: UUID(), bootID: UUID(), kernel: "7.2-test")
        identity["sessionToken"] = UUID().uuidString
        let origin = UUID(uuidString: identity["sessionToken"] as! String)!
        var report: [String: Any] = ["identity": identity, "bootID": proof.bootID.uuidString, "proof": try JSONSerialization.jsonObject(with: JSONEncoder().encode(proof))]
        if case .restored = try SSHGuestHibernation.decodeRestore(JSONSerialization.data(withJSONObject: report), request: request, user: "owner", origin: origin, proof: proof) {} else { Issue.record("Memory proof should restore") }
        report["bootID"] = UUID().uuidString; report["proof"] = NSNull()
        #expect(throws: (any Error).self) { try SSHGuestHibernation.decodeRestore(JSONSerialization.data(withJSONObject: report), request: request, user: "owner", origin: origin, proof: proof) }
        identity["sessionToken"] = request.sessionID.uuidString; report["identity"] = identity
        if case .coldBoot = try SSHGuestHibernation.decodeRestore(JSONSerialization.data(withJSONObject: report), request: request, user: "owner", origin: origin, proof: proof) {} else { Issue.record("Cold boot should not restore memory") }
    }
}
