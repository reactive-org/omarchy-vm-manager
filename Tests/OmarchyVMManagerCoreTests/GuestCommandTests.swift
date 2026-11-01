import Darwin
import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

private struct CLIAvailablePort: HostPortProbing { func isAvailable(_ port: Int) -> Bool { true } }
private struct CLIConnection: GuestConnectionChecking {
    var wrongSession = false
    func check(_ request: VMStartRequest, user: String) async throws -> VerifiedGuestConnection {
        VerifiedGuestConnection(vmID: request.profile.id, sessionID: wrongSession ? UUID() : request.sessionID, user: user, addresses: ["10.0.2.15"])
    }
}
private struct CommandFixture {
    let files: RegistryFixture
    let runtime: FakeRuntime
    let manager: VMManager
    let service: GuestCommandService
    init(wrongSession: Bool = false) throws {
        files = try RegistryFixture(); runtime = FakeRuntime()
        let registry = try RegistryStore(applicationSupport: files.support); _ = try registry.load()
        manager = VMManager(runtime: runtime, profiles: [], applicationSupport: files.support,
                            hostMemoryMiB: 65536, logicalCPUs: 64, registry: registry, portProbe: CLIAvailablePort())
        service = GuestCommandService(manager: manager, applicationSupport: files.support, connections: CLIConnection(wrongSession: wrongSession))
    }
    func create(_ name: String = "CLI fixture") async throws -> UUID {
        let result = await service.execute(GuestCommandRequest(command: .create, config: GuestConfigurationPatch(name: name)))
        #expect(result.ok); return try #require(result.guest?.id)
    }
}

