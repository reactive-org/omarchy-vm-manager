import Darwin
import Foundation
import Testing
@testable import OmarchyVMManagerCore

struct RegistryFixture {
    let support: URL
    var storage: ManagerStorage { ManagerStorage(applicationSupport: support) }
    init() throws {
        support = URL(fileURLWithPath: "/private/tmp/omarchy-registry-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func cleanup() { try? FileManager.default.removeItem(at: support) }
    func profile(name: String = "Development") -> VMProfile { VMProfile(id: UUID(), name: name, immersiveMode: false) }
}

private func seedRegistry(_ fixture: RegistryFixture, profiles: [VMProfile]) throws {
    let store = try RegistryStore(applicationSupport: fixture.support)
    _ = try store.load()
    try store.save(profiles)
}

@Suite("Persistent registry and guarded storage")
struct RegistryStorageTests {
    @Test("reopening restores metadata only; writes are private and duplicate managers fail")
    func persistence() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var store: RegistryStore? = try RegistryStore(applicationSupport: f.support)
        #expect(try store!.load().isEmpty)
        let profile = f.profile()
        try store!.save([profile])
        #expect(throws: VMFailure.self) { _ = try RegistryStore(applicationSupport: f.support) }
        #expect(!FileManager.default.fileExists(atPath: f.storage.root(for: profile).path))
        var s = stat(); #expect(lstat(f.storage.directory.appendingPathComponent("registry.json").path, &s) == 0)
        #expect(s.st_mode & 0o777 == 0o600)
        store = nil
        let reopened = try reopenRegistry(f)
        #expect(try reopened.load() == [profile])
    }

    @Test("malformed, newer, oversized, symlinked and insecure registries are preserved", arguments: ["malformed", "newer", "oversized", "symlink", "mode", "duplicate"])
    func corrupt(mode: String) throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        try seedRegistry(f, profiles: [f.profile()])
        let file = f.storage.directory.appendingPathComponent("registry.json")
        if mode == "mode" { chmod(file.path, 0o644) }
        else if mode == "symlink" {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "/dev/null")
        } else {
            let data: Data
            switch mode {
            case "malformed": data = Data("broken".utf8)
            case "newer": data = Data("{\"schemaVersion\":2,\"profiles\":[]}".utf8)
            case "oversized": data = Data(repeating: 32, count: 1_048_577)
            default:
                var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                object["profiles"] = [object["profiles"] as! [Any]].flatMap { $0 } + (object["profiles"] as! [Any])
                data = try JSONSerialization.data(withJSONObject: object)
            }
            try data.write(to: file)
        }
        let before = mode == "symlink" ? nil : try Data(contentsOf: file)
        let reopened = try reopenRegistry(f)
        #expect(throws: (any Error).self) { _ = try reopened.load() }
        if let before { #expect(try Data(contentsOf: file) == before) }
        else { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == "/dev/null") }
    }

    @Test("an external registry edit is not overwritten")
    func externalChange() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let store = try RegistryStore(applicationSupport: f.support); _ = try store.load()
        let file = f.storage.directory.appendingPathComponent("registry.json")
        let changed = Data("{\"schemaVersion\":99,\"profiles\":[]}".utf8)
        try changed.write(to: file)
        #expect(throws: VMFailure.self) { try store.save([f.profile()]) }
        #expect(try Data(contentsOf: file) == changed)
    }

    @Test("new root initialization prevents legacy inheritance and preserves guest files")
    func initialize() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let profile = f.profile(); let root = try f.storage.prepare(profile)
        let marker = root.appendingPathComponent("shell/test-guest-file")
        try Data("synthetic guest data".utf8).write(to: marker)
        _ = try f.storage.prepare(profile)
        #expect(try Data(contentsOf: marker) == Data("synthetic guest data".utf8))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("settings.json"))) as! [String: Any]
        let values = object["settings"] as! [String: Any]
        #expect(Set(values.keys) == POCStorage.inheritedKeys)
        #expect(values["networkPreferences"] is NSNull)
        #expect((values["fullscreenPreferences"] as? [String: Any])?["isImmersive"] as? Bool == false)
    }

    @Test("outside display-setting edits are preserved until an explicit configuration save")
    func displayRevision() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var profile = f.profile(); let root = try f.storage.prepare(profile)
        let file = root.appendingPathComponent("settings.json")
        let original = try Data(contentsOf: file)
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        var values = object["settings"] as! [String: Any]
        values["fullscreenPreferences"] = ["schemaVersion": 1, "isImmersive": true, "usesNotch": true]
        object["settings"] = values
        let changed = try JSONSerialization.data(withJSONObject: object)
        try changed.write(to: file)
        #expect(throws: VMFailure.self) { _ = try f.storage.prepare(profile) }
        #expect(try Data(contentsOf: file) == changed)
        profile.settingsFingerprint = try f.storage.settingsFingerprint(profile)
        _ = try f.storage.prepare(profile)
        let applied = try Data(contentsOf: file)
        #expect(applied != changed)
        _ = try f.storage.prepare(profile)
        #expect(try Data(contentsOf: file) == applied)
    }

    @Test("retained POC adoption changes no files and rejects deletion")
    func retainedPOC() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let poc = POCProfiles.all[0]
        let root = try POCStorage(applicationSupport: f.support).prepare(poc)
        let before = try Data(contentsOf: root.appendingPathComponent("settings.json"))
        let store = try RegistryStore(applicationSupport: f.support)
        #expect(try store.load().map(\.id) == [poc.id])
        _ = try f.storage.prepare(poc)
        #expect(try Data(contentsOf: root.appendingPathComponent("settings.json")) == before)
        let identity = try f.storage.deletionIdentity(poc)
        #expect(throws: VMFailure.self) { try f.storage.trash(poc, expectedIdentity: identity) { _ in Issue.record("POC must never reach Trash") } }
    }

    @Test("links, settings changes and ownership-marker mismatch fail closed", arguments: ["root-link", "disk-link", "settings", "marker", "tree-link", "identity"])
    func unsafeStorage(mode: String) throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let profile = f.profile(); let root = try f.storage.prepare(profile)
        let identity = try f.storage.deletionIdentity(profile)
        switch mode {
        case "root-link":
            try FileManager.default.moveItem(at: root, to: f.support.appendingPathComponent("outside"))
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: f.support.appendingPathComponent("outside"))
        case "disk-link": try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("shell/disk.img").path, withDestinationPath: "/dev/null")
        case "settings": try Data("{\"schemaVersion\":2,\"settings\":{}}".utf8).write(to: root.appendingPathComponent("settings.json"))
        case "marker": try Data("{}".utf8).write(to: root.appendingPathComponent(".omarchy-vm-manager.json"))
        case "tree-link": try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("guest-link").path, withDestinationPath: "/private/tmp")
        default: break
        }
        #expect(throws: (any Error).self) {
            try f.storage.trash(profile, expectedIdentity: mode == "identity" ? "wrong" : identity) { _ in Issue.record("Unsafe storage reached Trash") }
        }
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Trash failure keeps the root, and success moves the entire verified root")
    func trashResult() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let profile = f.profile(); let root = try f.storage.prepare(profile)
        let identity = try f.storage.deletionIdentity(profile)
        #expect(throws: CocoaError.self) {
            try f.storage.trash(profile, expectedIdentity: identity) { _ in throw CocoaError(.fileWriteNoPermission) }
        }
        #expect(FileManager.default.fileExists(atPath: root.path))
        let simulatedTrash = f.support.appendingPathComponent("simulated-trash")
        try f.storage.trash(profile, expectedIdentity: identity) { source in
            let contender = Process(); contender.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            contender.arguments = ["-s", "-t", "0", source.appendingPathComponent("shell/lock").path, "/usr/bin/true"]
            contender.standardOutput = FileHandle.nullDevice; contender.standardError = FileHandle.nullDevice
            try contender.run(); contender.waitUntilExit()
            #expect(contender.terminationStatus != 0)
            try FileManager.default.moveItem(at: source, to: simulatedTrash)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: simulatedTrash.appendingPathComponent("settings.json").path))
    }

    @Test("storage-helper results are bounded, successful and bound to the requested UUID", arguments: ["valid", "wrong-id", "nonzero", "oversized"])
    func helperResults(mode: String) async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let profile = f.profile()
        let helper = f.support.appendingPathComponent("fake-storage-helper")
        let identifier = mode == "wrong-id" ? UUID().uuidString : profile.id.uuidString
        var script = "#!/bin/sh\nprintf '%s' '{\"ok\":true,\"id\":\"" + identifier + "\"}'\n"
        if mode == "nonzero" { script += "exit 1\n" }
        if mode == "oversized" { script = "#!/bin/sh\nexec /usr/bin/python3 -c 'import os,time; os.write(1,b\"x\"*9000); time.sleep(20)'\n" }
        try Data(script.utf8).write(to: helper); chmod(helper.path, 0o700)
        let service = HelperTrashService(executable: helper)
        let request = TrashRequest(profile: profile, expectedIdentity: "synthetic-identity")
        if mode == "valid" { try await service.moveToTrash(request) }
        else { await #expect(throws: VMFailure.self) { try await service.moveToTrash(request) } }
    }

    @Test("runtime-compatible lock held by another process prevents Trash")
    func busyLock() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let profile = f.profile(); let root = try f.storage.prepare(profile)
        let identity = try f.storage.deletionIdentity(profile)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-t", "0", root.appendingPathComponent("shell/lock").path, "/bin/sleep", "10"]
        try process.run(); defer { process.terminate(); process.waitUntilExit() }
        usleep(100_000)
        #expect(process.isRunning)
        #expect(throws: VMFailure.self) { try f.storage.trash(profile, expectedIdentity: identity) { _ in Issue.record("Busy storage reached Trash") } }
    }
}

