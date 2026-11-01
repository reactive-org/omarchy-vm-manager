import Darwin
import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

private struct SharePort: HostPortProbing { func isAvailable(_ port: Int) -> Bool { true } }
private actor ShareProbe: SharedFolderChecking {
    var calls = 0
    var fail = false
    func setFailure(_ value: Bool) { fail = value }
    func count() -> Int { calls }
    func check(_ request: VMStartRequest, user: String) async throws {
        calls += 1
        if fail { throw SSHSharedFolderProbe.failure() }
    }
}

private actor DelayedShareProbe: SharedFolderChecking {
    var completion: CheckedContinuation<Void, Never>?
    func started() -> Bool { completion != nil }
    func finish() { completion?.resume(); completion = nil }
    func check(_ request: VMStartRequest, user: String) async throws {
        // Deliberately ignores cancellation, like an already-finishing subprocess.
        await withCheckedContinuation { completion = $0 }
    }
}

private actor ShareTransport {
    let replies: [SSHProbeProcess.Result]
    var calls = 0
    init(_ replies: [SSHProbeProcess.Result]) { self.replies = replies }
    func count() -> Int { calls }
    func run(_ arguments: [String]) -> SSHProbeProcess.Result {
        let result = replies[min(calls, replies.count - 1)]; calls += 1; return result
    }
}

private actor DelayedPowerProbe: GuestHibernating {
    var completion: CheckedContinuation<GuestHibernationCapability, Never>?
    func started() -> Bool { completion != nil }
    func finish() {
        completion?.resume(returning: .init(kernel: "fixture", kernelSupport: .unknown, diskStateAvailable: false, persistentSwap: false, resumeConfigured: false, nonInteractivePermission: false))
        completion = nil
    }
    func capability(_ request: VMStartRequest, user: String) async throws -> GuestHibernationCapability {
        await withCheckedContinuation { completion = $0 }
    }
    func prepare(_ request: VMStartRequest, user: String, token: UUID) async throws -> GuestSuspendProof { throw SSHSharedFolderProbe.failure() }
    func hibernate(_ request: VMStartRequest, user: String) async throws { throw SSHSharedFolderProbe.failure() }
    func verifyRestore(_ request: VMStartRequest, user: String, origin: UUID, proof: GuestSuspendProof) async throws -> GuestRestoreResult { throw SSHSharedFolderProbe.failure() }
}

@Suite("Native host-folder sharing — no guests")
struct SharedFolderTests {
    @Test("read-only sharing retries transport failures but never trust or mount-report failures", arguments: ["transient", "persistent", "identity", "authentication", "malformed"])
    func transportRetries(_ variant: String) async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var profile = f.profile(); profile.ssh = SSHOptions(hostPort: 22007)
        let root = try f.storage.prepare(profile)
        let request = VMStartRequest(profile: profile, storageRoot: root)
        let report: [String: Any] = ["identity": ["vmID": profile.id.uuidString, "sessionToken": request.sessionID.uuidString, "user": "owner", "uid": 1000], "accessible": true,
                                   "mount": ["filesystems": [["source": "mac", "target": "/mnt/mac", "fstype": "9p", "options": "rw,relatime,cache=0x1,access=client,msize=512000,trans=virtio"]]]]
        let good = SSHProbeProcess.Result(status: 0, output: try JSONSerialization.data(withJSONObject: report), hostKeyMismatch: false, failureKind: "unknown")
        let bad = SSHProbeProcess.Result(status: variant == "malformed" ? 0 : 255, output: Data("{}".utf8), hostKeyMismatch: variant == "identity", failureKind: variant == "authentication" ? "authentication" : "closed")
        let transport = ShareTransport(variant == "transient" ? [bad, bad, good] : [bad])
        let probe = SSHSharedFolderProbe(transport: { args in await transport.run(args) })
        if variant == "transient" { try await probe.check(request, user: "owner") }
        else { await #expect(throws: VMFailure.self) { try await probe.check(request, user: "owner") } }
        #expect(await transport.count() == (["transient", "persistent"].contains(variant) ? 3 : 1))
    }

