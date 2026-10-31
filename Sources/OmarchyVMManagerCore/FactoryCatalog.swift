import Darwin
import Foundation
import TryOmarchyKitClient

public struct FactoryIdentity: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case official, custom }
    public let kind: Kind
    public let name: String
    public let manifestSHA256: String
    public let diskSHA256: String
    public static let official = FactoryIdentity(kind: .official, name: "Offical Try Omarchy", manifestSHA256: "1c202c4d9c4087b87d40138d812835a765ff736ff7cf1b9dc233b4fa8945a8cf", diskSHA256: "f587d246981b14f1b0537d75ac1be03219368ac78aaefdb98b8e75a8f9a890c3")
    public var displayName: String { kind == .official ? Self.official.name : name }
    public var selector: String { kind == .official ? "official" : manifestSHA256 }
    public func validate() throws {
        guard VMFactorySelection.isDigest(manifestSHA256), VMFactorySelection.isDigest(diskSHA256),
              !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              kind != .official || (manifestSHA256 == Self.official.manifestSHA256 && diskSHA256 == Self.official.diskSHA256
                  && [Self.official.name, "Official Omarchy"].contains(name)) else { throw FactoryCatalog.invalid("Invalid recorded factory identity.") }
    }
}

public struct FactoryCatalogIssue: Codable, Equatable, Sendable {
    public let selector: String
    public let message: String
}

public struct FactoryCatalogListing: Sendable {
    public let factories: [FactoryIdentity]
    public let issues: [FactoryCatalogIssue]
}

public enum FactoryImportProgress: String, Sendable {
    case verifying = "Verifying factory…"
    case copying = "Copying factory…"
    case checkingCopy = "Checking imported copy…"
    case saving = "Saving verified factory…"
    case cancelling = "Cancelling import…"
}

struct FactoryImportReceipt: Codable, Equatable {
    let schemaVersion: Int
    let factory: FactoryIdentity
    let runtimeLockSHA256: String
    let importedAt: Date
}

public struct FactoryCatalog: Sendable {
    let applicationSupport: URL
    let kit: TryOmarchyKit
    let lockData: Data
    let reviewed: Set<String>
    public init(applicationSupport: URL, kit: TryOmarchyKit, lockData: Data) throws {
        #if DEBUG
        let policy = KitBuildPolicy.debugPOC
        #else
        let policy = KitBuildPolicy.release
        #endif
        _ = try KitVerifier.inspect(kit: kit, lockData: lockData, expectedLockSHA256: RuntimePin.lockSHA256, policy: policy, preflight: { nil })
        let signature = Process()
        signature.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signature.arguments = ["--verify", "--deep", "--strict", kit.bundleURL.path]
        signature.standardInput = FileHandle.nullDevice; signature.standardOutput = FileHandle.nullDevice; signature.standardError = FileHandle.nullDevice
        try signature.run(); signature.waitUntilExit()
        guard signature.terminationStatus == 0 else { throw Self.invalid("The embedded kit failed normal signature verification.") }
        let url = Bundle.module.url(forResource: "ReviewedFactories", withExtension: "json")!
        self.init(applicationSupport: applicationSupport, kit: kit, lockData: lockData,
                  reviewed: try Self.decodeReviews(VMFactorySelection.readMetadata(url), expectedSHA256: FactoryReviewPin.sha256))
    }
    init(applicationSupport: URL, kit: TryOmarchyKit, lockData: Data, reviewed: Set<String>) {
        self.applicationSupport = applicationSupport; self.kit = kit; self.lockData = lockData; self.reviewed = reviewed
    }
    static func decodeReviews(_ data: Data, expectedSHA256: String) throws -> Set<String> {
        guard data.count <= 65536, KitVerifier.sha256(data) == expectedSHA256 else { throw invalid("The factory review catalog differs from the compiled pin.") }
        let values = try JSONDecoder().decode([String].self, from: data)
        guard values.count <= 1000, Set(values).count == values.count, values.allSatisfy(VMFactorySelection.isDigest) else { throw invalid("The factory review catalog contains invalid or duplicate manifest pins.") }
        return Set(values)
    }
    var directory: URL { ManagerStorage(applicationSupport: applicationSupport).directory.appendingPathComponent("Factories") }
    func root(_ digest: String) -> URL { directory.appendingPathComponent(digest) }
    var receipts: URL { directory.appendingPathComponent(".receipts") }
    func receiptURL(_ digest: String) -> URL { receipts.appendingPathComponent(digest + ".json") }
    private func receipt(for digest: String) throws -> FactoryImportReceipt? {
        guard PrivateFiles.exists(receipts) else { return nil }
        try PrivateFiles.directory(directory); try PrivateFiles.directory(receipts)
        let url = receiptURL(digest)
        guard PrivateFiles.exists(url) else { return nil }
        let receipt = try JSONDecoder().decode(FactoryImportReceipt.self, from: PrivateFiles.read(url))
        try receipt.factory.validate()
        guard receipt.schemaVersion == 1, receipt.factory.kind == .custom, receipt.factory.manifestSHA256 == digest,
              receipt.runtimeLockSHA256 == KitVerifier.sha256(lockData), receipt.importedAt.timeIntervalSince1970.isFinite else {
            throw Self.invalid("This factory’s import record is damaged or belongs to a different runtime.")
        }
        return receipt
    }
    private func recordImport(_ factory: FactoryIdentity) throws {
        try PrivateFiles.directory(receipts, create: true)
        try Self.flushDirectory(directory)
        if let existing = try receipt(for: factory.manifestSHA256) {
            guard existing.factory == factory else { throw Self.invalid("The imported factory differs from its saved identity.") }
            return
        }
        let receipt = FactoryImportReceipt(schemaVersion: 1, factory: factory, runtimeLockSHA256: KitVerifier.sha256(lockData), importedAt: Date())
        try PrivateFiles.write(JSONEncoder().encode(receipt), name: receiptURL(factory.manifestSHA256).lastPathComponent, in: receipts, exclusively: true)
    }
    static func invalid(_ message: String) -> VMFailure { VMFailure(code: "factory-verification-failed", message: message) }