actor PausingTrash: VMTrashService {
    let storage: ManagerStorage
    var continuation: CheckedContinuation<Void, any Error>?
    var entered = false
    init(storage: ManagerStorage) { self.storage = storage }
    func moveToTrash(_ request: TrashRequest) async throws {
        entered = true
        try await withCheckedThrowingContinuation { continuation = $0 }
        try storage.trash(request.profile, expectedIdentity: request.expectedIdentity) {
            try FileManager.default.moveItem(at: $0, to: storage.applicationSupport.appendingPathComponent("simulated-trash"))
        }
    }
    func finish(fail: Bool = false) {
        if fail { continuation?.resume(throwing: CocoaError(.fileWriteUnknown)) }
        else { continuation?.resume() }
        continuation = nil
    }
}

@Suite("Registry lifecycle transactions")
struct RegistryLifecycleTests {
    @Test("registry edits after opening prevent launch before a runtime or storage is touched")
    func editedRegistryBeforeLaunch() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let store = try RegistryStore(applicationSupport: f.support); _ = try store.load()
        let profile = f.profile(); try store.save([profile])
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: f.support, hostMemoryMiB: 32768, logicalCPUs: 8, registry: store)
        let changed = Data("{\"schemaVersion\":99,\"profiles\":[]}".utf8)
        let file = f.storage.directory.appendingPathComponent("registry.json")
        try changed.write(to: file)
        await #expect(throws: VMFailure.self) { try await manager.start(profile.id) }
        #expect(runtime.startedHandles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.storage.root(for: profile).path))
        #expect(try Data(contentsOf: file) == changed)
    }

    @Test("create configure rename and relaunch preserve metadata without inventing sessions")
    func editing() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let store = try RegistryStore(applicationSupport: f.support)
        let manager = VMManager(runtime: FakeRuntime(), profiles: try store.load(), applicationSupport: f.support, hostMemoryMiB: 32768, logicalCPUs: 8, registry: store)
        let id = try await manager.create(name: "Work", memoryMiB: 4096, cpus: 4, clipboardEnabled: true, immersiveMode: false)
        var profile = try #require(await manager.snapshots().first?.profile)
        profile.name = "Work renamed"; profile.memoryMiB = 8192
        try await manager.configure(profile)
        #expect(await manager.snapshots()[0].profile == profile)
        #expect(await manager.snapshots()[0].state == .stopped)
        await #expect(throws: VMFailure.self) { _ = try await manager.create(name: profile.name, memoryMiB: 4096, cpus: 4, clipboardEnabled: true, immersiveMode: false) }
        #expect(await manager.snapshots().map(\.id) == [id])
        let data = try PrivateFiles.read(f.storage.directory.appendingPathComponent("registry.json"), maximum: 1_048_576)
        #expect(String(decoding: data, as: UTF8.self).contains("Work renamed"))
        #expect(!String(decoding: data, as: UTF8.self).contains("sessionID"))
    }

    @Test("delete blocks concurrent start/configuration until helper result and preserves failures", arguments: [false, true])
    func deleting(failure: Bool) async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let store = try RegistryStore(applicationSupport: f.support); _ = try store.load()
        let profile = f.profile(); try store.save([profile]); _ = try f.storage.prepare(profile)
        let service = PausingTrash(storage: f.storage)
        let manager = VMManager(runtime: FakeRuntime(), profiles: [profile], applicationSupport: f.support, hostMemoryMiB: 32768, logicalCPUs: 8, registry: store, trashService: service)
        let review = try #require(await manager.deletionRequest(profile.id))
        let task = Task { try await manager.delete(profile.id, confirmed: true, expectedIdentity: review.expectedIdentity) }
        #expect(await eventually { await service.entered })
        await #expect(throws: VMFailure.self) { try await manager.start(profile.id) }
        await #expect(throws: VMFailure.self) { try await manager.configure(profile) }
        #expect(await manager.snapshots()[0].state == .deleting)
        #expect(!(await manager.isIdle))
        await service.finish(fail: failure)
        if failure {
            do { try await task.value; Issue.record("Expected failure") } catch {}
            #expect(await manager.snapshots().count == 1)
            #expect(FileManager.default.fileExists(atPath: f.storage.root(for: profile).path))
        } else {
            try await task.value; #expect(await manager.snapshots().isEmpty)
        }
        #expect(await manager.isIdle)
    }

    @Test("an interrupted Trash operation survives relaunch and cannot recreate the missing disk")
    func interruptedDeletion() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let profile = f.profile()
        try seedInterruptedDeletion(f, profile: profile)
        let store = try reopenRegistry(f)
        let manager = VMManager(runtime: FakeRuntime(), profiles: try store.load(), applicationSupport: f.support, hostMemoryMiB: 32768, logicalCPUs: 8, registry: store)
        #expect(await manager.snapshots()[0].lastFailure?.code == "interrupted-deletion")
        await #expect(throws: VMFailure.self) { try await manager.start(profile.id) }
        #expect(!FileManager.default.fileExists(atPath: f.storage.root(for: profile).path))
        try await manager.delete(profile.id, confirmed: true, expectedIdentity: nil)
        #expect(await manager.snapshots().isEmpty)
        #expect(store.pendingDeletions.isEmpty)
    }

    @Test("active and protected VMs cannot be edited or deleted; quitting refuses new work")
    func protections() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let store = try RegistryStore(applicationSupport: f.support); _ = try store.load()
        let profile = f.profile(); let poc = POCProfiles.all[0]; try store.save([profile,poc])
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [profile,poc], applicationSupport: f.support, hostMemoryMiB: 32768, logicalCPUs: 8, registry: store)
        await #expect(throws: VMFailure.self) { try await manager.configure(poc) }
        await #expect(throws: VMFailure.self) { try await manager.delete(poc.id, confirmed: true, expectedIdentity: nil) }
        try await manager.start(profile.id)
        await #expect(throws: VMFailure.self) { try await manager.configure(profile) }
        await #expect(throws: VMFailure.self) { try await manager.delete(profile.id, confirmed: true, expectedIdentity: nil) }
        #expect(!(await manager.beginApplicationShutdown()))
        await #expect(throws: VMFailure.self) { _ = try await manager.create(name: "Late", memoryMiB: 4096, cpus: 4, clipboardEnabled: true, immersiveMode: false) }
        runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(await eventually { await manager.isIdle })
    }
}

private func seedInterruptedDeletion(_ fixture: RegistryFixture, profile: VMProfile) throws {
    let store = try RegistryStore(applicationSupport: fixture.support)
    _ = try store.load(); try store.save([profile])
    let root = try fixture.storage.prepare(profile)
    try store.markDeletion(profile.id)
    try FileManager.default.moveItem(at: root, to: fixture.support.appendingPathComponent("simulated-trash"))
}

private func reopenRegistry(_ fixture: RegistryFixture) throws -> RegistryStore {
    // Parallel process tests briefly inherit BSD lock descriptors before exec closes them.
    for _ in 0..<100 {
        do { return try RegistryStore(applicationSupport: fixture.support) }
        catch let error as VMFailure where error.code == "manager-already-open" { usleep(10_000) }
    }
    return try RegistryStore(applicationSupport: fixture.support)
}
