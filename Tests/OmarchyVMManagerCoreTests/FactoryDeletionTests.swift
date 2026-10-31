import Darwin
import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

private final class FixtureFactoryTrash: FactoryTrashService, @unchecked Sendable {
    enum Behavior { case move, fail, noOp, moveThenFail }
    let destination: URL
    let behavior: Behavior
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private let paused: Bool
    private var entered = false
    private var paths: [URL] = []
    init(destination: URL, behavior: Behavior = .move, paused: Bool = false) throws {
        self.destination = destination; self.behavior = behavior; self.paused = paused
        try PrivateFiles.directory(destination, create: true)
    }
    var calls: [URL] { lock.withLock { paths } }
    var waiting: Bool { lock.withLock { entered } }
    func release() {
        let waiter = lock.withLock { released = true; let value = continuation; continuation = nil; return value }
        waiter?.resume()
    }
    func moveToTrash(_ directory: URL) async throws {
        lock.withLock { paths.append(directory); entered = true }
        if paused {
            await withCheckedContinuation { waiter in
                let resume = lock.withLock {
                    if released { return true }
                    continuation = waiter
                    return false
                }
                if resume { waiter.resume() }
            }
        }
        if behavior == .fail { throw VMFailure(code: "fixture-trash-error", message: "Synthetic Trash failure") }
        if behavior == .noOp { return }
        try FileManager.default.moveItem(at: directory, to: destination.appendingPathComponent(directory.lastPathComponent))
        if behavior == .moveThenFail { throw VMFailure(code: "fixture-trash-error", message: "Synthetic post-move failure") }
    }
}

private func factoryManager(_ f: FactoryFixture, profiles: [VMProfile] = [], trash: any FactoryTrashService, runtime: FakeRuntime = FakeRuntime()) async throws -> (VMManager, RegistryStore) {
    let registry = try RegistryStore(applicationSupport: f.files.support)
    _ = try registry.load(); try registry.save(profiles)
    let manager = VMManager(runtime: runtime, profiles: profiles, applicationSupport: f.files.support, registry: registry, factoryTrashService: trash)
    await manager.installFactoryCatalog(try f.catalog(reviewed: []))
    return (manager, registry)
}