@Suite("CLI arguments and bounded configuration")
struct GuestCLIArgumentsTests {
    @Test("create options produce a validated request; JSON config is overridden explicitly")
    func createOptions() throws {
        let request = try #require(GuestCLIInvocation.parse(["create", "work", "--memory", "8GiB", "--cpus", "8", "--disk", "128GiB", "--clipboard", "off", "--start", "--wait", "ssh", "--timeout", "1800"]).request)
        #expect(request.config?.name == "work"); #expect(request.config?.memoryMiB == 8192)
        #expect(request.config?.cpus == 8); #expect(request.config?.diskGiB == 128); #expect(request.config?.clipboard == false)
        #expect(request.start && request.waitFor == .ssh && request.timeoutSeconds == 1800)
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        let file = fixture.support.appendingPathComponent("config.json")
        try Data(#"{"memoryMiB":4096,"cpus":4,"ownerDefaults":false}"#.utf8).write(to: file)
        let configured = try #require(GuestCLIInvocation.parse(["create", "new", "--config", file.path, "--cpus", "8"]).request)
        #expect(configured.config?.memoryMiB == 4096 && configured.config?.cpus == 8 && configured.config?.ownerDefaults == false)
        for command in ["pause", "resume"] {
            let execution = try #require(GuestCLIInvocation.parse([command, "work", "--timeout", "5"]).request)
            #expect(execution.command.rawValue == command && execution.timeoutSeconds == 5)
        }
        #expect(try GuestCLIInvocation.parse(["wait", "work", "--for", "paused"]).request?.waitFor == .paused)
        let stopped = try #require(GuestCLIInvocation.parse(["stop", "work", "--wait"]).request)
        #expect(stopped.waitFor == .stopped)
    }
    @Test("invalid, unknown and creation-only inputs cannot turn into a mutation", arguments: [
        ["create", "x", "--memory", "9999999999999999999999GiB"], ["create", "x", "--cpus", "-1"],
        ["update", "x", "--ssh", "on"], ["start", "x", "--memory", "4GiB"], ["delete", "x", "--force"],
        ["create", "x", "--wait"], ["get"], ["list", "extra"], ["start", "x", "--timeout", "3601"],
        ["pause", "x", "--wait"], ["resume", "x", "--force"], ["stop", "x", "--wait", "ssh"], ["start", "x", "--wait", "stopped"], ["list", "--password", "synthetic-secret"]])
    func invalid(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try GuestCLIInvocation.parse(arguments) }
    }
    @Test("JSON files reject passwords, storage overrides, nulls and wrong types without echoing values")
    func strictConfig() throws {
        for value in [#"{"password":"synthetic-secret"}"#, #"{"storageRoot":"/outside"}"#, #"{"memoryMiB":null}"#, #"{"cpus":true}"#] {
            #expect(throws: (any Error).self) { try GuestConfigurationPatch.decodeStrict(Data(value.utf8)) }
        }
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        let file = fixture.support.appendingPathComponent("config.json"), link = fixture.support.appendingPathComponent("link.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: VMFailure.self) { try GuestCLIInvocation.parse(["create", "x", "--config", link.path]) }
    }
}

@Suite("JSON guest commands through the existing lifecycle owner")
struct GuestCommandTests {
    @Test("CLI can Trash stopped POC fixtures while their configuration stays protected", arguments: POCProfiles.all)
    func deleteRetainedPOC(profile: VMProfile) async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let root = try POCStorage(applicationSupport: f.support).prepare(profile)
        let store = try RegistryStore(applicationSupport: f.support); #expect(try store.load() == [profile])
        let runtime = FakeRuntime(), trash = PausingTrash(storage: f.storage, pauses: false)
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: f.support, registry: store, trashService: trash)
        let commands = GuestCommandService(manager: manager, applicationSupport: f.support)
        let before = await commands.execute(GuestCommandRequest(command: .get, selector: profile.id.uuidString))
        #expect(before.ok && before.guest?.protected == true)
        let edit = await commands.execute(GuestCommandRequest(command: .update, selector: profile.id.uuidString, config: GuestConfigurationPatch(name: "Changed")))
        #expect(!edit.ok && edit.error?.code == "vm-not-editable")
        let deleted = await commands.execute(GuestCommandRequest(command: .delete, selector: profile.id.uuidString))
        #expect(deleted.ok)
        #expect(!PrivateFiles.exists(root))
        #expect(PrivateFiles.exists(f.support.appendingPathComponent("simulated-trash/settings.json")))
        #expect(await manager.snapshots().isEmpty)
        #expect(store.pendingDeletions.isEmpty)
        #expect(runtime.startedHandles.isEmpty)
    }

    @Test("CRUD uses persistent profiles, merges updates and never exposes credential references")
    func crud() async throws {
        let f = try CommandFixture(); defer { f.files.cleanup() }
        let id = try await f.create()
        let configured = await f.service.execute(GuestCommandRequest(command: .update, selector: id.uuidString, config: GuestConfigurationPatch(memoryMiB: 8192, cpus: 8, diskGiB: 128, clipboard: false)))
        #expect(configured.ok && configured.guest?.memoryMiB == 8192 && configured.guest?.cpus == 8 && configured.guest?.diskGiB == 128 && configured.guest?.clipboard == false)
        let renamed = await f.service.execute(GuestCommandRequest(command: .update, selector: id.uuidString, config: GuestConfigurationPatch(name: "Renamed")))
        #expect(renamed.guest?.memoryMiB == 8192)
        let fetched = await f.service.execute(GuestCommandRequest(command: .get, selector: "Renamed"))
        #expect(fetched.ok && fetched.guest?.id == id)
        #expect(fetched.guest?.ssh.host == "127.0.0.1" && fetched.guest?.ssh.port == 2222)
        #expect(fetched.guest?.network.guestIPs == [] && fetched.guest?.network.addressesVerified == false)
        let data = String(decoding: try JSONEncoder().encode(fetched), as: UTF8.self)
        for field in ["credentialReference", "password", "privateKey", "ownerSetup"] { #expect(!data.contains(field)) }
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.root(for: await f.manager.snapshots()[0].profile).path))
        let removed = await f.service.execute(GuestCommandRequest(command: .delete, selector: id.uuidString))
        #expect(removed.ok)
        #expect(await f.manager.snapshots().isEmpty)
    }
    @Test("names must be unique and retained POC configuration protection cannot be bypassed")
    func selectorAndProtected() async throws {
        let f = try CommandFixture(); defer { f.files.cleanup() }
        _ = try await f.create("Same")
        let duplicate = await f.service.execute(GuestCommandRequest(command: .create, config: GuestConfigurationPatch(name: "same")))
        #expect(!duplicate.ok)
        #expect(await f.manager.snapshots().count == 1)
        let core = VMManager(runtime: FakeRuntime(), profiles: POCProfiles.all, applicationSupport: f.files.support)
        let service = GuestCommandService(manager: core, applicationSupport: f.files.support)
        let result = await service.execute(GuestCommandRequest(command: .update, selector: POCProfiles.all[0].id.uuidString, config: GuestConfigurationPatch(cpus: 8)))
        #expect(!result.ok && result.error?.code == "vm-not-editable")
    }
    @Test("active updates and deletion fail; error events and a disconnected wait never release the VM")
    func activeGuards() async throws {
        let f = try CommandFixture(); defer { f.files.cleanup() }
        let id = try await f.create()
        #expect((await f.service.execute(GuestCommandRequest(command: .start, selector: id.uuidString))).ok)
        let handle = try #require(f.runtime.startedHandles.first)
        handle.emit(.error(.init(code: .launchFailed, message: "Synthetic error")))
        let changed = await f.service.execute(GuestCommandRequest(command: .update, selector: id.uuidString, config: GuestConfigurationPatch(cpus: 8)))
        #expect(changed.error?.code == "vm-not-editable")
        #expect(!(await f.service.execute(GuestCommandRequest(command: .delete, selector: id.uuidString))).ok)
        #expect(await f.manager.activeSessionCount == 1)
        let stop = Task {
            var request = GuestCommandRequest(command: .stop, selector: id.uuidString); request.waitFor = .stopped
            return await f.service.execute(request)
        }
        #expect(await eventually { handle.shutdownCount == 1 })
        #expect(await f.manager.activeSessionCount == 1)
        handle.emit(.exited(status: 0))
        #expect((await stop.value).ok)
        #expect(await f.manager.activeSessionCount == 0)
    }
    @Test("pause/resume acknowledge execution, hide cached addresses and keep edits protected")
    func pauseResume() async throws {
        let f = try CommandFixture(); defer { f.files.cleanup() }
        let id = try await f.create(), selector = id.uuidString
        _ = await f.service.execute(GuestCommandRequest(command: .start, selector: selector))
        let handle = try #require(f.runtime.startedHandles.first)
        handle.emit(.ready)
        #expect(await eventually { await f.manager.snapshots()[0].state == .running })
        let session = try #require(await f.manager.snapshots()[0].sessionID)
        await f.manager.receiveSSH(.ready(user: "owner", command: "synthetic"), vmID: id, sessionID: session)
        var details = GuestCommandRequest(command: .get, selector: selector); details.details = true
        #expect((await f.service.execute(details)).guest?.network.addressesVerified == true)
        let paused = Task { await f.service.execute(GuestCommandRequest(command: .pause, selector: selector)) }
        #expect(await eventually { handle.pauseCount == 1 })
        let busy = await f.service.execute(GuestCommandRequest(command: .resume, selector: selector))
        #expect(busy.error?.code == "execution-busy")
        handle.emit(.executionState(.init(state: .paused, command: .pause)))
        let result = await paused.value
        #expect(result.ok && result.guest?.state == "paused" && result.guest?.active == true)
        #expect(result.guest?.network.guestIPs == [] && result.guest?.ssh.status == "paused")
        #expect((await f.service.execute(details)).guest?.network.addressesVerified == false)
        var wait = GuestCommandRequest(command: .wait, selector: selector); wait.waitFor = .paused
        #expect((await f.service.execute(wait)).ok)
        wait.waitFor = .ssh
        #expect((await f.service.execute(wait)).error?.code == "guest-paused")
        let update = GuestCommandRequest(command: .update, selector: selector, config: .init(cpus: 8))
        #expect((await f.service.execute(update)).error?.code == "vm-not-editable")
        let resumed = Task { await f.service.execute(GuestCommandRequest(command: .resume, selector: selector)) }
        #expect(await eventually { handle.resumeCount == 1 })
        handle.emit(.executionState(.init(state: .running, command: .resume)))
        let running = await resumed.value
        #expect(running.guest?.state == "running")
        #expect(running.guest?.network.addressesVerified == false)
        handle.emit(.exited(status: 0))
        #expect(await eventually { await f.manager.activeSessionCount == 0 })
    }
    @Test("wait timeout returns the active guest without shutting it down")
    func timeout() async throws {
        let f = try CommandFixture(); defer { f.files.cleanup() }
        let id = try await f.create()
        _ = await f.service.execute(GuestCommandRequest(command: .start, selector: id.uuidString))
        var request = GuestCommandRequest(command: .wait, selector: id.uuidString); request.waitFor = .ssh; request.timeoutSeconds = 1
        let result = await f.service.execute(request)
        #expect(result.error?.code == "wait-timeout" && result.guest?.active == true)
        #expect(await f.manager.activeSessionCount == 1)
        let handle = f.runtime.startedHandles[0]; #expect(handle.shutdownCount == 0 && handle.terminationCount == 0)
        handle.emit(.exited(status: 0))
        #expect(await eventually { await f.manager.activeSessionCount == 0 })
    }
    @Test("create/start/wait returns only current-session authenticated connection details", arguments: [false, true])
    func ready(_ wrongSession: Bool) async throws {
        let f = try CommandFixture(wrongSession: wrongSession); defer { f.files.cleanup() }
        var request = GuestCommandRequest(command: .create, config: GuestConfigurationPatch(name: "Automation")); request.start = true; request.waitFor = .ssh
        let resultTask = Task { await f.service.execute(request) }
        #expect(await eventually { await f.manager.activeSessionCount == 1 })
        let value = try #require(await f.manager.snapshots().first), session = try #require(value.sessionID)
        f.runtime.startedHandles[0].emit(.ready)
        await f.manager.receiveSSH(.ready(user: "owner", command: "ssh synthetic"), vmID: value.id, sessionID: session)
        let result = await resultTask.value
        #expect(f.runtime.startRequests.map(\.launchIntent) == [.background])
        #expect(result.ok == !wrongSession)
        if wrongSession { #expect(result.error?.code == "session-changed") }
        else {
            #expect(result.guest?.network.guestIPs == ["10.0.2.15"] && result.guest?.network.addressesVerified == true)
            #expect(result.guest?.ssh.host == "127.0.0.1" && result.guest?.ssh.user == "owner")
        }
        f.runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(await eventually { await f.manager.activeSessionCount == 0 })
        let stopped = await f.service.execute(GuestCommandRequest(command: .get, selector: value.id.uuidString))
        #expect(stopped.guest?.network.guestIPs == [])
    }
}

