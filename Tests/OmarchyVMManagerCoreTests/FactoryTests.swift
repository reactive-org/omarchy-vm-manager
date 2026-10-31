import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

private struct FactoryFixture {
    let files: RegistryFixture
    let kit: KitFixture
    let source: URL
    var manifest: [String: Any]
    let lock: RuntimeProvenance
    init() throws {
        files = try RegistryFixture(); kit = try KitFixture()
        try PrivateFiles.directory(files.storage.directory, create: true)
        source = files.support.appendingPathComponent("Prepared.factory")
        try PrivateFiles.directory(source, create: true)
        for path in [VMFactorySelection.packagePath, "Contents/Resources/runtime/bin/Try Omarchy", "Contents/Resources/firmware/edk2-aarch64-code.fd", "Contents/Resources/scripts/run-qemu-gpu.sh"] {
            let target = kit.kit.bundleURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: target)
        }
        var provenance = kit.lock
        provenance.customFactoryVersion = 1; provenance.managedSSHVersion = 1; provenance.managedSetupVersion = 1
        // The synthetic package has no executable guest and is used only for file verification.
        provenance = RuntimeProvenance(format: provenance.format, upstreamBase: provenance.upstreamBase, patchCommit: provenance.patchCommit,
            patchSHA256: provenance.patchSHA256, referenceKitSHA256: provenance.referenceKitSHA256, kitSHA256: provenance.kitSHA256,
            kitVersion: provenance.kitVersion, runProtocolVersion: provenance.runProtocolVersion, buildDate: provenance.buildDate,
            focusAwareClipboard: true, managedSSHVersion: 1, manualPauseVersion: 1, customFactoryVersion: 1, managedSetupVersion: 1,
            composition: "synthetic no-VM factory fixture", files: try KitVerifier.inventory(at: kit.kit.bundleURL))
        lock = provenance
        let compressed = Data("synthetic compressed image; never booted".utf8)
        let recipe = Data("reviewed provisioning inputs".utf8)
        let image: [String: Any] = ["format": 1, "kind": "upstream-shell-factory", "platform": "aarch64", "boot": "uefi-limine",
            "disk": ["path": "test.img", "bytes": 21474836480, "sha256": String(repeating: "d", count: 64)],
            "compressed": ["path": "test.img.zst", "sha256": KitVerifier.sha256(compressed)]]
        let imageData = try JSONSerialization.data(withJSONObject: image, options: .sortedKeys)
        try imageData.write(to: source.appendingPathComponent("factory.json"))
        try compressed.write(to: source.appendingPathComponent("test.img.zst"))
        try recipe.write(to: source.appendingPathComponent("provisioning.json"))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        manifest = ["format": 1, "name": "Reviewed test image", "architecture": "aarch64", "boot": "uefi-limine", "customFactoryVersion": 1,
            "managedSSHVersion": 1, "managedSetupVersion": 1, "integrationPackageSHA256": lock.files[VMFactorySelection.packagePath]!,
            "ownerSetupContractSHA256": try VMFactorySelection.digest(repository.appendingPathComponent("Sources/OmarchyVMManagerCore/Resources/OwnerSetupContract.json")),
            "files": ["factory.json": KitVerifier.sha256(imageData), "test.img.zst": KitVerifier.sha256(compressed), "provisioning.json": KitVerifier.sha256(recipe)],
            "provisioning": ["provisioning.json": KitVerifier.sha256(recipe)], "runtimeFiles": lock.files]
    }
    func write() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys)
        try data.write(to: source.appendingPathComponent("reviewed-factory.json"))
        return KitVerifier.sha256(data)
    }
    func catalog(reviewed: Set<String>) throws -> FactoryCatalog {
        FactoryCatalog(applicationSupport: files.support, kit: kit.kit, lockData: try JSONEncoder().encode(lock), reviewed: reviewed)
    }
    func cleanup() { files.cleanup(); kit.cleanup() }
}