@Suite("Factory deletion — no VMs")
struct FactoryDeletionTests {
    @Test("factory-delete accepts one manifest digest and has no force or path override")
    func arguments() throws {
        let digest = String(repeating: "a", count: 64)
        let request = try #require(GuestCLIInvocation.parse(["factory-delete", digest]).request)
        #expect(request.command == .deleteFactory && request.selector == digest)
        for args in [["factory-delete"], ["factory-delete", "/private/tmp/example"], ["factory-delete", "../escape"], ["factory-delete", digest, "extra"], ["factory-delete", digest, "--force"], ["factory-delete", digest, "--start"], ["factory-delete", digest, "--wait"], ["factory-delete", digest, "--cpus", "4"]] {
            #expect(throws: VMFailure.self) { try GuestCLIInvocation.parse(args) }
        }
        for selector in ["official", FactoryIdentity.official.manifestSHA256] {
            do { _ = try GuestCLIInvocation.parse(["factory-delete", selector]); Issue.record("Official factory was accepted") }
            catch let failure as VMFailure { #expect(failure.code == "factory-protected") }
        }
    }
    @Test("unreferenced factory and receipt move together while source, registry and guest disks stay intact")
    func deletion() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: []), identity = try catalog.importBundle(f.source)
        let source = try KitVerifier.inventory(at: f.source)
        let receipt = try PrivateFiles.read(catalog.receiptURL(digest))
        let guest = f.files.profile(name: "Unrelated guest fixture")
        let root = try f.files.storage.prepare(guest)
        try PrivateFiles.directory(root.appendingPathComponent("shell"), create: true)
        try PrivateFiles.write(Data("existing fixture disk".utf8), name: "disk.img", in: root.appendingPathComponent("shell"))
        let diskInventory = try KitVerifier.inventory(at: root)
        let trash = try FixtureFactoryTrash(destination: f.files.support.appendingPathComponent("Trash"))
        let runtime = FakeRuntime()
        let (manager, registry) = try await factoryManager(f, profiles: [guest], trash: trash, runtime: runtime)
        let registryData = try PrivateFiles.read(registry.directory.appendingPathComponent("registry.json"))
        let service = GuestCommandService(manager: manager, applicationSupport: f.files.support)
        let revision = await manager.factoryLibraryRevision
        let response = await service.execute(GuestCommandRequest(command: .deleteFactory, selector: digest))
        #expect(await manager.observation().factoryRevision != revision)
        #expect(response.ok && response.deletedFactory == identity)
        #expect(!FileManager.default.fileExists(atPath: catalog.root(digest).path))
        #expect(!FileManager.default.fileExists(atPath: catalog.receiptURL(digest).path))
        let folders = try FileManager.default.contentsOfDirectory(at: trash.destination, includingPropertiesForKeys: nil)
        let folder = try #require(folders.first)
        #expect(folders.count == 1 && folder.lastPathComponent.hasPrefix("Omarchy Factory " + digest))
        #expect(try PrivateFiles.read(folder.appendingPathComponent("Import receipt.json")) == receipt)
        #expect(try KitVerifier.inventory(at: folder.appendingPathComponent("Factory.bundle")) == source)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Factory deletion.json").path))
        #expect(try catalog.identities() == [.official])
        #expect(try KitVerifier.inventory(at: f.source) == source)
        #expect(try KitVerifier.inventory(at: root) == diskInventory)
        #expect(try PrivateFiles.read(registry.directory.appendingPathComponent("registry.json")) == registryData)
        #expect(runtime.startedHandles.isEmpty)
        #expect(try catalog.importBundle(f.source) == identity)
    }
    @Test("all existing profiles protect their factory, including stopped metadata-only guests", arguments: ["stopped", "running", "error"])
    func references(_ state: String) async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: []), identity = try catalog.importBundle(f.source)
        var guest = f.files.profile(); guest.factory = identity
        let original = try KitVerifier.inventory(at: catalog.directory)
        let trash = try FixtureFactoryTrash(destination: f.files.support.appendingPathComponent("Trash"))
        let runtime = FakeRuntime()
        let (manager, registry) = try await factoryManager(f, profiles: [guest], trash: trash, runtime: runtime)
        if state != "stopped" {
            try await manager.start(guest.id)
            let handle = try #require(runtime.startedHandles.first)
            handle.emit(.ready)
            if state == "error" { handle.emit(.error(VMRunError(code: .launchFailed, message: "Synthetic diagnostic"))) }
        }
        let registryData = try PrivateFiles.read(registry.directory.appendingPathComponent("registry.json"))
        let response = await GuestCommandService(manager: manager, applicationSupport: f.files.support).execute(GuestCommandRequest(command: .deleteFactory, selector: digest))
        #expect(!response.ok && response.error?.code == "factory-in-use")
        #expect(trash.calls.isEmpty)
        #expect(try KitVerifier.inventory(at: catalog.directory) == original)
        #expect(try PrivateFiles.read(registry.directory.appendingPathComponent("registry.json")) == registryData)
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
        #expect(throws: VMFailure.self) { try FactoryReferencePolicy.requireUnused(digest, profiles: [], pendingCreations: 1) }
        try FactoryReferencePolicy.requireUnused(digest, profiles: [], pendingCreations: 0)
        if let handle = runtime.startedHandles.first {
            #expect(handle.shutdownCount == 0 && handle.terminationCount == 0)
            handle.emit(.exited(status: 0))
            #expect(await eventually { await manager.activeSessionCount == 0 })
        }
    }
    @Test("a verified legacy compiled-pin factory can be trashed without a local receipt")
    func legacyFactory() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [digest])
        let identity = try catalog.importBundle(f.source)
        try FileManager.default.removeItem(at: catalog.receiptURL(digest))
        let trash = try FixtureFactoryTrash(destination: f.files.support.appendingPathComponent("Trash"))
        let (manager, _) = try await factoryManager(f, trash: trash)
        await manager.installFactoryCatalog(catalog)
        #expect(try await manager.deleteFactory(digest) == identity)
        let folder = try #require(FileManager.default.contentsOfDirectory(at: trash.destination, includingPropertiesForKeys: nil).first)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Import receipt.json").path))
        #expect(try KitVerifier.inventory(at: folder.appendingPathComponent("Factory.bundle")) == KitVerifier.inventory(at: f.source))
        let record = try #require(JSONSerialization.jsonObject(with: PrivateFiles.read(folder.appendingPathComponent("Factory deletion.json"))) as? [String: Any])
        #expect(record["includesReceipt"] as? Bool == false)
        #expect(try catalog.identities() == [.official])
    }
    @Test("unknown factories and protected official selectors never reach Trash")
    func missingOrProtected() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let trash = try FixtureFactoryTrash(destination: f.files.support.appendingPathComponent("Trash"))
        let (manager, _) = try await factoryManager(f, trash: trash)
        for (selector, code) in [(String(repeating: "a", count: 64), "unknown-factory"), ("official", "factory-protected"), (FactoryIdentity.official.manifestSHA256, "factory-protected")] {
            do { _ = try await manager.deleteFactory(selector); Issue.record("Unexpected deletion") }
            catch let failure as VMFailure { #expect(failure.code == code) }
        }
        #expect(trash.calls.isEmpty)
    }
    @Test("changed or unsafe payloads and receipts are preserved", arguments: ["payload", "extra", "symlink", "hardlink", "receipt"])
    func unsafe(_ mode: String) async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        _ = try catalog.importBundle(f.source)
        let payload = catalog.root(digest).appendingPathComponent("test.img.zst")
        if mode == "symlink" {
            try FileManager.default.removeItem(at: payload)
            try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: f.source.appendingPathComponent("test.img.zst"))
        } else if mode == "hardlink" {
            try FileManager.default.linkItem(at: payload, to: f.files.support.appendingPathComponent("outside-link"))
        } else if mode == "receipt" {
            try Data("broken receipt".utf8).write(to: catalog.receiptURL(digest))
        } else {
            try Data("changed".utf8).write(to: mode == "extra" ? catalog.root(digest).appendingPathComponent("unexpected") : payload)
        }
        let trash = try FixtureFactoryTrash(destination: f.files.support.appendingPathComponent("Trash"))
        let (manager, _) = try await factoryManager(f, trash: trash)
        await #expect(throws: (any Error).self) { try await manager.deleteFactory(digest) }
        #expect(trash.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: catalog.root(digest).path))
        #expect(FileManager.default.fileExists(atPath: catalog.receiptURL(digest).path))
    }
    @Test("Trash failure rolls back and an ambiguous post-move failure preserves recoverable files", arguments: ["fail", "no-op", "after-move"])
    func trashFailure(_ mode: String) async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        _ = try catalog.importBundle(f.source)
        let before = try KitVerifier.inventory(at: catalog.directory)
        let behavior: FixtureFactoryTrash.Behavior = mode == "fail" ? .fail : mode == "no-op" ? .noOp : .moveThenFail
        let trash = try FixtureFactoryTrash(destination: f.files.support.appendingPathComponent("Trash"), behavior: behavior)
        let (manager, _) = try await factoryManager(f, trash: trash)
        do { _ = try await manager.deleteFactory(digest); Issue.record("Expected Trash failure") }
        catch let failure as VMFailure {
            #expect(failure.code == (mode == "after-move" ? "factory-delete-outcome-unknown" : "factory-trash-failed"))
        }
        #expect(await manager.isIdle)
        if mode == "after-move" {
            #expect(try FileManager.default.contentsOfDirectory(atPath: trash.destination.path).count == 1)
        } else { #expect(try KitVerifier.inventory(at: catalog.directory) == before) }
    }
    @Test("a factory changed after review cannot be trashed")
    func changedAfterReview() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        _ = try catalog.importBundle(f.source)
        let review = try catalog.deletionReview(digest)
        try Data("changed".utf8).write(to: catalog.root(digest).appendingPathComponent("test.img.zst"))
        let before = try KitVerifier.inventory(at: catalog.directory)
        let trash = try FixtureFactoryTrash(destination: f.files.support.appendingPathComponent("Trash"))
        await #expect(throws: VMFailure.self) { try await catalog.trash(review, service: trash, beforeTrash: {}) }
        #expect(trash.calls.isEmpty)
        #expect(try KitVerifier.inventory(at: catalog.directory) == before)
    }
    @Test("deletion reservations block creation, import and overlapping deletion; Quit waits")
    func concurrentMutation() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: []), source = f.source
        _ = try catalog.importBundle(source)
        let trash = try FixtureFactoryTrash(destination: f.files.support.appendingPathComponent("Trash"), paused: true)
        let (manager, _) = try await factoryManager(f, trash: trash)
        let fallback = Task.detached { try? await Task.sleep(for: .seconds(5)); trash.release() }
        defer { trash.release(); fallback.cancel() }
        let deletion = Task { try await manager.deleteFactory(digest) }
        #expect(await eventually { trash.waiting })
        #expect(await manager.isIdle == false)
        #expect(await manager.prepareToQuitIfIdle() == false)
        await #expect(throws: VMFailure.self) { try await manager.create(name: "Concurrent fixture", memoryMiB: 4096, cpus: 4, clipboardEnabled: false, immersiveMode: false, sshEnabled: false, factory: digest) }
        await #expect(throws: VMFailure.self) { try await manager.importFactory(source) }
        await #expect(throws: VMFailure.self) { try await manager.deleteFactory(digest) }
        #expect(await manager.beginApplicationShutdown() == false)
        deletion.cancel()
        trash.release()
        #expect(try await deletion.value.manifestSHA256 == digest)
        await manager.waitForFactoryDeletion()
        #expect(await manager.isIdle)
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
    }
}