    @Test("sharing waits for the optional power probe before opening another SSH connection")
    func serialProbes() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var p = f.profile(); p.ssh = SSHOptions(hostPort: 22008)
        p.sharedFolder = SharedFolderMapping(hostPath: "/Users/fixture/Shared")
        let runtime = FakeRuntime(), power = DelayedPowerProbe(), sharing = ShareProbe()
        let manager = VMManager(runtime: runtime, profiles: [p], applicationSupport: f.support, portProbe: SharePort(), hibernation: power, sharingProbe: sharing)
        try await manager.start(p.id)
        let handle = try #require(runtime.startedHandles.first); handle.emit(.ready)
        #expect(await eventually { await manager.snapshots()[0].state == .running })
        let session = try #require(await manager.snapshots()[0].sessionID)
        await manager.receiveSSH(.ready(user: "owner", command: "fixture"), vmID: p.id, sessionID: session)
        #expect(await eventually { await power.started() })
        #expect(await sharing.count() == 0)
        await power.finish()
        #expect(await eventually { await manager.snapshots()[0].sharedFolderReadiness == .mounted })
        #expect(await sharing.count() == 1)
        handle.emit(.exited(status: 0))
        #expect(await eventually { await manager.activeSessionCount == 0 })
    }
    @Test("storage helper admits sharing schema 5 only for a unique pending reviewed profile", arguments: ["valid", "legacy", "future", "unreviewed", "duplicate", "other-id"])
    func helperAdmission(_ variant: String) throws {
        var profile = VMProfile(id: UUID(), name: "Disposable helper admission")
        if variant != "legacy" { profile.sharedFolder = SharedFolderMapping(hostPath: "/missing/Shared", enabled: false) }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        let object: [String: Any] = [
            "schemaVersion": variant == "legacy" ? 4 : variant == "future" ? 6 : 5,
            "profiles": variant == "duplicate" ? [encoded, encoded] : [encoded],
            "pendingDeletions": variant == "unreviewed" ? [] : [profile.id.uuidString]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let id = variant == "other-id" ? UUID() : profile.id
        if ["valid", "legacy"].contains(variant) {
            #expect(try RegistryStore.profileForDeletion(in: data, id: id) == profile)
        } else { #expect(throws: (any Error).self) { try RegistryStore.profileForDeletion(in: data, id: id) } }
    }
    @Test("SSH failure categories never expose stderr, paths or identities")
    func sshFailures() {
        #expect(SSHProbeProcess.failureKind("Permission denied (publickey); synthetic-private-data") == "authentication")
        #expect(SSHProbeProcess.failureKind("ssh: connect to host synthetic-host port 2222: Connection refused") == "refused")
        #expect(SSHProbeProcess.failureKind("Bad port 'synthetic-private-data'") == "configuration")
        #expect(SSHProbeProcess.failureKind("unrecognized synthetic-private-data") == "unknown")
    }
    @Test("dedicated owned folders expand ~/ and broad, hidden, missing and linked paths fail closed")
    func paths() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let share = f.support.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(try SharedFolderPolicy.mapping(path: "~/Shared", home: f.support).hostPath == share.path)
        for path in [f.support.path, "/", "/Users", "/tmp", "relative", share.path + "/../Shared", share.path + ",bad", share.path + "\n", f.support.appendingPathComponent("missing").path] {
            #expect(throws: VMFailure.self) { try SharedFolderPolicy.mapping(path: path, home: f.support) }
        }
        for name in ["Library", ".ssh", "Documents"] {
            let folder = f.support.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            #expect(throws: VMFailure.self) { try SharedFolderPolicy.mapping(path: folder.path, home: f.support) }
        }
        let link = f.support.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: share)
        #expect(throws: VMFailure.self) { try SharedFolderPolicy.mapping(path: link.path, home: f.support) }
        #expect(chmod(share.path, 0o777) == 0)
        #expect(throws: VMFailure.self) { try SharedFolderPolicy.mapping(path: share.path, home: f.support) }
    }

    @Test("nested credential trees, symbolic links, hard links and special files are refused", arguments: ["credential", "symlink", "hardlink", "fifo"])
    func contents(_ kind: String) throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let share = f.support.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let entry = share.appendingPathComponent(kind == "credential" ? ".ssh" : "entry")
        switch kind {
        case "credential": try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: false)
        case "symlink": try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: f.support)
        case "hardlink":
            let source = f.support.appendingPathComponent("outside")
            try Data("fixture".utf8).write(to: source)
            try FileManager.default.linkItem(at: source, to: entry)
        default: #expect(mkfifo(entry.path, 0o600) == 0)
        }
        #expect(throws: VMFailure.self) { try SharedFolderPolicy.mapping(path: share.path, home: f.support) }
    }

    @Test("CLI exposes opt-in, default path, update disable and strict types")
    func cli() throws {
        let enabled = try #require(GuestCLIInvocation.parse(["create", "work", "--share", "on", "--share-path", "~/WorkShare"]).request)
        #expect(enabled.config?.share == true && enabled.config?.sharePath == "~/WorkShare")
        let disabled = try #require(GuestCLIInvocation.parse(["update", "work", "--share", "off"]).request)
        #expect(disabled.config?.share == false)
        #expect(try disabled.config?.sharing(replacing: nil)?.hostPath == SharedFolderMapping.defaultPath)
        let patch = try GuestConfigurationPatch.decodeStrict(Data(#"{"share":false,"sharePath":"/missing/folder"}"#.utf8))
        #expect(try patch.sharing(replacing: nil)?.enabled == false)
        #expect(try GuestConfigurationPatch().sharing(replacing: nil) == nil)
        for json in [#"{"share":null}"#, #"{"share":"on"}"#, #"{"sharePath":true}"#, #"{"sharePath":"relative"}"#, #"{"shareMount":"/etc"}"#] {
            #expect(throws: (any Error).self) {
                let config = try GuestConfigurationPatch.decodeStrict(Data(json.utf8))
                _ = try config.sharing(replacing: nil)
            }
        }
        #expect(throws: (any Error).self) { try GuestCLIInvocation.parse(["start", "work", "--share", "on"]) }
        #expect(throws: (any Error).self) { try GuestCLIInvocation.parse(["update", "work", "--share", "on", "--share", "off"]) }
    }

    @Test("schema 5 preserves opt-in; old profiles stay off; unsupported targets and modes are refused")
    func registry() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var p = f.profile(); p.ssh = SSHOptions(hostPort: 22001)
        #expect(try JSONDecoder().decode(VMProfile.self, from: JSONEncoder().encode(p)).sharedFolder == nil)
        p.sharedFolder = SharedFolderMapping(hostPath: "/missing/Shared", enabled: false)
        var store: RegistryStore? = try RegistryStore(applicationSupport: f.support)
        _ = try store!.load(); try store!.save([p]); store = nil
        let reopened = try RegistryStore(applicationSupport: f.support)
        #expect(try reopened.load() == [p])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: f.storage.directory.appendingPathComponent("registry.json"))) as! [String: Any]
        #expect(object["schemaVersion"] as? Int == 5)
        for (field, value) in [("guestPath", "/mnt/shared"), ("access", "read-only")] {
            var mapping = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p.sharedFolder)) as! [String: Any]
            mapping[field] = value
            let decoded = try JSONDecoder().decode(SharedFolderMapping.self, from: JSONSerialization.data(withJSONObject: mapping))
            #expect(throws: VMFailure.self) { try decoded.validate() }
        }
    }

    @Test("native settings enable, restart and disable preserve SSH settings and existing guest bytes")
    func settings() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let share = f.support.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let storage = ManagerStorage(applicationSupport: f.support, sharingHome: f.support)
        var p = f.profile()
        p.ssh = SSHOptions(hostPort: 22001)
        let root = try storage.prepare(p)
        let sentinel = root.appendingPathComponent("shell/preserved")
        try Data("existing guest data".utf8).write(to: sentinel)
        let sshKey = try Data(contentsOf: root.appendingPathComponent(".manager-ssh/client"))
        p.sharedFolder = SharedFolderMapping(hostPath: share.path)
        p.settingsFingerprint = try storage.settingsFingerprint(p)
        _ = try storage.prepare(p)
        func preferences() throws -> [String: Any] {
            (try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("settings.json"))) as! [String: Any])["settings"] as! [String: Any]
        }
        let before = try preferences(), forwarding = before["portForwardingPreferences"] as! [String: Any]
        #expect((before["sharedFolderPreferences"] as? [String: Any])?["path"] as? String == share.path)
        _ = try storage.prepare(p)
        p.sharedFolder?.enabled = false
        #expect(throws: VMFailure.self) { try storage.prepare(p) }
        p.settingsFingerprint = try storage.settingsFingerprint(p)
        _ = try storage.prepare(p)
        let after = try preferences()
        #expect((after["sharedFolderPreferences"] as? [String: Any])?["isEnabled"] as? Bool == false)
        #expect(NSDictionary(dictionary: after["portForwardingPreferences"] as! [String: Any]).isEqual(to: forwarding))
        #expect(try Data(contentsOf: sentinel) == Data("existing guest data".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent(".manager-ssh/client")) == sshKey)
        var unopted = p; unopted.sharedFolder = nil
        #expect(throws: VMFailure.self) { try storage.validate(unopted) }
        // Disablement must work even after the host folder has gone away.
        try FileManager.default.removeItem(at: share)
        _ = try storage.prepare(p)
    }

    @Test("unknown sharing schemas and malformed payloads are preserved", arguments: ["schema", "bool-type", "extra", "relative"])
    func damagedSettings(_ variant: String) throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var p = f.profile(); p.sharedFolder = SharedFolderMapping(hostPath: "/missing/Shared", enabled: false)
        let root = try f.storage.prepare(p), file = root.appendingPathComponent("settings.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var values = object["settings"] as! [String: Any]
        var share = p.sharedFolder!.runtimePreference
        switch variant {
        case "schema": share["schemaVersion"] = 2
        case "bool-type": share["isEnabled"] = 1
        case "extra": share["guestPath"] = "/etc"
        default: share["path"] = "relative"
        }
        values["sharedFolderPreferences"] = share; object["settings"] = values
        let damaged = try JSONSerialization.data(withJSONObject: object)
        try damaged.write(to: file)
        #expect(throws: VMFailure.self) { try f.storage.validate(p) }
        #expect(try Data(contentsOf: file) == damaged)
    }

    @Test("mount verification requires the exact VM/session, tag, target, mode and safe cache", arguments: ["valid", "hex", "missing", "wrong-session", "wrong-source", "wrong-target", "wrong-fs", "readonly", "writeback", "inaccessible", "version-omitted", "version-wrong"])
    func report(_ variant: String) throws {
        let p = VMProfile(id: UUID(), name: "Mount fixture")
        let request = VMStartRequest(profile: p, storageRoot: URL(fileURLWithPath: "/private/tmp/" + p.id.uuidString))
        let reportedOptions = variant == "writeback" ? "rw,trans=virtio,version=9p2000.L,cache=mmap" : "\(variant == "readonly" ? "ro" : "rw"),trans=virtio,version=9p2000.L,cache=\(variant == "hex" ? "0x1" : "readahead")"
        let options = variant == "version-omitted" ? "rw,relatime,cache=0x1,access=client,msize=512000,trans=virtio" : variant == "version-wrong" ? reportedOptions.replacingOccurrences(of: "version=9p2000.L", with: "version=9p2000") : reportedOptions
        let mounts: [[String: String]] = variant == "missing" ? [] : [["source": variant == "wrong-source" ? "tryomarchy-managed-ssh" : "mac", "target": variant == "wrong-target" ? "/mnt/shared" : "/mnt/mac", "fstype": variant == "wrong-fs" ? "ext4" : "9p", "options": options]]
        let object: [String: Any] = ["identity": ["vmID": p.id.uuidString, "sessionToken": variant == "wrong-session" ? UUID().uuidString : request.sessionID.uuidString, "user": "owner", "uid": 1000], "accessible": variant != "inaccessible", "mount": ["filesystems": mounts]]
        let data = try JSONSerialization.data(withJSONObject: object)
        if ["valid", "hex", "version-omitted"].contains(variant) { try SSHSharedFolderProbe.validateReport(data, request: request, user: "owner") }
        else { #expect(throws: VMFailure.self) { try SSHSharedFolderProbe.validateReport(data, request: request, user: "owner") } }
    }

    @Test("mount failures retain sessions and reservations; retry recovers and exit clears readiness")
    func lifecycle() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var p = f.profile(); p.ssh = SSHOptions(hostPort: 22003)
        p.sharedFolder = SharedFolderMapping(hostPath: "/Users/fixture/Shared")
        let runtime = FakeRuntime(), probe = ShareProbe()
        await probe.setFailure(true)
        let manager = VMManager(runtime: runtime, profiles: [p], applicationSupport: f.support,
                                portProbe: SharePort(), sharingProbe: probe)
        try await manager.start(p.id)
        let handle = try #require(runtime.startedHandles.first)
        handle.emit(.ready)
        #expect(await eventually { await manager.snapshots()[0].state == .running })
        let session = try #require(await manager.snapshots()[0].sessionID)
        await manager.receiveSSH(.ready(user: "owner", command: "fixture"), vmID: p.id, sessionID: session)
        #expect(await eventually { await manager.snapshots()[0].sharedFolderReadiness.status == "failed" })
        #expect(await manager.activeSessionCount == 1)
        #expect(await manager.allocatedMemoryMiB == 4096)
        await #expect(throws: VMFailure.self) { try await manager.update(p.id, configuration: GuestConfigurationPatch(share: false)) }
        await probe.setFailure(false)
        await manager.receiveSSH(.ready(user: "owner", command: "fixture"), vmID: p.id, sessionID: session)
        #expect(await eventually { await manager.snapshots()[0].sharedFolderReadiness == .mounted })
        await manager.shutDown(p.id)
        #expect(await manager.snapshots()[0].sharedFolderReadiness == .unverified)
        #expect(await manager.activeSessionCount == 1)
        handle.emit(.exited(status: 0))
        #expect(await eventually { await manager.snapshots()[0].sharedFolderReadiness == .stopped })
        await manager.receiveSSH(.ready(user: "owner", command: "stale"), vmID: p.id, sessionID: session)
        #expect(await manager.snapshots()[0].sharedFolderReadiness == .stopped)
    }

    @Test("a cancelled in-flight mount report cannot restore readiness during shutdown")
    func staleMountReport() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var p = f.profile(); p.ssh = SSHOptions(hostPort: 22004)
        p.sharedFolder = SharedFolderMapping(hostPath: "/Users/fixture/Shared")
        let runtime = FakeRuntime(), probe = DelayedShareProbe()
        let manager = VMManager(runtime: runtime, profiles: [p], applicationSupport: f.support,
                                portProbe: SharePort(), sharingProbe: probe)
        try await manager.start(p.id)
        let handle = try #require(runtime.startedHandles.first)
        handle.emit(.ready)
        #expect(await eventually { await manager.snapshots()[0].state == .running })
        let session = try #require(await manager.snapshots()[0].sessionID)
        await manager.receiveSSH(.ready(user: "owner", command: "fixture"), vmID: p.id, sessionID: session)
        #expect(await eventually { await probe.started() })
        await manager.shutDown(p.id)
        await probe.finish()
        #expect(await manager.snapshots()[0].sharedFolderReadiness == .unverified)
        #expect(await manager.activeSessionCount == 1)
        handle.emit(.exited(status: 0))
        #expect(await eventually { await manager.activeSessionCount == 0 })
        #expect(await manager.snapshots()[0].sharedFolderReadiness == .stopped)
    }

    @Test("pinned native export and guest mount remain separate from managed SSH")
    func runtimeContract() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = repository.appendingPathComponent(".build/runtime-source")
        let preferences = try String(contentsOf: source.appendingPathComponent("macos/Sources/OmarchyVMHelper/SharedFolder.swift"), encoding: .utf8)
        #expect(preferences.contains("static let key = \"sharedFolderPreferences\""))
        #expect(preferences.contains("static let schemaVersion = 1"))
        #expect(preferences.contains("let path: String?") && preferences.contains("let isEnabled: Bool"))
        let launcher = try String(contentsOf: source.appendingPathComponent("macos/run-qemu-gpu.sh"), encoding: .utf8)
        #expect(launcher.contains("security_model=none,multidevs=remap,guest_owner_uid=1000,guest_owner_gid=1000"))
        #expect(launcher.contains("fsdev=omarchy-share,mount_tag=mac,romfile="))
        #expect(launcher.contains("fsdev=omarchy-managed-ssh,mount_tag=tryomarchy-managed-ssh,romfile="))
        let mount = try String(contentsOf: source.appendingPathComponent("guest/package/try-omarchy/files/usr/bin/omarchy-native-mac-share"), encoding: .utf8)
        #expect(mount.contains("trans=virtio,version=9p2000.L,msize=1048576,cache=readahead"))
        #expect(mount.contains("mount_point=${OMARCHY_MAC_SHARE_MOUNT_POINT:-/mnt/mac}"))
        #expect(!SSHSharedFolderProbe.program.contains("sudo"))
        #expect(!SSHSharedFolderProbe.program.contains("mount -"))
    }
}