@Suite("Reviewed custom factories — no VMs")
struct FactoryTests {
    @Test("renaming the official label preserves legacy recorded factory identities")
    func officialLabelCompatibility() throws {
        let files = try RegistryFixture(); defer { files.cleanup() }
        let legacy = FactoryIdentity(kind: .official, name: "Official Omarchy", manifestSHA256: FactoryIdentity.official.manifestSHA256, diskSHA256: FactoryIdentity.official.diskSHA256)
        var profile = files.profile(); profile.factory = legacy
        let encoded = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(VMProfile.self, from: encoded)
        try RegistryStore.validate(restored)
        _ = try files.storage.prepare(restored)
        try files.storage.validate(restored)
        let marker = try JSONDecoder().decode(FactoryIdentity.self, from: PrivateFiles.read(files.storage.root(for: restored).appendingPathComponent(".omarchy-factory.json")))
        #expect(marker == legacy && restored.factory == legacy)
        #expect(legacy.displayName == "Offical Try Omarchy")
        try FactoryIdentity.official.validate()
        let altered = FactoryIdentity(kind: .official, name: legacy.name, manifestSHA256: String(repeating: "a", count: 64), diskSHA256: legacy.diskSHA256)
        #expect(throws: VMFailure.self) { try altered.validate() }
    }
    @Test("factory review bytes must match their compiled pin and contain unique valid digests")
    func reviewPin() throws {
        let original = Data("[]\n".utf8)
        #expect(try FactoryCatalog.decodeReviews(original, expectedSHA256: KitVerifier.sha256(original)).isEmpty)
        let forged = try JSONEncoder().encode([String(repeating: "a", count: 64)])
        #expect(throws: VMFailure.self) { try FactoryCatalog.decodeReviews(forged, expectedSHA256: KitVerifier.sha256(original)) }
        for values in [["bad"], [String(repeating: "a", count: 64), String(repeating: "a", count: 64)]] {
            let data = try JSONEncoder().encode(values)
            #expect(throws: VMFailure.self) { try FactoryCatalog.decodeReviews(data, expectedSHA256: KitVerifier.sha256(data)) }
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("Sources/OmarchyVMManagerCore/Resources/ReviewedFactories.json"))
        #expect(KitVerifier.sha256(data) == FactoryReviewPin.sha256)
    }
    @Test("one damaged import cannot hide official or another valid factory")
    func damagedListing() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [digest])
        _ = try catalog.importBundle(f.source)
        let unknown = String(repeating: "e", count: 64)
        try PrivateFiles.directory(catalog.directory.appendingPathComponent(unknown), create: true)
        var listing = try catalog.listing()
        #expect(listing.factories.map(\.selector) == ["official", digest])
        #expect(listing.issues.map(\.selector) == [unknown])
        try Data("changed".utf8).write(to: catalog.root(digest).appendingPathComponent("test.img.zst"))
        listing = try catalog.listing()
        #expect(listing.factories == [.official])
        #expect(Set(listing.issues.map(\.selector)) == [unknown, digest])
        #expect(throws: (any Error).self) { try catalog.identity(for: digest) }
        let registry = try RegistryStore(applicationSupport: f.files.support); _ = try registry.load()
        let manager = VMManager(runtime: FakeRuntime(), profiles: [], applicationSupport: f.files.support, registry: registry)
        await manager.installFactoryCatalog(catalog)
        let service = GuestCommandService(manager: manager, applicationSupport: f.files.support)
        let response = await service.execute(GuestCommandRequest(command: .factories))
        #expect(response.ok && response.factories == [.official])
        #expect(response.factoryIssues?.count == 2)
    }
    @Test("unknown bundles cannot approve themselves or create a cache")
    func unreviewed() throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        _ = try f.write()
        let catalog = try f.catalog(reviewed: [])
        #expect(throws: VMFailure.self) { try catalog.importBundle(f.source) }
        #expect(!FileManager.default.fileExists(atPath: catalog.directory.path))
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
    }
    @Test("reviewed imports are copied, verified, idempotent and selectable alongside official")
    func imports() throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [digest])
        let identity = try catalog.importBundle(f.source)
        #expect(identity.kind == .custom && identity.manifestSHA256 == digest)
        #expect(throws: VMFailure.self) { try catalog.validateCapacity(identity, diskGiB: Int.max) }
        #expect(try catalog.importBundle(f.source) == identity)
        #expect(try catalog.identities() == [.official, identity])
        #expect(try catalog.identity(for: digest) == identity)
        let selection = try #require(try catalog.selection(for: identity))
        #expect(selection.bundlePath != f.source.path)
        try Data("source changed".utf8).write(to: f.source.appendingPathComponent("test.img.zst"))
        #expect(try catalog.identity(for: digest) == identity)
        try Data("cache changed".utf8).write(to: URL(fileURLWithPath: selection.bundlePath).appendingPathComponent("test.img.zst"))
        #expect(throws: (any Error).self) { try catalog.selection(for: identity) }
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
    }
    @Test("incompatible image, runtime, package and provisioning are refused", arguments: ["architecture", "boot", "customFactoryVersion", "managedSSHVersion", "managedSetupVersion", "integrationPackageSHA256", "ownerSetupContractSHA256", "provisioning", "runtimeFiles"])
    func incompatible(_ key: String) throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        switch key {
        case "architecture": f.manifest[key] = "x86_64"
        case "boot": f.manifest[key] = "bios"
        case "customFactoryVersion", "managedSSHVersion", "managedSetupVersion": f.manifest[key] = 2
        case "provisioning": f.manifest[key] = ["provisioning.json": String(repeating: "a", count: 64)]
        case "runtimeFiles":
            var inventory = f.lock.files; inventory["Contents/Resources/runtime/bin/Try Omarchy"] = String(repeating: "a", count: 64); f.manifest[key] = inventory
        default: f.manifest[key] = String(repeating: "a", count: 64)
        }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [digest])
        #expect(throws: (any Error).self) { try catalog.importBundle(f.source) }
    }
    @Test("extra files, traversal, symlinks and changed image/provisioning hashes fail closed", arguments: ["extra", "symlink", "traversal", "image", "recipe"])
    func unsafe(_ kind: String) throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        if kind == "traversal" {
            var inventory = f.manifest["files"] as! [String: String]; inventory["../escape"] = String(repeating: "a", count: 64); f.manifest["files"] = inventory
        }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [digest])
        if kind == "symlink" {
            let target = f.source.appendingPathComponent("test.img.zst")
            try FileManager.default.moveItem(at: target, to: f.files.support.appendingPathComponent("outside"))
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: f.files.support.appendingPathComponent("outside").path)
        } else if kind != "traversal" {
            let name = kind == "image" ? "test.img.zst" : kind == "recipe" ? "provisioning.json" : "extra"
            try Data("changed".utf8).write(to: f.source.appendingPathComponent(name))
        }
        #expect(throws: (any Error).self) { try catalog.importBundle(f.source) }
    }
    @Test("image metadata and missing runtime capability cannot assert compatibility")
    func imageContract() throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        let imageURL = f.source.appendingPathComponent("factory.json")
        var image = try JSONSerialization.jsonObject(with: Data(contentsOf: imageURL)) as! [String: Any]
        image["platform"] = "x86_64"
        let bytes = try JSONSerialization.data(withJSONObject: image)
        try bytes.write(to: imageURL)
        var hashes = f.manifest["files"] as! [String: String]
        hashes["factory.json"] = KitVerifier.sha256(bytes); f.manifest["files"] = hashes
        let digest = try f.write(), catalog = try f.catalog(reviewed: [digest])
        #expect(throws: (any Error).self) { try catalog.importBundle(f.source) }
        var lock = f.lock; lock.customFactoryVersion = nil
        let unsupported = FactoryCatalog(applicationSupport: f.files.support, kit: f.kit.kit, lockData: try JSONEncoder().encode(lock), reviewed: [digest])
        #expect(throws: VMFailure.self) { try unsupported.importBundle(f.source) }
    }
    @Test("factory selection uses the public protocol and rejects malformed fields")
    func protocolRoundTrip() throws {
        var config = VMRunConfiguration(productName: "Fixture", storageRoot: "/private/tmp/" + UUID().uuidString)
        config.factory = VMFactorySelection(bundlePath: "/private/tmp/factory", manifestSHA256: String(repeating: "a", count: 64))
        #expect(try VMRunConfiguration.decode(line: config.encodedLine()) == config)
        config.factory = VMFactorySelection(bundlePath: "relative", manifestSHA256: "bad")
        #expect(throws: VMRunProtocolError.self) { try config.encodedLine() }
        #expect(try GuestCLIInvocation.parse(["factories"]).request?.command == .factories)
        #expect(try GuestCLIInvocation.parse(["factory-import", "/private/tmp/prepared.factory"]).request?.command == .importFactory)
        #expect(try GuestCLIInvocation.parse(["create", "Custom", "--factory", "official"]).request?.config?.factory == "official")
        #expect(throws: VMFailure.self) { try GuestCLIInvocation.parse(["update", "Existing", "--cpus", "4", "--factory", "official"]) }
    }
    @Test("legacy identity stays absent; new identity persists and cannot be changed")
    func profileContinuity() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [digest]), identity = try catalog.importBundle(f.source)
        let registry = try RegistryStore(applicationSupport: f.files.support); _ = try registry.load()
        let legacy = f.files.profile(name: "Legacy"); try registry.save([legacy])
        let legacyRoot = try f.files.storage.prepare(legacy)
        try PrivateFiles.directory(legacyRoot.appendingPathComponent("shell"), create: true)
        try PrivateFiles.write(Data("existing disk fixture".utf8), name: "disk.img", in: legacyRoot.appendingPathComponent("shell"))
        let legacyInventory = try KitVerifier.inventory(at: legacyRoot)
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [legacy], applicationSupport: f.files.support, hostMemoryMiB: 65536, logicalCPUs: 64, registry: registry)
        await manager.installFactoryCatalog(catalog)
        let id = try await manager.create(name: "Custom", memoryMiB: 4096, cpus: 4, clipboardEnabled: false, immersiveMode: false, sshEnabled: false, factory: digest)
        var custom = try #require(await manager.snapshots().first(where: { $0.id == id })?.profile)
        #expect(custom.factory == identity)
        struct SavedRegistry: Decodable { let profiles: [VMProfile] }
        let persisted = try JSONDecoder().decode(SavedRegistry.self, from: PrivateFiles.read(registry.directory.appendingPathComponent("registry.json")))
        #expect(persisted.profiles.first(where: { $0.id == legacy.id }) == legacy)
        #expect(persisted.profiles.first(where: { $0.id == id })?.factory == identity)
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.root(for: custom).path))
        custom.factory = .official
        do { try await manager.configure(custom); Issue.record("Factory replacement was allowed") } catch { }
        let officialID = try await manager.create(name: "Official", memoryMiB: 4096, cpus: 4, clipboardEnabled: false, immersiveMode: false, sshEnabled: false)
        #expect(await manager.snapshots().first(where: { $0.id == officialID })?.profile.factory == .official)
        let saved = try #require(await manager.snapshots().first(where: { $0.id == id })?.profile)
        _ = try f.files.storage.prepare(saved)
        #expect(throws: VMFailure.self) { try f.files.storage.validate(custom) }
        try f.files.storage.validate(saved)
        #expect(try KitVerifier.inventory(at: legacyRoot) == legacyInventory)
        #expect(runtime.startedHandles.isEmpty)
    }
}