private final class DeletionChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

extension FactoryDeletionTests {
    @Test("an external registry change before Trash rolls back the transaction and preserves the new reference")
    func changedRegistry() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: []), identity = try catalog.importBundle(f.source)
        let trash = try FixtureFactoryTrash(destination: f.files.support.appendingPathComponent("Trash"))
        let (_, registry) = try await factoryManager(f, trash: trash)
        let review = try catalog.deletionReview(digest)
        var profile = f.files.profile(); profile.factory = identity
        let path = registry.directory.appendingPathComponent("registry.json")
        var contents = try JSONSerialization.jsonObject(with: PrivateFiles.read(path)) as! [String: Any]
        contents["profiles"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([profile]))
        let external = try JSONSerialization.data(withJSONObject: contents)
        let checks = DeletionChecks()
        do {
            _ = try await catalog.trash(review, service: trash, beforeTrash: {
                if checks.next() == 2 { try external.write(to: path) }
                try registry.checkRevision()
            })
            Issue.record("Changed registry was ignored")
        } catch let failure as VMFailure { #expect(failure.code == "unsafe-storage") }
        #expect(trash.calls.isEmpty)
        #expect(try PrivateFiles.read(path) == external)
        #expect(try catalog.identity(for: digest) == identity)
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
    }
    @Test("an in-progress import prevents factory deletion")
    func importBusy() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: []), source = f.source
        _ = try catalog.importBundle(source)
        let before = try KitVerifier.inventory(at: catalog.directory)
        let trash = try FixtureFactoryTrash(destination: f.files.support.appendingPathComponent("Trash"))
        let (manager, _) = try await factoryManager(f, trash: trash)
        let gate = FactoryImportGate(pauseAt: .verifying)
        let fallback = Task.detached {
            do { try await Task.sleep(for: .seconds(5)); gate.release() } catch { }
        }
        defer { gate.release(); fallback.cancel() }
        let importing = Task { try await manager.importFactory(source) { gate.report($0) } }
        #expect(await eventually { gate.isBlocked })
        do { _ = try await manager.deleteFactory(digest); Issue.record("Deletion raced import") }
        catch let failure as VMFailure { #expect(failure.code == "factory-busy") }
        #expect(trash.calls.isEmpty)
        gate.release()
        #expect(try await importing.value.manifestSHA256 == digest)
        #expect(try KitVerifier.inventory(at: catalog.directory) == before)
    }
}

