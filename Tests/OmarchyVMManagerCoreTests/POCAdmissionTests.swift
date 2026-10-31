import Darwin
import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

private struct StorageFixture {
    let support: URL
    let storage: POCStorage
    init() throws {
        support = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("manager-poc-storage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        storage = POCStorage(applicationSupport: support)
    }
    func cleanup() { try? FileManager.default.removeItem(at: support) }
}

@Suite("Disposable POC admission")
struct POCAdmissionTests {
    @Test("new roots are private, independent and preserve their initialized metadata")
    func privateRoots() throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let a = try fixture.storage.prepare(POCProfiles.all[0])
        let b = try fixture.storage.prepare(POCProfiles.all[1])
        #expect(a != b)
        for profile in POCProfiles.all {
            let root = fixture.storage.root(for: profile)
            var info = stat()
            #expect(lstat(root.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
            let settings = root.appendingPathComponent("settings.json")
            #expect(lstat(settings.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
            let before = try Data(contentsOf: settings)
            _ = try fixture.storage.prepare(profile)
            #expect(try Data(contentsOf: settings) == before)
        }
    }

    @Test("unknown or modified profiles cannot create storage")
    func unknownProfile() throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        var changed = POCProfiles.all[0]; changed.memoryMiB = 8192
        #expect(throws: VMFailure.self) { try fixture.storage.prepare(changed) }
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.root(for: changed).path))
    }

    @Test("an unowned UUID directory is preserved and refused")
    func unownedRoot() throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        _ = try fixture.storage.prepare(POCProfiles.all[1])
        let root = fixture.storage.root(for: POCProfiles.all[0])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(throws: (any Error).self) { try fixture.storage.prepare(POCProfiles.all[0]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("symlink roots never write through to another directory")
    func symlinkRoot() throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        _ = try fixture.storage.prepare(POCProfiles.all[1])
        let outside = fixture.support.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let root = fixture.storage.root(for: POCProfiles.all[0])
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        #expect(throws: VMFailure.self) { try fixture.storage.prepare(POCProfiles.all[0]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("changed, newer, oversized and insecure settings fail closed", arguments: ["changed", "newer", "oversized", "permissions", "symlink"])
    func unsafeSettings(mode: String) throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let root = try fixture.storage.prepare(POCProfiles.all[0])
        let settings = root.appendingPathComponent("settings.json")
        if mode == "changed" || mode == "newer" {
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
            if mode == "newer" { object["schemaVersion"] = 2 }
            else {
                var values = object["settings"] as! [String: Any]
                values["networkPreferences"] = ["version": 1, "mode": "bridged"]
                object["settings"] = values
            }
            try JSONSerialization.data(withJSONObject: object).write(to: settings)
        } else if mode == "oversized" { try Data(repeating: 32, count: 65_537).write(to: settings) }
        else if mode == "permissions" { chmod(settings.path, 0o644) }
        else {
            try FileManager.default.removeItem(at: settings)
            try FileManager.default.createSymbolicLink(atPath: settings.path, withDestinationPath: "/dev/null")
        }
        #expect(throws: (any Error).self) { try fixture.storage.validate(POCProfiles.all[0]) }
    }

    @Test("aggregate host budgets are deterministic")
    func hostBudget() throws {
        try POCHostPolicy.validate(memoryMiB: 8192, cpus: 4, physicalMemoryMiB: 131072, logicalCPUs: 18)
        #expect(throws: VMFailure.self) { try POCHostPolicy.validate(memoryMiB: 12289, cpus: 4, physicalMemoryMiB: 16384, logicalCPUs: 8) }
        #expect(throws: VMFailure.self) { try POCHostPolicy.validate(memoryMiB: 8192, cpus: 17, physicalMemoryMiB: 16384, logicalCPUs: 8) }
    }

    @Test("a second cold start waits for ready and duplicate roots remain refused")
    func serializedColdStart() async throws {
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: POCProfiles.all, applicationSupport: URL(fileURLWithPath: "/private/tmp/cold-start-fixture"),
                                enforcePOCPolicy: true, hostMemoryMiB: 131072, logicalCPUs: 18)
        let a = POCProfiles.all[0].id, b = POCProfiles.all[1].id
        try await manager.start(a)
        await #expect(throws: VMFailure.self) { try await manager.start(b) }
        runtime.startedHandles[0].emit(.ready)
        #expect(await eventually { await manager.snapshots()[0].state == .running })
        try await manager.start(b)
        await #expect(throws: VMFailure.self) { try await manager.start(a) }
        #expect(runtime.startedHandles.count == 2)
        for handle in runtime.startedHandles { handle.emit(.exited(status: 0)) }
        #expect(await eventually { await manager.activeSessionCount == 0 })
    }

    @Test("approval cannot bypass kit provenance or create roots with an unproven kit")
    func badKit() throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let profile = POCProfiles.all[0]
        let runtime = TryOmarchyRuntime(approvedPOCKit: TryOmarchyKit(bundleURL: fixture.support), lockData: Data(), applicationSupport: fixture.support)
        #expect(throws: (any Error).self) {
            try runtime.start(VMStartRequest(profile: profile, storageRoot: fixture.storage.root(for: profile))) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.root(for: profile).path))
    }
}
