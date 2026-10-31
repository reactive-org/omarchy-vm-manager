import Darwin
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private struct AvailablePorts: HostPortProbing { func isAvailable(_ port: Int) -> Bool { port != 2222 } }
private actor ControlledSSHProbe: SSHReadinessChecking {
    private var callbacks: [UUID: @Sendable (SSHReadiness) async -> Void] = [:]
    func monitor(_ request: VMStartRequest, update: @escaping @Sendable (SSHReadiness) async -> Void) async {
        callbacks[request.sessionID] = update
        await update(.waitingForOwner)
        while !Task.isCancelled { do { try await Task.sleep(for: .milliseconds(50)) } catch { return } }
    }
    func send(_ value: SSHReadiness, session: UUID) async { await callbacks[session]?(value) }
}

@Suite("Managed host SSH")
struct ManagedSSHTests {
    @Test("new profiles enable SSH on distinct persistent ports; legacy profiles stay off")
    func defaultsAndPorts() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let store = try RegistryStore(applicationSupport: f.support)
        let legacy = f.profile(name: "Legacy"); _ = try store.load(); try store.save([legacy])
        let manager = VMManager(runtime: FakeRuntime(), profiles: [legacy], applicationSupport: f.support, hostMemoryMiB: 32768, logicalCPUs: 8, registry: store, portProbe: AvailablePorts())
        let a = try await manager.create(name: "A", memoryMiB: 4096, cpus: 4, clipboardEnabled: true, immersiveMode: false)
        let b = try await manager.create(name: "B", memoryMiB: 4096, cpus: 4, clipboardEnabled: true, immersiveMode: false)
        let rows = await manager.snapshots()
        #expect(rows[0].profile.ssh == nil)
        #expect(rows.first(where: { $0.id == a })?.profile.ssh?.hostPort == 2223)
        #expect(rows.first(where: { $0.id == b })?.profile.ssh?.hostPort == 2224)
        #expect(rows[1].sshReadiness == .stopped)
        let data = try PrivateFiles.read(f.storage.directory.appendingPathComponent("registry.json"), maximum: 1_048_576)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE KEY"))
        #expect(!FileManager.default.fileExists(atPath: f.storage.root(for: rows[1].profile).path))
    }

    @Test("SSH can be disabled during creation without a port or credential")
    func optedOut() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let store = try RegistryStore(applicationSupport: f.support); _ = try store.load()
        let manager = VMManager(runtime: FakeRuntime(), profiles: [], applicationSupport: f.support, hostMemoryMiB: 32768, logicalCPUs: 8, registry: store, portProbe: AvailablePorts())
        _ = try await manager.create(name: "Offline", memoryMiB: 4096, cpus: 4, clipboardEnabled: true, immersiveMode: false, sshEnabled: false)
        #expect(await manager.snapshots()[0].profile.ssh == nil)
        #expect(await manager.snapshots()[0].sshReadiness == .disabled)
    }

    @Test("per-VM keys are distinct, private and never share the client private key with the guest")
    func isolatedCredentials() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var a = f.profile(name: "A"), b = f.profile(name: "B")
        a.ssh = SSHOptions(hostPort: 2223); b.ssh = SSHOptions(hostPort: 2224)
        let ar = try f.storage.prepare(a), br = try f.storage.prepare(b)
        let sa = ManagedSSHStorage(root: ar), sb = ManagedSSHStorage(root: br)
        #expect(try PrivateFiles.read(sa.clientKey) != PrivateFiles.read(sb.clientKey))
        #expect(try PrivateFiles.read(sa.bootstrap.appendingPathComponent("host_ed25519")) != PrivateFiles.read(sb.bootstrap.appendingPathComponent("host_ed25519")))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: sa.bootstrap.path)) == ["manifest.json", "host_ed25519", "host_ed25519.pub"])
        for path in [sa.clientKey, sa.knownHosts, sa.bootstrap.appendingPathComponent("host_ed25519")] {
            var info = stat(); #expect(lstat(path.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        }
        let settings = try JSONSerialization.jsonObject(with: PrivateFiles.read(ar.appendingPathComponent("settings.json"))) as! [String: Any]
        let forwarding = (settings["settings"] as! [String: Any])["portForwardingPreferences"] as! [String: Any]
        let mapping = (forwarding["mappings"] as! [[String: Any]])[0]
        #expect(mapping["hostPort"] as? Int == 2223 && mapping["guestPort"] as? Int == 22 && mapping["protocol"] as? String == "tcp")
    }

    @Test("restart retains keys and endpoint but replaces the session nonce")
    func restart() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var profile = f.profile(); profile.ssh = SSHOptions(hostPort: 2223)
        let first = UUID(), second = UUID()
        let root = try f.storage.prepare(profile, sessionID: first); let storage = ManagedSSHStorage(root: root)
        let key = try PrivateFiles.read(storage.clientKey), pin = try PrivateFiles.read(storage.knownHosts)
        _ = try f.storage.prepare(profile, sessionID: second)
        #expect(try PrivateFiles.read(storage.clientKey) == key)
        #expect(try PrivateFiles.read(storage.knownHosts) == pin)
        let manifest = try JSONDecoder().decode(ManagedSSHStorage.Manifest.self, from: PrivateFiles.read(root.appendingPathComponent(ManagedSSHStorage.manifestName)))
        #expect(manifest.sessionToken == second && manifest.hostPort == 2223)
    }

    @Test("missing credentials and changed host pins fail without regeneration", arguments: ["missing", "pin"])
    func damagedCredentials(mode: String) throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var profile = f.profile(); profile.ssh = SSHOptions(hostPort: 2223)
        let root = try f.storage.prepare(profile); let storage = ManagedSSHStorage(root: root)
        let privateHost = try PrivateFiles.read(storage.bootstrap.appendingPathComponent("host_ed25519"))
        if mode == "missing" { unlink(storage.clientKey.path) }
        else { try Data("wrong-host-key\n".utf8).write(to: storage.knownHosts) }
        #expect(throws: (any Error).self) { _ = try f.storage.prepare(profile) }
        #expect(try PrivateFiles.read(storage.bootstrap.appendingPathComponent("host_ed25519")) == privateHost)
        if mode == "missing" { #expect(!FileManager.default.fileExists(atPath: storage.clientKey.path)) }
        else { #expect(try PrivateFiles.read(storage.knownHosts) == Data("wrong-host-key\n".utf8)) }
    }

    @Test("selected public keys are canonical and private key material is rejected")
    func publicKeyEnrollment() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var source = f.profile(name: "Source"); source.ssh = SSHOptions(hostPort: 2223)
        let sourceRoot = try f.storage.prepare(source)
        let publicKey = String(decoding: try PrivateFiles.read(ManagedSSHStorage(root: sourceRoot).directory.appendingPathComponent("client.pub")), as: UTF8.self)
        let fingerprint = try SSHPublicKey.fingerprint(publicKey)
        #expect(fingerprint.hasPrefix("SHA256:"))
        var target = f.profile(name: "Target")
        let stored = try SelectedPublicKeyStore(applicationSupport: f.support).save(publicKey, id: target.id)
        target.ssh = SSHOptions(hostPort: 2224, publicKeyFingerprint: stored)
        let root = try f.storage.prepare(target)
        let owner = String(decoding: try PrivateFiles.read(ManagedSSHStorage(root: root).directory.appendingPathComponent("owner.pub")), as: UTF8.self)
        #expect(try SSHPublicKey.fingerprint(owner) == fingerprint)
        #expect(!owner.contains("Omarchy VM Manager"))
        #expect(throws: VMFailure.self) { _ = try SSHPublicKey.canonical("-----BEGIN OPENSSH PRIVATE KEY-----") }
        #expect(throws: VMFailure.self) { _ = try SSHPublicKey.canonical("command=malicious " + publicKey) }
        let malformed = Data([0,0,0,11]) + Data("ssh-ed25519".utf8) + Data([0,0,0,0])
        #expect(throws: VMFailure.self) { _ = try SSHPublicKey.canonical("ssh-ed25519 " + malformed.base64EncodedString()) }
    }

    @Test("SSH failures and stale results never release or replace a live VM session")
    func sessionIsolation() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var a = f.profile(name: "A"), b = f.profile(name: "B")
        a.ssh = SSHOptions(hostPort: 2223); b.ssh = SSHOptions(hostPort: 2223)
        let runtime = FakeRuntime(), probe = ControlledSSHProbe()
        let manager = VMManager(runtime: runtime, profiles: [a,b], applicationSupport: f.support, sshProbe: probe, portProbe: AvailablePorts())
        try await manager.start(a.id)
        let first = try #require(await manager.snapshots()[0].sessionID)
        #expect(await eventually { await manager.snapshots()[0].sshReadiness == .waitingForOwner })
        await probe.send(.failed("synthetic SSH failure"), session: first)
        #expect(await manager.activeSessionCount == 1)
        #expect(await manager.allocatedMemoryMiB == 4096)
        await #expect(throws: VMFailure.self) { try await manager.start(b.id) }
        runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(await eventually { await manager.activeSessionCount == 0 })
        try await manager.start(a.id)
        let second = try #require(await manager.snapshots()[0].sessionID)
        await manager.receiveSSH(.ready(user: "wrong", command: "wrong"), vmID: a.id, sessionID: first)
        #expect(await manager.snapshots()[0].sessionID == second)
        #expect(await manager.snapshots()[0].sshReadiness != .ready(user: "wrong", command: "wrong"))
        runtime.startedHandles[1].emit(.exited(status: 0))
        #expect(await eventually { await manager.isIdle })
    }

    @Test("session-bound guest reports reject old sessions and root accounts")
    func reportValidation() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let profile = f.profile(); let root = try f.storage.prepare(profile)
        try PrivateFiles.directory(root.appendingPathComponent("shell"), create: true)
        let request = VMStartRequest(profile: profile, storageRoot: root)
        let file = root.appendingPathComponent("shell/guest-status.json")
        func write(token: UUID, user: String) throws {
            let value: [String: Any] = ["receivedAt": ISO8601DateFormatter().string(from: Date()), "report": ["managedSSH": ["schemaVersion": 1, "vmID": profile.id.uuidString, "sessionToken": token.uuidString, "state": "configured", "owner": user]]]
            try PrivateFiles.write(JSONSerialization.data(withJSONObject: value), name: file.lastPathComponent, in: file.deletingLastPathComponent())
        }
        try write(token: UUID(), user: "owner"); #expect(try ManagedSSHProbe().currentReport(request) == nil)
        try write(token: request.sessionID, user: "root"); #expect(try ManagedSSHProbe().currentReport(request) == nil)
        try write(token: request.sessionID, user: "owner"); #expect(try ManagedSSHProbe().currentReport(request)?.owner == "owner")
    }

    @Test("generated OpenSSH configuration parses paths with spaces and enforces host checking")
    func clientConfiguration() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var profile = f.profile(); profile.ssh = SSHOptions(hostPort: 2223)
        let root = try f.storage.prepare(profile); let storage = ManagedSSHStorage(root: root)
        let command = try storage.command(profile: profile, user: "owner")
        #expect(command.contains("/usr/bin/ssh -F '"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", storage.clientConfig.path, storage.alias(profile.id)]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let config = String(decoding: data, as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(config.contains("stricthostkeychecking true"))
        #expect(config.contains("identityagent none"))
        #expect(config.contains("port 2223"))
        #expect(config.contains(storage.clientKey.path))
    }
}