    func verify(_ url: URL, digest: String) throws -> FactoryIdentity {
        let receipt = try receipt(for: digest)
        guard reviewed.contains(digest) || receipt != nil else { throw Self.invalid("Import this prepared factory through Import Factory before selecting it.") }
        let identity = try verifyCandidate(url, digest: digest)
        if let receipt, receipt.factory != identity { throw Self.invalid("The imported factory differs from its saved identity.") }
        return identity
    }

    private func verifyCandidate(_ url: URL, digest: String) throws -> FactoryIdentity {
        try Task.checkCancellation()
        let lock = try JSONDecoder().decode(RuntimeProvenance.self, from: lockData)
        guard lock.customFactoryVersion == 1, lock.managedSSHVersion == 1, lock.managedSetupVersion == 1 else { throw Self.invalid("The runtime lacks the reviewed custom-factory and provisioning capabilities.") }
        let selection = VMFactorySelection(bundlePath: url.path, manifestSHA256: digest)
        let manifest: VMFactoryManifest
        do { manifest = try selection.verified(runtimeBundle: kit.bundleURL) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Self.invalid("The factory payload, image metadata or runtime hashes failed verification.") }
        try Task.checkCancellation()
        let contract = Bundle.module.url(forResource: "OwnerSetupContract", withExtension: "json")!
        guard manifest.runtimeFiles == lock.files,
              manifest.integrationPackageSHA256 == lock.files[VMFactorySelection.packagePath],
              manifest.ownerSetupContractSHA256 == (try VMFactorySelection.digest(contract)) else { throw Self.invalid("Factory runtime, integration package or provisioning contract provenance differs from this kit.") }
        let image = try Self.decodeImage(VMFactorySelection.readMetadata(url.appendingPathComponent("factory.json")), expectedSHA256: manifest.files["factory.json"])
        return FactoryIdentity(kind: .custom, name: manifest.name, manifestSHA256: digest, diskSHA256: image.disk.sha256)
    }

    static func decodeImage(_ data: Data, expectedSHA256: String?) throws -> VMFactoryManifest.Image {
        guard let expectedSHA256, KitVerifier.sha256(data) == expectedSHA256 else { throw invalid("Factory image metadata changed after verification.") }
        return try JSONDecoder().decode(VMFactoryManifest.Image.self, from: data)
    }