@Suite("Guest IP response validation")
struct GuestConnectionTests {
    @Test("only a bounded current identity and literal addresses are accepted")
    func decode() throws {
        let profile = VMProfile(id: UUID(), name: "Network fixture")
        let request = VMStartRequest(profile: profile, storageRoot: URL(fileURLWithPath: "/private/tmp/" + profile.id.uuidString))
        var value: [String: Any] = ["identity": ["vmID": profile.id.uuidString, "sessionToken": request.sessionID.uuidString, "user": "owner", "uid": 1000], "addresses": ["10.0.2.15", "fd00::15"]]
        func read() throws -> VerifiedGuestConnection { try SSHGuestConnectionProbe.decode(JSONSerialization.data(withJSONObject: value), request: request, user: "owner") }
        #expect(try read().addresses.count == 2)
        value["addresses"] = ["10.0.2.15; unsafe"]
        #expect(throws: VMFailure.self) { try read() }
        value["addresses"] = ["10.0.2.15"]
        value["identity"] = ["vmID": profile.id.uuidString, "sessionToken": UUID().uuidString, "user": "owner", "uid": 1000]
        #expect(throws: VMFailure.self) { try read() }
        #expect(throws: VMFailure.self) { try SSHGuestConnectionProbe.decode(Data(repeating: 32, count: 4097), request: request, user: "owner") }
    }
}

