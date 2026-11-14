@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private struct ReclaimPort: HostPortProbing { func isAvailable(_ port: Int) -> Bool { true } }
private struct ReclaimMount: SharedFolderChecking { func check(_ request: VMStartRequest, user: String) async throws {} }
private actor ReclaimWorker: GuestSpaceReclaiming {
    var completion: CheckedContinuation<[String], any Error>?
    var root: URL?
    func started() -> Bool { completion != nil }
    /// Models the guest's trim by freeing the root's fixture allocation.
    func finish(_ outcome: String = "success") {
        switch outcome {
        case "failure": completion?.resume(throwing: SSHGuestReclaim.failure(stage: "trim"))
        case "unsupported": completion?.resume(throwing: SSHGuestReclaim.failure(stage: "unsupported"))
        default:
            if let root { try? FileManager.default.removeItem(at: root.appendingPathComponent("trimmed.bin")) }
            completion?.resume(returning: ["root", "home"])
        }
        completion = nil
    }
    func reclaim(_ request: VMStartRequest, user: String, operationID: UUID) async throws -> [String] {
        root = request.storageRoot
        // Intentionally ignores cancellation to model a late subprocess result.
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
}

@Suite("Reclaim space — disposable fixtures only")
struct GuestReclaimTests {
    private func running(_ f: RegistryFixture, runtime: FakeRuntime, worker: ReclaimWorker, share: Bool = false) async throws -> (VMManager, VMProfile, FakeRuntimeHandle, UUID) {
        var p = f.profile(); p.ssh = SSHOptions(hostPort: 22511)
        if share { p.sharedFolder = SharedFolderMapping(hostPath: "/Users/fixture/Shared") }
        let manager = VMManager(runtime: runtime, profiles: [p], applicationSupport: f.support,
                                portProbe: ReclaimPort(), sharingProbe: ReclaimMount(), homeBackup: share ? HeldBackup() : nil, reclaim: worker)
        try await manager.start(p.id)
        let handle = try #require(runtime.startedHandles.first)
        handle.emit(.ready)
        #expect(await eventually { await manager.snapshots()[0].state == .running })
        let session = try #require(await manager.snapshots()[0].sessionID)
        return (manager, p, handle, session)
    }

    @Test("an unproven runtime never offers or runs Reclaim space")
    func unsupportedRuntime() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let runtime = FakeRuntime(), worker = ReclaimWorker()
        let (manager, p, handle, session) = try await running(f, runtime: runtime, worker: worker)
        await manager.receiveSSH(.ready(user: "owner", command: "fixture"), vmID: p.id, sessionID: session)
        #expect(await manager.snapshots()[0].guestTrimSupported == false)
        #expect(await manager.snapshots()[0].canReclaimSpace == false)
        do { _ = try await manager.reclaimSpace(p.id); Issue.record("An unproven runtime reclaimed") }
        catch let failure as VMFailure { #expect(failure.code == "reclaim-unsupported-runtime") }
        #expect(await worker.started() == false)
        handle.emit(.exited(status: 0))
        #expect(await eventually { await manager.isIdle })
    }

    @Test("admission, measurement, failures and late results preserve runtime ownership",
          arguments: ["success", "failure", "unsupported", "shutdown", "exit"])
    func lifecycle(_ variant: String) async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let runtime = FakeRuntime(guestTrimVersion: 1), worker = ReclaimWorker()
        let (manager, p, handle, session) = try await running(f, runtime: runtime, worker: worker)
        // SSH is not ready yet.
        do { _ = try await manager.reclaimSpace(p.id); Issue.record("Reclaimed without SSH") }
        catch let failure as VMFailure { #expect(failure.code == "reclaim-not-ready") }
        await manager.receiveSSH(.ready(user: "owner", command: "fixture"), vmID: p.id, sessionID: session)
        #expect(await eventually { await manager.snapshots()[0].canReclaimSpace })
        // Provisioning protection refuses it.
        let coordinator = UUID()
        try await manager.installProvisioningCoordinator(coordinator, blocked: [p.id])
        await #expect(throws: VMFailure.self) { _ = try await manager.reclaimSpace(p.id) }
        await manager.clearUnstartedProvisioningHold(vmID: p.id)

        let root = ManagerStorage(applicationSupport: f.support).root(for: p)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1 << 20).write(to: root.appendingPathComponent("trimmed.bin"))
        let request = Task { try await manager.reclaimSpace(p.id) }
        #expect(await eventually { await worker.started() })
        #expect(await manager.snapshots()[0].reclaim == .working)
        #expect(await manager.snapshots()[0].canReclaimSpace == false)
        #expect(await manager.isIdle == false)
        // The guest is held like a transaction while the trim runs.
        do { _ = try await manager.reclaimSpace(p.id); Issue.record("Duplicate reclaim admitted") }
        catch let failure as VMFailure { #expect(failure.code == "reclaim-busy") }
        let target = try GuestBinding(vmID: p.id, sessionID: session, owner: "owner", ownerUID: 1000, hostKeyDigest: String(repeating: "a", count: 64))
        await #expect(throws: ProvisioningJobFailure.self) {
            _ = try await manager.reserveProvisioning(owner: coordinator, jobID: UUID(), target: target, cancel: { _ in })
        }
        #expect(await manager.activeSessionCount == 1)
        if variant == "shutdown" { await manager.shutDown(p.id) }
        if variant == "exit" {
            handle.emit(.exited(status: 0))
            #expect(await eventually { await manager.activeSessionCount == 0 })
            #expect(await manager.isIdle == false)
            await #expect(throws: VMFailure.self) { try await manager.start(p.id) }
            await #expect(throws: VMFailure.self) { try await manager.delete(p.id, confirmed: true, expectedIdentity: nil) }
        }
        await worker.finish(variant == "failure" || variant == "unsupported" ? variant : "success")
        let outcome = await request.result
        let state = await manager.snapshots()[0].reclaim
        switch variant {
        case "success":
            let result = try outcome.get()
            #expect(result.filesystems == ["root", "home"])
            #expect(result.reclaimedBytes > 0 && result.afterBytes < result.beforeBytes)
            #expect(state == .completed(result))
            #expect(await manager.eventLog().contains { $0.text == "Reclaim space finished: allocation fell by \(result.reclaimedBytes) bytes" })
        case "failure":
            #expect(throws: VMFailure.self) { try outcome.get() }
            if case .failure(let error as VMFailure) = outcome { #expect(error.code == "reclaim-failed" && error.diagnostics == "stage=trim") }
            #expect(await manager.eventLog().contains { $0.text == "Reclaim space did not complete (stage=trim)" })
            if case .failed = state {} else { Issue.record("Expected a failed reclaim") }
        case "unsupported":
            if case .failure(let error as VMFailure) = outcome { #expect(error.code == "reclaim-unsupported-guest") }
            else { Issue.record("Expected an unsupported guest") }
        default:
            // A late success after shutdown or exit is never reported.
            if case .failure(let error as VMFailure) = outcome { #expect(error.code == "reclaim-interrupted") }
            else { Issue.record("A cancelled reclaim reported success") }
        }
        #expect(await manager.snapshots()[0].reclaim.isBusy == false)
        if variant != "exit" {
            #expect(await manager.activeSessionCount == 1)
            handle.emit(.error(.init(code: .launchFailed, message: "fixture")))
            #expect(await manager.activeSessionCount == 1)
            handle.emit(.exited(status: 0))
        }
        #expect(await eventually { await manager.isIdle })
    }

    @Test("Reclaim space and home backup exclude each other")
    func exclusion() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let runtime = FakeRuntime(guestTrimVersion: 1), worker = ReclaimWorker()
        let (manager, p, handle, session) = try await running(f, runtime: runtime, worker: worker, share: true)
        await manager.receiveSSH(.ready(user: "owner", command: "fixture"), vmID: p.id, sessionID: session)
        #expect(await eventually { await manager.snapshots()[0].canBackUpHome })
        let request = Task { try await manager.reclaimSpace(p.id) }
        #expect(await eventually { await worker.started() })
        #expect(await manager.snapshots()[0].canBackUpHome == false)
        await #expect(throws: VMFailure.self) { try await manager.beginHomeBackup(p.id, confirmed: true) }
        await worker.finish()
        _ = try await request.value
        try await manager.beginHomeBackup(p.id, confirmed: true)
        #expect(await manager.snapshots()[0].canReclaimSpace == false)
        do { _ = try await manager.reclaimSpace(p.id); Issue.record("Reclaim ran during a backup") }
        catch let failure as VMFailure { #expect(failure.code == "reclaim-busy") }
        handle.emit(.exited(status: 0))
        #expect(await eventually { await manager.activeSessionCount == 0 })
    }

    @Test("availability requires the runtime capability, managed SSH and a running guest")
    func availability() {
        var p = VMProfile(id: UUID(), name: "Fixture"); p.ssh = SSHOptions(hostPort: 22512)
        let ready = SSHReadiness.ready(user: "owner", command: "fixture")
        var s = VMSnapshot(profile: p, state: .running, sessionID: UUID(), sshReadiness: ready, guestTrimSupported: true)
        #expect(s.canReclaimSpace)
        s.guestTrimSupported = false; #expect(!s.canReclaimSpace)
        s.guestTrimSupported = true; s.sshReadiness = .connecting; #expect(!s.canReclaimSpace)
        s.sshReadiness = ready; s.reclaim = .working; #expect(!s.canReclaimSpace)
        #expect(!s.canBackUpHome && !s.canAttemptExperimentalSuspend)
        s.reclaim = .idle; s.experimentalPowerBusy = true; #expect(!s.canReclaimSpace)
        s.experimentalPowerBusy = false; s.homeBackup = .working(URL(fileURLWithPath: "/private/tmp/fixture")); #expect(!s.canReclaimSpace)
        for state in [VMState.paused, .stopped, .stopping, .hostSleeping, .executionUnknown] {
            #expect(!VMSnapshot(profile: p, state: state, sessionID: UUID(), sshReadiness: ready, guestTrimSupported: true).canReclaimSpace)
        }
        p.ssh = nil
        #expect(!VMSnapshot(profile: p, state: .running, sessionID: UUID(), sshReadiness: ready, guestTrimSupported: true).canReclaimSpace)
    }

    @Test("reports require matching VM, session, operation and known filesystems",
          arguments: ["valid", "root-only", "vm", "session", "operation", "no-root", "unknown", "duplicate", "malformed", "oversized"])
    func reports(_ variant: String) throws {
        let p = VMProfile(id: UUID(), name: "Reclaim fixture")
        let request = VMStartRequest(profile: p, storageRoot: URL(fileURLWithPath: "/private/tmp/" + UUID().uuidString))
        let operation = UUID()
        let filesystems: [String] = switch variant {
        case "root-only": ["root"]
        case "no-root": ["home"]
        case "unknown": ["root", "/home/owner"]
        case "duplicate": ["root", "root"]
        default: ["root", "home"]
        }
        let object: [String: Any] = ["vmID": variant == "vm" ? UUID().uuidString : p.id.uuidString,
            "sessionID": variant == "session" ? UUID().uuidString : request.sessionID.uuidString,
            "operationID": variant == "operation" ? UUID().uuidString : operation.uuidString,
            "filesystems": filesystems]
        let data = variant == "malformed" ? Data("{}".utf8) : variant == "oversized" ? Data(repeating: 32, count: 4097) : try JSONSerialization.data(withJSONObject: object)
        if ["valid", "root-only"].contains(variant) { #expect(try SSHGuestReclaim.decode(data, request: request, operationID: operation) == filesystems) }
        else { #expect(throws: VMFailure.self) { try SSHGuestReclaim.decode(data, request: request, operationID: operation) } }
    }

    @Test("a nonzero guest exit reports only its fixed stage, mapped to a stable code", arguments: [
        ("printf '{\"failure\":\"trim\"}'; exit 1", "reclaim-failed", "stage=trim"),
        ("printf '{\"failure\":\"prerequisites\",\"errno\":2}'; exit 1", "reclaim-failed", "stage=prerequisites errno=2"),
        ("printf '{\"failure\":\"unsupported\"}'; exit 1", "reclaim-unsupported-guest", "stage=unsupported"),
        ("printf '{\"failure\":\"/home/owner/private\"}'; exit 1", "reclaim-failed", ""),
        ("exit 255", "reclaim-failed", ""),
    ])
    func stagedExit(_ script: String, _ code: String, _ diagnostics: String) {
        do {
            _ = try HomeBackupSSHProcess().run(arguments: ["-c", script], executable: URL(fileURLWithPath: "/bin/sh"), timeout: 5,
                                               failure: { $0.map(SSHGuestReclaim.failure(report:)) ?? SSHGuestReclaim.failure() })
            Issue.record("A nonzero exit succeeded")
        } catch let failure as VMFailure {
            #expect(failure.code == code && failure.diagnostics == diagnostics)
            #expect(!failure.message.contains("private"))
        } catch { Issue.record("Unexpected error \(error)") }
    }

    @Test("the guest program is packaged and calls only the fixed helper through sudo -n")
    func resource() throws {
        let url = try #require(ManagerResources.bundle.url(forResource: "GuestReclaim", withExtension: "py"))
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("[SUDO, '-n', HELPER]"))
        #expect(source.contains("HELPER = '/usr/bin/try-omarchy-reclaim'"))
        #expect(!source.contains("shell=True"))
    }
}

/// A home backup that never finishes, to hold the guest for the exclusion test.
private struct HeldBackup: GuestHomeBackingUp {
    func backup(_ request: VMStartRequest, user: String, operationID: UUID) async throws -> Int64 {
        try await Task.sleep(for: .seconds(3600)); return 1
    }
}