    public func importBundle(_ source: URL, onProgress: @Sendable (FactoryImportProgress) -> Void = { _ in }) throws -> FactoryIdentity {
        try Task.checkCancellation()
        onProgress(.verifying)
        let descriptor: Data
        do { descriptor = try VMFactorySelection.readMetadata(source.appendingPathComponent("reviewed-factory.json")) }
        catch { throw Self.invalid("Choose a prepared factory bundle with a readable reviewed-factory.json manifest.") }
        let digest = KitVerifier.sha256(descriptor)
        let identity = try verifyCandidate(source, digest: digest)
        try PrivateFiles.directory(ManagerStorage(applicationSupport: applicationSupport).directory)
        try PrivateFiles.directory(directory, create: true)
        let destination = root(digest)
        if PrivateFiles.exists(destination) {
            try PrivateFiles.directory(destination)
            guard try verifyCandidate(destination, digest: digest) == identity else { throw Self.invalid("The imported factory identity changed.") }
            try Task.checkCancellation()
            onProgress(.saving)
            try recordImport(identity)
            return identity
        }
        let stage = directory.appendingPathComponent(".import-" + UUID().uuidString)
        try PrivateFiles.directory(stage, create: true)
        defer {
            if let entries = try? FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil) {
                for file in entries { try? FileManager.default.removeItem(at: file) }
            }
            try? FileManager.default.removeItem(at: stage)
        }
        onProgress(.copying)
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            try Task.checkCancellation()
            let target = stage.appendingPathComponent(name)
            try Self.copyPayload(source.appendingPathComponent(name), to: target)
        }
        onProgress(.checkingCopy)
        guard try verifyCandidate(stage, digest: digest) == identity else { throw Self.invalid("Factory changed while importing. The source was preserved.") }
        try Task.checkCancellation()
        onProgress(.saving)
        try FileManager.default.moveItem(at: stage, to: destination)
        try Self.flushDirectory(directory)
        try recordImport(identity)
        return identity
    }
    static func flushDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw invalid("Cannot flush factory metadata.") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw invalid("Cannot flush factory metadata.") }
    }
    private static func copyPayload(_ source: URL, to target: URL) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw invalid("Cannot safely read a factory payload.") }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw invalid("Factory payloads must be regular files.") }
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw invalid("Cannot create a private factory payload.") }
        defer { close(output) }
        let reader = FileHandle(fileDescriptor: input, closeOnDealloc: false)
        let writer = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        var remaining = info.st_size
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try reader.read(upToCount: Int(min(remaining, 1_048_576))) ?? Data()
            guard !data.isEmpty else { throw invalid("A factory payload changed while copying.") }
            try writer.write(contentsOf: data)
            remaining -= off_t(data.count)
        }
        let extra = try reader.read(upToCount: 1) ?? Data()
        var current = stat()
        guard extra.isEmpty, fstat(input, &current) == 0, current.st_size == info.st_size,
              current.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, current.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, current.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { throw invalid("A factory payload changed while copying.") }
        guard fsync(output) == 0 else { throw invalid("Cannot flush the imported factory payload.") }
    }
    public func listing() throws -> FactoryCatalogListing {
        guard PrivateFiles.exists(directory) else { return FactoryCatalogListing(factories: [.official], issues: []) }
        try PrivateFiles.directory(directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var factories: [FactoryIdentity] = [.official]
        var issues: [FactoryCatalogIssue] = []
        for digest in names.filter({ VMFactorySelection.isDigest($0) }).sorted() {
            do {
                try PrivateFiles.directory(root(digest))
                factories.append(try verify(root(digest), digest: digest))
            } catch {
                issues.append(FactoryCatalogIssue(selector: digest, message: "This imported factory or its import record failed verification and cannot be selected."))
            }
        }
        return FactoryCatalogListing(factories: factories, issues: issues)
    }
    public func identities() throws -> [FactoryIdentity] { try listing().factories }
    public func identity(for selector: String) throws -> FactoryIdentity {
        if selector == "official" { return .official }
        guard VMFactorySelection.isDigest(selector) else { throw Self.invalid("Select official or a reviewed imported manifest SHA-256.") }
        try PrivateFiles.directory(directory); try PrivateFiles.directory(root(selector))
        return try verify(root(selector), digest: selector)
    }
    public func validateCapacity(_ identity: FactoryIdentity, diskGiB: Int) throws {
        try identity.validate()
        guard identity.kind == .custom else { return }
        try PrivateFiles.directory(directory); try PrivateFiles.directory(root(identity.manifestSHA256))
        let descriptor = try VMFactorySelection.readMetadata(root(identity.manifestSHA256).appendingPathComponent("reviewed-factory.json"))
        guard KitVerifier.sha256(descriptor) == identity.manifestSHA256 else { throw Self.invalid("The factory descriptor differs from its recorded identity.") }
        let manifest = try JSONDecoder().decode(VMFactoryManifest.self, from: descriptor)
        try manifest.validate()
        let image = try Self.decodeImage(VMFactorySelection.readMetadata(root(identity.manifestSHA256).appendingPathComponent("factory.json")), expectedSHA256: manifest.files["factory.json"])
        guard image.disk.sha256 == identity.diskSHA256, image.disk.bytes > 0 else { throw Self.invalid("Factory image metadata differs from its recorded identity.") }
        guard (64...8192).contains(diskGiB), Int64(diskGiB) * 1_073_741_824 >= image.disk.bytes else { throw Self.invalid("Choose a disk capacity at least as large as the prepared factory disk.") }
    }
    public func selection(for identity: FactoryIdentity?) throws -> VMFactorySelection? {
        guard let identity else { return nil }
        try identity.validate()
        if identity.kind == .official {
            guard try VMFactorySelection.digest(kit.bundleURL.appendingPathComponent("Contents/Resources/guest/factory.json")) == identity.manifestSHA256 else { throw Self.invalid("The official factory differs from this profile’s recorded identity.") }
            return nil
        }
        guard try self.identity(for: identity.selector) == identity else { throw Self.invalid("The selected factory differs from this profile’s recorded identity.") }
        return VMFactorySelection(bundlePath: root(identity.manifestSHA256).path, manifestSHA256: identity.manifestSHA256)
    }
}