private final class GatedFactoryRuntime: VMRuntime, @unchecked Sendable {
    let slow: UUID
    let fake = FakeRuntime(initialEvents: [.ready])
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entered = false
    private var opened = false
    init(slow: UUID) { self.slow = slow }
    var isBlocked: Bool { lock.withLock { entered && !opened } }
    func preflight() -> VMRunError? { nil }
    func start(_ request: VMStartRequest, onEvent: @escaping @Sendable (VMRuntimeEvent) -> Void) throws -> any VMRuntimeHandle {
        if request.profile.id == slow {
            lock.withLock { entered = true }
            gate.wait()
        }
        return try fake.start(request, onEvent: onEvent)
    }
    func release() {
        let signal = lock.withLock { if opened { return false }; opened = true; return true }
        if signal { gate.signal() }
    }
}

@Suite("Factory verification keeps lifecycle responsive — no VMs")
struct FactoryLifecycleTests {
    @Test("other exits and pending stop commands survive slow launch verification", arguments: ["shutdown", "force", "quit"])
    func slowVerification(_ action: String) async throws {
        let files = try RegistryFixture(); defer { files.cleanup() }
        let fast = files.profile(name: "Already running fixture"), slow = files.profile(name: "Slow factory fixture")
        let runtime = GatedFactoryRuntime(slow: slow.id)
        let manager = VMManager(runtime: runtime, profiles: [fast, slow], applicationSupport: files.support)
        try await manager.start(fast.id)
        let existing = try #require(runtime.fake.startedHandles.first)
        let fallback = Task.detached {
            do { try await Task.sleep(for: .seconds(5)); runtime.release() } catch { }
        }
        defer { runtime.release(); fallback.cancel() }
        let launch = Task { try await manager.start(slow.id) }
        #expect(await eventually { runtime.isBlocked })
        existing.emit(.exited(status: 0))
        #expect(await eventually { await manager.activeSessionCount == 1 })
        #expect(runtime.isBlocked)
        #expect(await manager.allocatedMemoryMiB == slow.memoryMiB)
        await #expect(throws: VMFailure.self) { try await manager.start(slow.id) }
        switch action {
        case "force": try await manager.forceStop(slow.id, confirmed: true)
        case "quit": #expect(await manager.beginApplicationShutdown() == false)
        default: await manager.shutDown(slow.id)
        }
        #expect(runtime.isBlocked)
        runtime.release()
        try await launch.value
        let pending = try #require(runtime.fake.startedHandles.last)
        #expect(pending.shutdownCount == (action == "force" ? 0 : 1))
        #expect(pending.terminationCount == (action == "force" ? 1 : 0))
        #expect(await eventually { await manager.snapshots().first(where: { $0.id == slow.id })?.state == .stopping })
        pending.emit(.error(VMRunError(code: .launchFailed, message: "Synthetic verification failure")))
        #expect(await manager.activeSessionCount == 1)
        pending.emit(.exited(status: 1))
        #expect(await eventually { await manager.isIdle })
    }
}
