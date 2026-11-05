import Darwin
@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private struct BackupPort: HostPortProbing { func isAvailable(_ port: Int) -> Bool { true } }
private struct BackupMount: SharedFolderChecking { func check(_ request: VMStartRequest, user: String) async throws {} }
private actor BackupWorker: GuestHomeBackingUp {
    var completion: CheckedContinuation<Int64, any Error>?
    func started() -> Bool { completion != nil }
    func finish(fail: Bool = false) {
        if fail { completion?.resume(throwing: SSHGuestHomeBackup.failure()) }
        else { completion?.resume(returning: 1234) }
        completion = nil
    }
    func backup(_ request: VMStartRequest, user: String, operationID: UUID) async throws -> Int64 {
        // Intentionally ignores cancellation to model a late subprocess result.
        try await withCheckedThrowingContinuation { completion = $0 }
    }
}

@Suite("Guest home backup — disposable fixtures only")
struct GuestHomeBackupTests {
    @Test("host confirmation refuses links, public files, wrong sizes and replaced shares", arguments: ["valid", "symlink", "hardlink", "mode", "size", "share-replaced", "folder-symlink"])
    func hostOutput(_ variant: String) throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let share = SharedFolderMapping(hostPath: f.support.appendingPathComponent("Shared").path)
        try FileManager.default.createDirectory(atPath: share.hostPath, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let operation = UUID(), output = SSHGuestHomeBackup.destination(share, operationID: operation)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("fixture".utf8).write(to: output)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        let fd = open(share.hostPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        #expect(fd >= 0); defer { close(fd) }
        if variant == "symlink" {
            let saved = output.appendingPathExtension("saved")
            try FileManager.default.moveItem(at: output, to: saved)
            try FileManager.default.createSymbolicLink(at: output, withDestinationURL: saved)
        }
        if variant == "hardlink" { try FileManager.default.linkItem(at: output, to: output.appendingPathExtension("link")) }
        if variant == "mode" { #expect(chmod(output.path, 0o644) == 0) }
        if variant == "share-replaced" {
            try FileManager.default.moveItem(atPath: share.hostPath, toPath: share.hostPath + ".saved")
            try FileManager.default.createDirectory(atPath: share.hostPath, withIntermediateDirectories: false)
        }
        if variant == "folder-symlink" {
            let folder = output.deletingLastPathComponent(), saved = folder.appendingPathExtension("saved")
            try FileManager.default.moveItem(at: folder, to: saved)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: saved)
        }
        if variant == "valid" { try SSHGuestHomeBackup.verifyOutput(shareFD: fd, share: share, operationID: operation, bytes: 7) }
        else {
            #expect(throws: VMFailure.self) { try SSHGuestHomeBackup.verifyOutput(shareFD: fd, share: share, operationID: operation, bytes: variant == "size" ? 100 : 7) }
        }
    }
    @Test("reports require matching VM, session, operation and positive bytes", arguments: ["valid", "vm", "session", "operation", "bytes", "malformed", "oversized"])
    func reports(_ variant: String) throws {
        let p = VMProfile(id: UUID(), name: "Backup fixture")
        let request = VMStartRequest(profile: p, storageRoot: URL(fileURLWithPath: "/private/tmp/" + UUID().uuidString))
        let operation = UUID()
        let object: [String: Any] = ["vmID": variant == "vm" ? UUID().uuidString : p.id.uuidString,
            "sessionID": variant == "session" ? UUID().uuidString : request.sessionID.uuidString,
            "operationID": variant == "operation" ? UUID().uuidString : operation.uuidString,
            "bytes": variant == "bytes" ? 0 : 1234]
        let data = variant == "malformed" ? Data("{}".utf8) : variant == "oversized" ? Data(repeating: 32, count: 4097) : try JSONSerialization.data(withJSONObject: object)
        if variant == "valid" { #expect(try SSHGuestHomeBackup.decode(data, request: request, operationID: operation) == 1234) }
        else { #expect(throws: VMFailure.self) { try SSHGuestHomeBackup.decode(data, request: request, operationID: operation) } }
    }

    @Test("backup admission, duplicates, failures and late results preserve runtime ownership", arguments: ["success", "failure", "cancel", "shutdown", "exit"])
    func lifecycle(_ variant: String) async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var p = f.profile(); p.ssh = SSHOptions(hostPort: 22501)
        p.sharedFolder = SharedFolderMapping(hostPath: "/Users/fixture/Shared")
        let runtime = FakeRuntime(), worker = BackupWorker()
        let manager = VMManager(runtime: runtime, profiles: [p], applicationSupport: f.support,
                                portProbe: BackupPort(), sharingProbe: BackupMount(), homeBackup: worker)
        await #expect(throws: VMFailure.self) { try await manager.beginHomeBackup(p.id, confirmed: true) }
        try await manager.start(p.id)
        let handle = try #require(runtime.startedHandles.first)
        handle.emit(.ready)
        #expect(await eventually { await manager.snapshots()[0].state == .running })
        let session = try #require(await manager.snapshots()[0].sessionID)
        await #expect(throws: VMFailure.self) { try await manager.beginHomeBackup(p.id, confirmed: true) }
        await manager.receiveSSH(.ready(user: "owner", command: "fixture"), vmID: p.id, sessionID: session)
        #expect(await eventually { await manager.snapshots()[0].canBackUpHome })
        await #expect(throws: VMFailure.self) { try await manager.beginHomeBackup(p.id, confirmed: false) }
        let coordinator = UUID()
        try await manager.installProvisioningCoordinator(coordinator, blocked: [p.id])
        await #expect(throws: VMFailure.self) { try await manager.beginHomeBackup(p.id, confirmed: true) }
        await manager.clearUnstartedProvisioningHold(vmID: p.id)
        try await manager.beginHomeBackup(p.id, confirmed: true)
        #expect(await eventually { await worker.started() })
        let target = try GuestBinding(vmID: p.id, sessionID: session, owner: "owner", ownerUID: 1000, hostKeyDigest: String(repeating: "a", count: 64))
        await #expect(throws: ProvisioningJobFailure.self) {
            _ = try await manager.reserveProvisioning(owner: coordinator, jobID: UUID(), target: target, cancel: { _ in })
        }
        await #expect(throws: ProvisioningJobFailure.self) {
            _ = try await manager.reserveProvisioningPreparation(owner: coordinator, jobID: UUID(), target: target, cancel: {})
        }
        #expect(await manager.snapshots()[0].homeBackup.isBusy)
        #expect(await manager.activeSessionCount == 1)
        #expect(await manager.allocatedMemoryMiB == 4096)
        await #expect(throws: VMFailure.self) { try await manager.beginHomeBackup(p.id, confirmed: true) }
        if variant == "cancel" { await manager.cancelHomeBackup(p.id) }
        if variant == "shutdown" { await manager.shutDown(p.id) }
        if variant == "exit" {
            handle.emit(.exited(status: 0))
            #expect(await eventually { await manager.activeSessionCount == 0 })
            #expect(await manager.isIdle == false)
            await #expect(throws: VMFailure.self) { try await manager.start(p.id) }
            await #expect(throws: VMFailure.self) { try await manager.delete(p.id, confirmed: true, expectedIdentity: nil) }
        }
        if ["cancel", "shutdown", "exit"].contains(variant) {
            if case .cancelling = await manager.snapshots()[0].homeBackup {} else { Issue.record("Expected cancellation") }
        }
        await worker.finish(fail: variant == "failure")
        #expect(await eventually { await manager.snapshots()[0].homeBackup.isBusy == false })
        let result = await manager.snapshots()[0].homeBackup
        if variant == "success" {
            if case .completed(let url, let bytes) = result {
                #expect(bytes == 1234 && url.lastPathComponent == "home.tgz")
                #expect(url.deletingLastPathComponent().lastPathComponent.hasPrefix("home-backup-"))
            } else { Issue.record("Expected completed backup") }
        } else { if case .failed = result {} else { Issue.record("Late/failed backup reported success") } }
        if variant != "exit" {
            #expect(await manager.activeSessionCount == 1)
            handle.emit(.error(.init(code: .launchFailed, message: "fixture")))
            #expect(await manager.activeSessionCount == 1)
            handle.emit(.exited(status: 0))
        }
        #expect(await eventually { await manager.isIdle })
    }