private actor LiveSSHResult {
    var value: SSHReadiness?
    func receive(_ value: SSHReadiness) { self.value = value }
}

@Suite("Real managed SSH probe", .enabled(if: ProcessInfo.processInfo.environment["OMARCHY_SSH_FIXTURE_MANIFEST"] != nil))
struct LiveManagedSSHTests {
    struct Fixture: Decodable { let id: UUID; let sessionID: UUID; let root: String; let port: Int }
    @Test("production probe authenticates and pins each isolated server")
    func verifiesServers() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["OMARCHY_SSH_FIXTURE_MANIFEST"])
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(fixtures.count == 2)
        for fixture in fixtures {
            var profile = VMProfile(id: fixture.id, name: "Synthetic SSH fixture", memoryMiB: 4096, cpus: 2, clipboardEnabled: false)
            profile.ssh = SSHOptions(hostPort: fixture.port)
            let request = VMStartRequest(profile: profile, storageRoot: URL(fileURLWithPath: fixture.root), sessionID: fixture.sessionID, startedAt: Date().addingTimeInterval(-120))
            let result = LiveSSHResult()
            let task = Task { await ManagedSSHProbe().monitor(request) { await result.receive($0) } }
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if case .ready = await result.value { break }
                if case .failed = await result.value { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            task.cancel(); await task.value
            guard case .ready(let user, let command) = await result.value else { Issue.record("Production SSH probe did not authenticate the synthetic server"); return }
            #expect(user == "owner")
            #expect(command.contains(fixture.id.uuidString.lowercased()))
        }
    }
}

