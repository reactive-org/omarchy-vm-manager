import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

struct FactoryFixture {
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
        let contractProvenance: [String: Any] = ["version": 1, "reportVersion": 1, "sourceCommit": kit.lock.patchCommit,
            "contracts": ["official": VMOwnerSetupContract.official, "lean-e4fffc6": VMOwnerSetupContract.lean]]
        try JSONSerialization.data(withJSONObject: contractProvenance, options: .sortedKeys).write(to: kit.kit.bundleURL.appendingPathComponent(VMOwnerSetupContract.provenancePath))
        var provenance = kit.lock
        provenance.customFactoryVersion = 1; provenance.managedSSHVersion = 1; provenance.managedSetupVersion = 1
        // The synthetic package has no executable guest and is used only for file verification.
        provenance = RuntimeProvenance(format: provenance.format, upstreamBase: provenance.upstreamBase, patchCommit: provenance.patchCommit,
            patchSHA256: provenance.patchSHA256, referenceKitSHA256: provenance.referenceKitSHA256, kitSHA256: provenance.kitSHA256,
            kitVersion: provenance.kitVersion, runProtocolVersion: provenance.runProtocolVersion, buildDate: provenance.buildDate,
            focusAwareClipboard: true, managedSSHVersion: 1, manualPauseVersion: 1, customFactoryVersion: 1, managedSetupVersion: 1, ownerSetupContractsVersion: 1, ownerSetupReportVersion: 1,
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
            "managedSSHVersion": 1, "managedSetupVersion": 1, "ownerSetupReportVersion": 1, "integrationPackageSHA256": lock.files[VMFactorySelection.packagePath]!,
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
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return FactoryCatalog(applicationSupport: files.support, kit: kit.kit, lockData: try encoder.encode(lock), reviewed: reviewed)
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
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
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
    @Test("explicit import verifies and persists a local factory without a bundled review pin")
    func localImport() throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        #expect(throws: VMFailure.self) { try catalog.verify(f.source, digest: digest) }
        let identity = try catalog.importBundle(f.source)
        let receiptData = try PrivateFiles.read(catalog.receiptURL(digest))
        let receipt = try JSONDecoder().decode(FactoryImportReceipt.self, from: receiptData)
        #expect(receipt.factory == identity && receipt.schemaVersion == 1)
        let reopened = try f.catalog(reviewed: [])
        #expect(try reopened.identities() == [.official, identity])
        #expect(try reopened.selection(for: identity)?.manifestSHA256 == digest)
        #expect(try reopened.importBundle(f.source) == identity)
        #expect(try PrivateFiles.read(catalog.receiptURL(digest)) == receiptData)
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
    }
    @Test("invalid candidates cannot write a local import receipt or become selectable")
    func invalidLocalImport() throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        try Data("changed provisioning".utf8).write(to: f.source.appendingPathComponent("provisioning.json"))
        #expect(throws: VMFailure.self) { try catalog.importBundle(f.source) }
        #expect(!FileManager.default.fileExists(atPath: catalog.directory.path))
        #expect(!FileManager.default.fileExists(atPath: catalog.receiptURL(digest).path))
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
    }
    @Test("local receipts reject tampering, other runtimes and unsafe files", arguments: ["schema", "runtime", "identity", "permissions", "symlink", "missing"])
    func localReceiptDamage(_ mode: String) throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        _ = try catalog.importBundle(f.source)
        let url = catalog.receiptURL(digest)
        if mode == "missing" {
            try FileManager.default.removeItem(at: url)
        } else if mode == "permissions" {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        } else if mode == "symlink" {
            let outside = f.files.support.appendingPathComponent("outside-receipt")
            try FileManager.default.moveItem(at: url, to: outside)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        } else {
            var value = try JSONSerialization.jsonObject(with: PrivateFiles.read(url)) as! [String: Any]
            if mode == "schema" { value["schemaVersion"] = 2 }
            if mode == "runtime" { value["runtimeLockSHA256"] = String(repeating: "a", count: 64) }
            if mode == "identity" {
                var factory = value["factory"] as! [String: Any]
                factory["diskSHA256"] = String(repeating: "a", count: 64); value["factory"] = factory
            }
            try PrivateFiles.write(JSONSerialization.data(withJSONObject: value), name: url.lastPathComponent, in: catalog.receipts)
        }
        #expect(throws: (any Error).self) { try catalog.identity(for: digest) }
        let listing = try catalog.listing()
        #expect(listing.factories == [.official] && listing.issues.map(\.selector) == [digest])
        if mode != "missing" {
            let damaged = try Data(contentsOf: url)
            #expect(throws: (any Error).self) { try catalog.importBundle(f.source) }
            #expect(try Data(contentsOf: url) == damaged)
        } else {
            #expect(try catalog.importBundle(f.source).manifestSHA256 == digest)
        }
    }
    @Test("the shared file hasher observes cancellation before scanning payloads")
    func cancellableHasher() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let payload = f.source.appendingPathComponent("test.img.zst")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try VMFactorySelection.digest(payload)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test("cancelled verification and copy publish no factory or receipt", arguments: [FactoryImportProgress.verifying, .copying, .checkingCopy])
    func cancelImport(_ phase: FactoryImportProgress) async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        let original = try KitVerifier.inventory(at: f.source)
        let source = f.source
        let task = Task.detached {
            try catalog.importBundle(source) { progress in
                if progress == phase { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: catalog.root(digest).path))
        #expect(!FileManager.default.fileExists(atPath: catalog.receiptURL(digest).path))
        #expect(try KitVerifier.inventory(at: f.source) == original)
        #expect(try catalog.identities() == [.official])
        if FileManager.default.fileExists(atPath: catalog.directory.path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: catalog.directory.path).isEmpty)
        }
    }
    @Test("reviewed imports are copied, verified, idempotent and selectable alongside official")
    func imports() throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
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
    @Test("incompatible image, runtime, package and provisioning are refused", arguments: ["architecture", "boot", "customFactoryVersion", "managedSSHVersion", "managedSetupVersion", "ownerSetupReportVersion", "integrationPackageSHA256", "ownerSetupContractSHA256", "provisioning", "runtimeFiles"])
    func incompatible(_ key: String) throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        switch key {
        case "architecture": f.manifest[key] = "x86_64"
        case "boot": f.manifest[key] = "bios"
        case "customFactoryVersion", "managedSSHVersion", "managedSetupVersion", "ownerSetupReportVersion": f.manifest[key] = 2
        case "provisioning": f.manifest[key] = ["provisioning.json": String(repeating: "a", count: 64)]
        case "runtimeFiles":
            var inventory = f.lock.files; inventory["Contents/Resources/runtime/bin/Try Omarchy"] = String(repeating: "a", count: 64); f.manifest[key] = inventory
        default: f.manifest[key] = String(repeating: "a", count: 64)
        }
        _ = try f.write()
        let catalog = try f.catalog(reviewed: [])
        #expect(throws: (any Error).self) { try catalog.importBundle(f.source) }
    }
    @Test("extra files, traversal, symlinks and changed image/provisioning hashes fail closed", arguments: ["extra", "symlink", "traversal", "image", "recipe"])
    func unsafe(_ kind: String) throws {
        var f = try FactoryFixture(); defer { f.cleanup() }
        if kind == "traversal" {
            var inventory = f.manifest["files"] as! [String: String]; inventory["../escape"] = String(repeating: "a", count: 64); f.manifest["files"] = inventory
        }
        _ = try f.write()
        let catalog = try f.catalog(reviewed: [])
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
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        #expect(throws: (any Error).self) { try catalog.importBundle(f.source) }
        var lock = f.lock; lock.customFactoryVersion = nil
        let unsupported = FactoryCatalog(applicationSupport: f.files.support, kit: f.kit.kit, lockData: try JSONEncoder().encode(lock), reviewed: [digest])
        #expect(throws: VMFailure.self) { try unsupported.importBundle(f.source) }
    }
    @Test("capacity checks reject metadata changed after identity verification", arguments: ["image", "descriptor", "identity"])
    func capacityMetadata(_ mode: String) throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        var identity = try catalog.importBundle(f.source)
        try catalog.validateCapacity(identity, diskGiB: 64)
        if mode == "identity" {
            identity = FactoryIdentity(kind: .custom, name: identity.name, manifestSHA256: digest, diskSHA256: String(repeating: "a", count: 64))
        } else {
            let file = catalog.root(digest).appendingPathComponent(mode == "image" ? "factory.json" : "reviewed-factory.json")
            var data = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            if mode == "image" {
                var disk = data["disk"] as! [String: Any]; disk["bytes"] = 1; data["disk"] = disk
            } else { data["name"] = "Changed metadata" }
            try JSONSerialization.data(withJSONObject: data).write(to: file)
        }
        #expect(throws: VMFailure.self) { try catalog.validateCapacity(identity, diskGiB: 64) }
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
        let digest = try f.write(), catalog = try f.catalog(reviewed: []), identity = try catalog.importBundle(f.source)
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