@Suite("CLI stopped-storage updates")
struct GuestCommandStorageTests {
    @Test("an external runtime lock prevents config changes and preserves registry bytes")
    func externalLock() async throws {
        let f = try CommandFixture(); defer { f.files.cleanup() }
        let created = await f.service.execute(GuestCommandRequest(command: .create, config: GuestConfigurationPatch(name: "Locked fixture", ssh: false)))
        let id = try #require(created.guest?.id), profile = try #require(await f.manager.snapshots().first?.profile)
        let root = try f.files.storage.prepare(profile)
        let before = try PrivateFiles.read(f.files.storage.directory.appendingPathComponent("registry.json"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-t", "0", root.appendingPathComponent("shell/lock").path, "/bin/sleep", "10"]
        try process.run(); defer { process.terminate(); process.waitUntilExit() }
        try await Task.sleep(for: .milliseconds(100))
        let result = await f.service.execute(GuestCommandRequest(command: .update, selector: id.uuidString, config: GuestConfigurationPatch(cpus: 8)))
        #expect(result.error?.code == "vm-already-open")
        #expect(try PrivateFiles.read(f.files.storage.directory.appendingPathComponent("registry.json")) == before)
    }
    @Test("restart waits for the old exit before starting a new session")
    func restart() async throws {
        let f = try CommandFixture(); defer { f.files.cleanup() }
        let id = try await f.create()
        _ = await f.service.execute(GuestCommandRequest(command: .start, selector: id.uuidString))
        let original = try #require(await f.manager.snapshots().first?.sessionID)
        let restart = Task { await f.service.execute(GuestCommandRequest(command: .restart, selector: id.uuidString)) }
        #expect(await eventually { f.runtime.startedHandles[0].shutdownCount == 1 })
        #expect(f.runtime.startedHandles.count == 1)
        f.runtime.startedHandles[0].emit(.exited(status: 0))
        let result = await restart.value
        #expect(result.ok && result.guest?.sessionID != original)
        #expect(f.runtime.startedHandles.count == 2)
        #expect(f.runtime.startRequests.map(\.launchIntent) == [.background, .background])
        f.runtime.startedHandles[1].emit(.exited(status: 0))
        #expect(await eventually { await f.manager.activeSessionCount == 0 })
    }
}
