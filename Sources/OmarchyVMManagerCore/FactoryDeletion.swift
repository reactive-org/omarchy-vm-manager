import Darwin
import Foundation
import TryOmarchyKitClient

public protocol FactoryTrashService: Sendable {
    func moveToTrash(_ directory: URL) async throws
}

public struct SystemFactoryTrashService: FactoryTrashService {
    public init() {}
    public func moveToTrash(_ directory: URL) async throws {
        try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
    }
}

struct FactoryDeletionStamp: Equatable, Sendable {
    let rootID: String
    let rootStamp: String
    let files: [String: String]
    let receipt: Data?
}

struct FactoryDeletionReview: Sendable {
    let factory: FactoryIdentity
    let stamp: FactoryDeletionStamp
}

enum FactoryReferencePolicy {
    static func requireUnused(_ digest: String, profiles: [VMProfile], pendingCreations: Int) throws {
        let count = profiles.filter { $0.factory?.manifestSHA256 == digest }.count
        guard count == 0, pendingCreations == 0 else {
            throw VMFailure(code: "factory-in-use", message: "This factory is referenced by an existing guest or a guest being created. Keep it while those profiles exist.")
        }
    }
}

extension FactoryCatalog {
    static func validateDeletionSelector(_ selector: String) throws {
        guard selector != "official", selector != FactoryIdentity.official.manifestSHA256 else {
            throw VMFailure(code: "factory-protected", message: "The built-in Offical Try Omarchy factory cannot be deleted.")
        }
        guard VMFactorySelection.isDigest(selector) else {
            throw VMFailure(code: "factory-selector-invalid", message: "Use the imported manifest SHA-256 reported by factories.")
        }
    }

    func deletionReview(_ digest: String) throws -> FactoryDeletionReview {
        try Self.validateDeletionSelector(digest)
        guard PrivateFiles.exists(directory) else { throw VMFailure(code: "unknown-factory", message: "No imported factory matches this manifest SHA-256.") }
        try PrivateFiles.directory(directory)
        guard PrivateFiles.exists(root(digest)) else { throw VMFailure(code: "unknown-factory", message: "No imported factory matches this manifest SHA-256.") }
        let before = try deletionStamp(bundle: root(digest), receipt: receiptURL(digest))
        let factory = try identity(for: digest)
        let after = try deletionStamp(bundle: root(digest), receipt: receiptURL(digest))
        guard factory.kind == .custom, before == after else { throw changedFactory() }
        return FactoryDeletionReview(factory: factory, stamp: after)
    }

    func trash(_ review: FactoryDeletionReview, service: any FactoryTrashService,
               beforeTrash: @Sendable () throws -> Void) async throws -> FactoryIdentity {
        let digest = review.factory.manifestSHA256
        try Self.validateDeletionSelector(digest)
        try PrivateFiles.directory(directory)
        guard try deletionStamp(bundle: root(digest), receipt: receiptURL(digest)) == review.stamp else { throw changedFactory() }
        try beforeTrash()
        let transaction = directory.appendingPathComponent("Omarchy Factory " + digest + "-" + UUID().uuidString)
        try PrivateFiles.directory(transaction, create: true)
        let bundle = transaction.appendingPathComponent("Factory.bundle")
        let receipt = transaction.appendingPathComponent("Import receipt.json")
        let marker = "Factory deletion.json"
        var bundleMoved = false, receiptMoved = false
        do {
            struct Record: Encodable { let schemaVersion = 1; let factory: FactoryIdentity; let includesReceipt: Bool }
            try PrivateFiles.write(JSONEncoder().encode(Record(factory: review.factory, includesReceipt: review.stamp.receipt != nil)), name: marker, in: transaction, exclusively: true)
            try FileManager.default.moveItem(at: root(digest), to: bundle)
            bundleMoved = true
            if review.stamp.receipt != nil {
                try FileManager.default.moveItem(at: receiptURL(digest), to: receipt)
                receiptMoved = true
            }
            let staged = try deletionStamp(bundle: bundle, receipt: receipt)
            guard staged.rootID == review.stamp.rootID, staged.files == review.stamp.files, staged.receipt == review.stamp.receipt else { throw changedFactory() }
            try Self.flushDirectory(transaction)
            try Self.flushDirectory(directory)
            if receiptMoved { try Self.flushDirectory(receipts) }
            try beforeTrash()
            do { try await service.moveToTrash(transaction) }
            catch { throw VMFailure(code: "factory-trash-failed", message: "The factory could not be moved to Trash. Its library entry was restored.") }
            guard !PrivateFiles.exists(transaction) else { throw VMFailure(code: "factory-trash-failed", message: "Trash did not move the selected factory.") }
            try Self.flushDirectory(directory)
            return review.factory
        } catch {
            guard PrivateFiles.exists(transaction) else {
                throw VMFailure(code: "factory-delete-outcome-unknown", message: "The Trash operation could not be confirmed. Inspect Trash before retrying; no factory files were erased.")
            }
            do {
                if bundleMoved {
                    guard !PrivateFiles.exists(root(digest)) else { throw changedFactory() }
                    try FileManager.default.moveItem(at: bundle, to: root(digest))
                }
                if receiptMoved {
                    guard !PrivateFiles.exists(receiptURL(digest)) else { throw changedFactory() }
                    try FileManager.default.moveItem(at: receipt, to: receiptURL(digest))
                }
                let leftovers = Set(try FileManager.default.contentsOfDirectory(atPath: transaction.path))
                guard leftovers.isSubset(of: [marker]) else { throw changedFactory() }
                if leftovers.contains(marker) {
                    guard unlink(transaction.appendingPathComponent(marker).path) == 0 else { throw changedFactory() }
                }
                guard rmdir(transaction.path) == 0 else { throw changedFactory() }
                try Self.flushDirectory(directory)
                if receiptMoved { try Self.flushDirectory(receipts) }
            } catch {
                throw VMFailure(code: "factory-delete-recovery-required", message: "Factory deletion could not finish or restore its original paths. The recovery folder was preserved in the factory library; review it manually.")
            }
            if let failure = error as? VMFailure { throw failure }
            throw VMFailure(code: "factory-trash-failed", message: "The factory could not be moved to Trash. Its library entry was restored.")
        }
    }

    private func changedFactory() -> VMFailure {
        VMFailure(code: "factory-changed", message: "The factory changed during deletion review. Its files were preserved.")
    }
    private func deletionStamp(bundle: URL, receipt: URL) throws -> FactoryDeletionStamp {
        try PrivateFiles.directory(bundle)
        var rootInfo = stat()
        var parentInfo = stat()
        guard lstat(bundle.path, &rootInfo) == 0, lstat(bundle.deletingLastPathComponent().path, &parentInfo) == 0,
              rootInfo.st_dev == parentInfo.st_dev else { throw changedFactory() }
        var files: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: bundle.path) {
            guard VMFactoryManifest.safeName(name) else { throw changedFactory() }
            var info = stat()
            guard lstat(bundle.appendingPathComponent(name).path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_mode & 0o7777 == 0o600 else { throw changedFactory() }
            files[name] = Self.entryStamp(info)
        }
        let receiptData: Data?
        if PrivateFiles.exists(receipt) {
            try PrivateFiles.directory(receipt.deletingLastPathComponent())
            receiptData = try PrivateFiles.read(receipt)
        } else { receiptData = nil }
        return FactoryDeletionStamp(rootID: "\(rootInfo.st_dev):\(rootInfo.st_ino)", rootStamp: Self.entryStamp(rootInfo), files: files, receipt: receiptData)
    }
    private static func entryStamp(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
}