final class FactoryImportGate: @unchecked Sendable {
    private let pauseAt: FactoryImportProgress
    init(pauseAt: FactoryImportProgress = .copying) { self.pauseAt = pauseAt }
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var opened = false
    private var cancelled = false
    var isBlocked: Bool { lock.withLock { entered && !opened } }
    var cancellationRequested: Bool { lock.withLock { cancelled } }
    func report(_ progress: FactoryImportProgress) {
        if progress == .cancelling { lock.withLock { cancelled = true }; return }
        guard progress == pauseAt else { return }
        lock.withLock { entered = true }
        semaphore.wait()
    }
    func release() {
        let signal = lock.withLock { if opened { return false }; opened = true; return true }
        if signal { semaphore.signal() }
    }
}

@Suite("Local factory import through the manager — no VMs")
struct LocalFactoryManagerTests {
    @Test("quit waits for import cancellation or final publication", arguments: ["cancel", "shutdown", "saving"])
    func quitDuringImport(_ mode: String) async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: []), source = f.source
        let registry = try RegistryStore(applicationSupport: f.files.support); _ = try registry.load()
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [], applicationSupport: f.files.support, registry: registry)
        await manager.installFactoryCatalog(catalog)
        let gate = FactoryImportGate(pauseAt: mode == "saving" ? .saving : .copying)
        let fallback = Task.detached {
            do { try await Task.sleep(for: .seconds(5)); gate.release() } catch { }
        }
        defer { gate.release(); fallback.cancel() }
        let imported = Task { try await manager.importFactory(source) { gate.report($0) } }
        #expect(await eventually { gate.isBlocked })
        #expect(await manager.isImportingFactory)
        #expect(await manager.isIdle == false)
        #expect(await manager.prepareToQuitIfIdle() == false)
        let cancelled: Task<Void, Never>?
        if mode == "shutdown" {
            #expect(await manager.beginApplicationShutdown() == false)
            cancelled = nil
        } else { cancelled = Task { await manager.cancelFactoryImportAndWait() } }
        #expect(await eventually { gate.cancellationRequested })
        #expect(await manager.isIdle == false)
        gate.release()
        if mode == "saving" {
            let identity = try await imported.value
            #expect(try catalog.identity(for: digest) == identity)
            #expect(FileManager.default.fileExists(atPath: catalog.receiptURL(digest).path))
        } else {
            await #expect(throws: CancellationError.self) { try await imported.value }
            #expect(!FileManager.default.fileExists(atPath: catalog.receiptURL(digest).path))
        }
        await cancelled?.value
        #expect(await eventually { await manager.isIdle })
        #expect(runtime.startedHandles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
    }
    @Test("an already cancelled caller cannot start an import worker")
    func cancelledCaller() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        _ = try f.write(); let catalog = try f.catalog(reviewed: []), source = f.source
        let registry = try RegistryStore(applicationSupport: f.files.support); _ = try registry.load()
        let manager = VMManager(runtime: FakeRuntime(), profiles: [], applicationSupport: f.files.support, registry: registry)
        await manager.installFactoryCatalog(catalog)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await manager.importFactory(source)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await manager.isIdle)
        #expect(!FileManager.default.fileExists(atPath: catalog.directory.path))
    }
    @Test("the command import is available after reopening without compiled approval or storage creation")
    func commandImport() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: [])
        let registry = try RegistryStore(applicationSupport: f.files.support); _ = try registry.load()
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [], applicationSupport: f.files.support,
                                hostMemoryMiB: 32768, logicalCPUs: 8, registry: registry)
        await manager.installFactoryCatalog(catalog)
        let service = GuestCommandService(manager: manager, applicationSupport: f.files.support)
        let response = await service.execute(GuestCommandRequest(command: .importFactory, selector: f.source.path))
        #expect(response.ok && response.factories?.first?.manifestSHA256 == digest)
        await manager.installFactoryCatalog(try f.catalog(reviewed: []))
        let listing = await service.execute(GuestCommandRequest(command: .factories))
        #expect(listing.ok && listing.factories?.count == 2 && listing.factoryIssues == nil)
        let created = await service.execute(GuestCommandRequest(command: .create, config: GuestConfigurationPatch(name: "Imported fixture", ssh: false, ownerDefaults: false, factory: digest)))
        #expect(created.ok && created.guest?.factory?.manifestSHA256 == digest)
        #expect(runtime.startedHandles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
    }
    @Test("manager cancellation stops the import and releases its busy guard for retry")
    func cancellationPropagation() async throws {
        let f = try FactoryFixture(); defer { f.cleanup() }
        let digest = try f.write(), catalog = try f.catalog(reviewed: []), source = f.source
        let registry = try RegistryStore(applicationSupport: f.files.support); _ = try registry.load()
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [], applicationSupport: f.files.support, registry: registry)
        await manager.installFactoryCatalog(catalog)
        let gate = FactoryImportGate()
        let fallback = Task.detached {
            do { try await Task.sleep(for: .seconds(5)); gate.release() } catch { }
        }
        defer { gate.release(); fallback.cancel() }
        let operation = Task { try await manager.importFactory(source) { gate.report($0) } }
        #expect(await eventually { gate.isBlocked })
        operation.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(!FileManager.default.fileExists(atPath: catalog.receiptURL(digest).path))
        #expect(try await manager.importFactory(source).manifestSHA256 == digest)
        #expect(runtime.startedHandles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.files.storage.vms.path))
    }
}