@Suite("SSH port and stored mapping safeguards")
struct SSHPortSafetyTests {
    @Test("a listening localhost port cannot be admitted")
    func boundPort() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        #expect(fd >= 0); defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(bound == 0); #expect(listen(fd, 1) == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        #expect(status == 0)
        #expect(!LoopbackPortProbe().isAvailable(Int(UInt16(bigEndian: address.sin_port))))
    }
    @Test("external SSH remapping is refused without rewriting settings")
    func editedMapping() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var profile = f.profile(); profile.ssh = SSHOptions(hostPort: 2223)
        let root = try f.storage.prepare(profile)
        let file = root.appendingPathComponent("settings.json")
        var settings = try JSONSerialization.jsonObject(with: PrivateFiles.read(file)) as! [String: Any]
        var values = settings["settings"] as! [String: Any]
        values["portForwardingPreferences"] = ["schemaVersion": 1, "mappings": [["hostPort": 2224, "guestPort": 22, "protocol": "tcp"]]]
        settings["settings"] = values
        let changed = try JSONSerialization.data(withJSONObject: settings)
        try PrivateFiles.write(changed, name: file.lastPathComponent, in: root)
        #expect(throws: (any Error).self) { _ = try f.storage.prepare(profile) }
        #expect(try PrivateFiles.read(file) == changed)
    }
}

@Suite("Fresh owned root URL admission")
struct FreshRootAdmissionTests {
    @Test("directory and file URL forms name the same new UUID root without widening its namespace")
    func directoryURL() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let profile = f.profile()
        let directoryURL = POCProfiles.root(for: profile, applicationSupport: f.support).resolvingSymlinksInPath()
        #expect(!FileManager.default.fileExists(atPath: directoryURL.path))
        #expect(f.storage.matchesRoot(directoryURL, profile: profile))
        #expect(f.storage.matchesRoot(URL(fileURLWithPath: directoryURL.path), profile: profile))
        #expect(!f.storage.matchesRoot(directoryURL.appendingPathComponent("other"), profile: profile))
        #expect(!f.storage.matchesRoot(URL(string: "https://example.com" + directoryURL.path)!, profile: profile))
        _ = try f.storage.prepare(profile)
        #expect(f.storage.matchesRoot(directoryURL.resolvingSymlinksInPath(), profile: profile))
    }
}