private struct ClosureFactoryTrash: FactoryTrashService {
    let action: @Sendable (URL) throws -> Void
    func moveToTrash(_ directory: URL) async throws { try action(directory) }
}

extension FactoryDeletionTests {
    @Test("rollback never overwrites a newly appeared library path and preserves its recovery record")
    func rollbackCollision() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        _ = try catalog.importBundle(f.source)
        let review = try catalog.deletionReview(digest)
        let root = catalog.root(digest)
        let source = try KitVerifier.inventory(at: root)
        let receipt = try PrivateFiles.read(catalog.receiptURL(digest))
        let service = ClosureFactoryTrash { _ in
            try PrivateFiles.directory(root, create: true)
            try PrivateFiles.write(Data("preserve this new path".utf8), name: "Preserve.me", in: root)
            throw VMFailure(code: "fixture-failure", message: "Synthetic failure after a path appeared")
        }
        do { _ = try await catalog.trash(review, service: service, beforeTrash: {}); Issue.record("Expected recovery refusal") }
        catch let failure as VMFailure { #expect(failure.code == "factory-delete-recovery-required") }
        #expect(try PrivateFiles.read(root.appendingPathComponent("Preserve.me")) == Data("preserve this new path".utf8))
        let recoveries = try FileManager.default.contentsOfDirectory(at: catalog.directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("Omarchy Factory ") }
        let recovery = try #require(recoveries.first)
        #expect(try KitVerifier.inventory(at: recovery.appendingPathComponent("Factory.bundle")) == source)
        #expect(try PrivateFiles.read(recovery.appendingPathComponent("Import receipt.json")) == receipt)
        #expect(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("Factory deletion.json").path))
    }
}
