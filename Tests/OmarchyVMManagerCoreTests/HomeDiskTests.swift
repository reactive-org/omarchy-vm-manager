import Darwin
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private struct HomePort: HostPortProbing { func isAvailable(_ port: Int) -> Bool { true } }

@Suite("Optional home disks — no VM")
struct HomeDiskTests {
    @Test("replaced or unexpectedly truncated home files are refused without repair", arguments: ["replaced", "truncated"])
    func damagedDisk(_ variant: String) throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var p = f.profile(); p.homeDisk = HomeDisk(sizeGiB: 32)
        _ = try f.storage.prepare(p)
        let path = f.storage.homeImage(p)
        if variant == "replaced" {
            try FileManager.default.moveItem(at: path, to: path.appendingPathExtension("preserved"))
            let fd = open(path.path, O_RDWR | O_CREAT | O_EXCL, 0o600); defer { close(fd) }
            #expect(ftruncate(fd, 32 * 1_073_741_824) == 0)
        } else {
            let fd = open(path.path, O_RDWR); defer { close(fd) }
            #expect(ftruncate(fd, 16 * 1_073_741_824) == 0)
        }
        #expect(throws: (any Error).self) { try f.storage.prepare(p) }
        var info = stat(); #expect(lstat(path.path, &info) == 0)
        #expect(info.st_size == (variant == "truncated" ? 16 : 32) * 1_073_741_824)
    }
    @Test("legacy profiles remain single-disk and new defaults are independently persisted")
    func defaults() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let legacy = f.profile()
        #expect(try JSONDecoder().decode(VMProfile.self, from: JSONEncoder().encode(legacy)).homeDisk == nil)
        let store = DiskDefaultsStore(applicationSupport: f.support)
        #expect(try store.load() == DiskDefaults())
        try store.save(DiskDefaults(systemDiskGiB: 128, separateHome: false, homeDiskGiB: 256))
        #expect(try store.load() == DiskDefaults(systemDiskGiB: 128, separateHome: false, homeDiskGiB: 256))
        #expect(throws: VMFailure.self) { try store.save(DiskDefaults(systemDiskGiB: 16)) }
    }

    @Test("new creation inherits disk defaults, accepts single-disk opt-out and persists schema 6")
    func creation() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let registry = try RegistryStore(applicationSupport: f.support); _ = try registry.load()
        let manager = VMManager(runtime: FakeRuntime(), profiles: [], applicationSupport: f.support, hostMemoryMiB: 32768, logicalCPUs: 8, registry: registry, portProbe: HomePort())
        func create(_ name: String, separate: Bool? = nil) async throws -> UUID {
            try await manager.create(name: name, memoryMiB: 4096, cpus: 4, clipboardEnabled: true, immersiveMode: false,
                                     sshEnabled: false, separateHome: separate)
        }
        let split = try await create("Split")
        #expect(await manager.snapshots().first(where: { $0.id == split })?.profile.homeDisk?.sizeGiB == 64)
        let single = try await create("Single", separate: false)
        #expect(await manager.snapshots().first(where: { $0.id == single })?.profile.homeDisk == nil)
        try await manager.saveDiskDefaults(DiskDefaults(systemDiskGiB: 128, separateHome: false, homeDiskGiB: 256))
        let inherited = try await create("Inherited")
        let p = try #require(await manager.snapshots().first(where: { $0.id == inherited })?.profile)
        #expect(p.diskGiB == 128 && p.homeDisk == nil)
        #expect(!FileManager.default.fileExists(atPath: f.storage.vms.path))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: f.storage.directory.appendingPathComponent("registry.json"))) as! [String: Any]
        #expect(object["schemaVersion"] as? Int == 6)
        await #expect(throws: VMFailure.self) {
            try await manager.create(name: "Invalid", memoryMiB: 4096, cpus: 4, clipboardEnabled: true, immersiveMode: false,
                                     sshEnabled: false, separateHome: false, homeDiskGiB: 64)
        }
    }

    @Test("blank home creation is sparse, identity-bound, grow-only and never recreated when missing")
    func storage() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var p = f.profile(); p.homeDisk = HomeDisk(sizeGiB: 16)
        _ = try f.storage.prepare(p)
        let image = f.storage.homeImage(p)
        var info = stat(); #expect(lstat(image.path, &info) == 0)
        #expect(info.st_size == 16 * 1_073_741_824 && info.st_blocks * 512 < 1_048_576)
        let fd = open(image.path, O_RDONLY); defer { close(fd) }
        let header = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 80)
        #expect(String(decoding: header ?? Data(), as: UTF8.self).hasPrefix("OMARCHY_HOME_BLANK_V1\n"))
        p.homeDisk?.sizeGiB = 32; _ = try f.storage.prepare(p)
        #expect(lstat(image.path, &info) == 0 && info.st_size == 32 * 1_073_741_824)
        p.homeDisk?.sizeGiB = 16
        #expect(throws: VMFailure.self) { try f.storage.prepare(p) }
        p.homeDisk?.sizeGiB = 32
        let saved = image.appendingPathExtension("preserved")
        try FileManager.default.moveItem(at: image, to: saved)
        #expect(throws: VMFailure.self) { try f.storage.prepare(p) }
        #expect(!FileManager.default.fileExists(atPath: image.path))
        #expect(FileManager.default.fileExists(atPath: saved.path))
    }

    @Test("APFS reuse produces independent home files and leaves the source and root disk unchanged")
    func reuse() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var source = f.profile(name: "Source"); source.homeDisk = HomeDisk(sizeGiB: 16)
        _ = try f.storage.prepare(source)
        let original = f.storage.homeImage(source)
        let writer = try FileHandle(forWritingTo: original)
        try writer.seek(toOffset: 4096); try writer.write(contentsOf: Data("source sentinel".utf8)); try writer.close()
        var target = f.profile(name: "Replacement")
        target.homeDisk = HomeDisk(id: source.homeDisk!.id, sizeGiB: 16, sourceVMID: source.id)
        let registry = try RegistryStore(applicationSupport: f.support); _ = try registry.load(); try registry.save([source, target])
        _ = try f.storage.prepare(target)
        let copy = f.storage.homeImage(target)
        var old = stat(), new = stat()
        #expect(lstat(original.path, &old) == 0 && lstat(copy.path, &new) == 0)
        #expect(old.st_ino != new.st_ino && old.st_nlink == 1 && new.st_nlink == 1)
        let change = try FileHandle(forWritingTo: copy)
        try change.seek(toOffset: 4096); try change.write(contentsOf: Data("changed target".utf8)); try change.close()
        let check = try FileHandle(forReadingFrom: original); defer { try? check.close() }
        try check.seek(toOffset: 4096)
        #expect(try check.read(upToCount: 15) == Data("source sentinel".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.storage.root(for: source).appendingPathComponent("shell/disk.img").path))
    }

    @Test("damaged replacement copies cannot release their source for deletion", arguments: ["metadata", "truncated", "linked", "plan"])
    func incompleteCopyProtectsSource(_ damage: String) async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var source = f.profile(name: "Source"); source.homeDisk = HomeDisk(sizeGiB: 16)
        var replacement = f.profile(name: "Replacement")
        replacement.homeDisk = HomeDisk(id: source.homeDisk!.id, sizeGiB: 16, sourceVMID: source.id)
        let registry = try RegistryStore(applicationSupport: f.support); _ = try registry.load(); try registry.save([source, replacement])
        _ = try f.storage.prepare(source); _ = try f.storage.prepare(replacement)
        let manager = VMManager(runtime: FakeRuntime(), profiles: [source, replacement], applicationSupport: f.support, hostMemoryMiB: 32768, logicalCPUs: 8, registry: registry)
        let review = try #require(await manager.deletionRequest(source.id))
        if damage == "metadata" {
            try PrivateFiles.write(Data("{}".utf8), name: "state.json", in: f.storage.homeDirectory(replacement))
        } else if damage == "plan" {
            let damaged = HomeDisk(id: replacement.homeDisk!.id, sizeGiB: -1, sourceVMID: source.id)
            try PrivateFiles.write(JSONEncoder().encode(damaged), name: ".omarchy-home.json", in: f.storage.root(for: replacement))
        } else if damage == "truncated" {
            let fd = open(f.storage.homeImage(replacement).path, O_RDWR); defer { close(fd) }
            #expect(ftruncate(fd, 1_048_576) == 0)
        } else {
            try FileManager.default.linkItem(at: f.storage.homeImage(replacement), to: f.storage.homeImage(replacement).appendingPathExtension("linked"))
        }
        await #expect(throws: VMFailure.self) { try await manager.deletionRequest(source.id) }
        await #expect(throws: VMFailure.self) { try await manager.delete(source.id, confirmed: true, expectedIdentity: review.expectedIdentity) }
        #expect(FileManager.default.fileExists(atPath: f.storage.homeImage(source).path))
        #expect(await manager.snapshots().contains(where: { $0.id == source.id }))
    }

    @Test("replacement creation retains its owner's snapshot and protects the source until copying")
    func replacementProfile() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var source = f.profile(name: "Source"); source.homeDisk = HomeDisk(sizeGiB: 128)
        source.ownerSetup = try OwnerDefaults(enabled: true, configuration: OwnerConfiguration(username: "original"), credentialReference: UUID()).snapshot(for: source.id)
        let registry = try RegistryStore(applicationSupport: f.support); _ = try registry.load(); try registry.save([source])
        let manager = VMManager(runtime: FakeRuntime(), profiles: [source], applicationSupport: f.support, hostMemoryMiB: 32768, logicalCPUs: 8, registry: registry, portProbe: HomePort())
        let id = try await manager.create(name: "Replacement", memoryMiB: 4096, cpus: 4, diskGiB: 256,
            clipboardEnabled: true, immersiveMode: false, sshEnabled: false, reuseHomeFrom: source.id)
        let replacement = try #require(await manager.snapshots().first(where: { $0.id == id })?.profile)
        #expect(replacement.homeDisk == HomeDisk(id: source.homeDisk!.id, sizeGiB: 128, sourceVMID: source.id))
        #expect(replacement.diskGiB == 256)
        #expect(replacement.ownerSetup?.configuration == source.ownerSetup?.configuration)
        #expect(replacement.ownerSetup?.credentialReference == source.ownerSetup?.credentialReference)
        #expect(replacement.ownerSetup?.hostname != source.ownerSetup?.hostname)
        #expect(await manager.snapshots().first(where: { $0.id == source.id })?.profile == source)
        #expect(!FileManager.default.fileExists(atPath: f.storage.vms.path))
        await #expect(throws: VMFailure.self) { try await manager.deletionRequest(source.id) }
        await #expect(throws: VMFailure.self) {
            try await manager.create(name: "Wrong capacity", memoryMiB: 4096, cpus: 4, clipboardEnabled: true,
                immersiveMode: false, sshEnabled: false, homeDiskGiB: 256, reuseHomeFrom: source.id)
        }
        try await manager.delete(id, confirmed: true, expectedIdentity: nil)
        #expect(try await manager.deletionRequest(source.id) == nil)
    }

    @Test("CLI exposes independent sizes, creation-only layout, reuse UUID and strict JSON")
    func cli() throws {
        let source = UUID()
        let c = try #require(GuestCLIInvocation.parse(["create", "Replacement", "--disk", "128GiB", "--home-disk", "256GiB", "--reuse-home-from", source.uuidString]).request?.config)
        #expect(c.diskGiB == 128 && c.homeDiskGiB == 256 && c.reuseHomeFrom == source)
        #expect(try GuestCLIInvocation.parse(["create", "single", "--separate-home", "off"]).request?.config?.separateHome == false)
        #expect(try GuestCLIInvocation.parse(["update", "guest", "--home-disk", "256GiB"]).request?.config?.homeDiskGiB == 256)
        #expect(try GuestCLIInvocation.parse(["create", "guest", "--system-disk", "128GiB"]).request?.config?.diskGiB == 128)
        for args in [["update", "guest", "--separate-home", "on"], ["create", "guest", "--reuse-home-from", "bad"], ["create", "guest", "--home-disk", "1MiB"]] {
            #expect(throws: (any Error).self) { try GuestCLIInvocation.parse(args) }
        }
        for json in [#"{"homeDiskGiB":null}"#, #"{"separateHome":"yes"}"#, #"{"reuseHomeFrom":"bad"}"#] {
            #expect(throws: (any Error).self) { try GuestConfigurationPatch.decodeStrict(Data(json.utf8)) }
        }
    }

    @Test("configuration preserves disk identity, rejects layout changes and binds deletion review to home data")
    func configurationAndDeletion() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        var p = f.profile(); p.homeDisk = HomeDisk(sizeGiB: 16)
        let registry = try RegistryStore(applicationSupport: f.support); _ = try registry.load(); try registry.save([p])
        _ = try f.storage.prepare(p)
        let manager = VMManager(runtime: FakeRuntime(), profiles: [p], applicationSupport: f.support, hostMemoryMiB: 32768, logicalCPUs: 8, registry: registry)
        try await manager.update(p.id, configuration: GuestConfigurationPatch(homeDiskGiB: 32))
        #expect(await manager.snapshots()[0].profile.homeDisk?.sizeGiB == 32)
        await #expect(throws: VMFailure.self) { try await manager.update(p.id, configuration: GuestConfigurationPatch(homeDiskGiB: 16)) }
        var edited = await manager.snapshots()[0].profile
        edited.homeDisk = nil
        await #expect(throws: VMFailure.self) { try await manager.configure(edited) }
        let current = await manager.snapshots()[0].profile
        _ = try f.storage.prepare(current)
        let before = try f.storage.deletionIdentity(current)
        #expect(before.utf8.count <= 256)
        let file = try FileHandle(forWritingTo: f.storage.homeImage(current)); defer { try? file.close() }
        try file.seek(toOffset: 8192); try file.write(contentsOf: Data("changed fixture".utf8)); try file.synchronize()
        #expect(try f.storage.deletionIdentity(current) != before)
        #expect(throws: VMFailure.self) { try f.storage.trash(current, expectedIdentity: before, recycle: { _ in Issue.record("Changed home disk was admitted to Trash") }) }
        #expect(FileManager.default.fileExists(atPath: f.storage.homeImage(current).path))
    }
}