    @Test("availability refuses paused, stopped, unmounted and unverified SSH states")
    func availability() {
        var p = VMProfile(id: UUID(), name: "Fixture"); p.ssh = SSHOptions(hostPort: 22502)
        p.sharedFolder = SharedFolderMapping(hostPath: "/Users/fixture/Shared")
        var s = VMSnapshot(profile: p, state: .running, sessionID: UUID(), sshReadiness: .ready(user: "owner", command: "fixture"), sharedFolderReadiness: .mounted)
        #expect(s.canBackUpHome)
        s.sharedFolderReadiness = .unverified; #expect(!s.canBackUpHome)
        s.sharedFolderReadiness = .mounted; s.sshReadiness = .connecting; #expect(!s.canBackUpHome)
        s.sshReadiness = .ready(user: "owner", command: "fixture")
        s.homeBackup = .working(URL(fileURLWithPath: "/private/tmp/fixture")); #expect(!s.canBackUpHome)
        s.homeBackup = .idle; s.experimentalPowerBusy = true; #expect(!s.canBackUpHome)
        for state in [VMState.paused, .stopped, .stopping, .hostSleeping, .executionUnknown] {
            #expect(!VMSnapshot(profile: p, state: state, sessionID: UUID(), sshReadiness: .ready(user: "owner", command: "fixture"), sharedFolderReadiness: .mounted).canBackUpHome)
        }
    }

    @Test("long SSH runner bounds output and timeout, and closes its lease on cancellation")
    func processControl() async throws {
        let runner = HomeBackupSSHProcess()
        let f = try RegistryFixture(); defer { f.cleanup() }
        let started = f.support.appendingPathComponent("started")
        let task = Task.detached { try runner.run(arguments: ["-c", "printf started > \"$1\"; read value; printf cancelled", "fixture", started.path], executable: URL(fileURLWithPath: "/bin/sh")) }
        #expect(await eventually { FileManager.default.fileExists(atPath: started.path) })
        runner.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(throws: (any Error).self) {
            try HomeBackupSSHProcess().run(arguments: ["-c", "read value"], executable: URL(fileURLWithPath: "/bin/sh"), timeout: 0.1)
        }
        #expect(throws: (any Error).self) {
            try HomeBackupSSHProcess().run(arguments: ["-c", "printf '%05000d' 0"], executable: URL(fileURLWithPath: "/bin/sh"))
        }
        #expect(try HomeBackupSSHProcess().run(arguments: ["-c", "printf '{}'"], executable: URL(fileURLWithPath: "/bin/sh")) == Data("{}".utf8))
    }
}
