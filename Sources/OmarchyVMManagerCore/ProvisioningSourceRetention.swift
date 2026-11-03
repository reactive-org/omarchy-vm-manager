import Darwin
import DevVMProvisioningCore
import Foundation

/// Retain partial/orphaned private rebind trees; refuse admission at the quota.
/// This is metadata accounting, never an ownership proof or deletion policy.
enum ProvisioningSourceRetention {
    static func admit(_ archive: FrozenInputsArchive, into root: URL, additionalBytes: Int = 0, additionalEntries: Int = 0) throws {
        guard (0...(PlainDataParser.maximumBytes + 256 * 1024)).contains(additionalBytes), (0...2).contains(additionalEntries) else { throw ProvisioningJobFailure.artifactUnavailable }
        try PrivateFiles.directory(root)
        let trees = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard trees.count < 128 else { throw ProvisioningJobFailure.artifactUnavailable }
        var bytes = archive.filePaths.reduce(Int64(additionalBytes)) { $0 + Int64(archive.data(for: $1)?.count ?? 0) }
        var entries = archive.filePaths.count + archive.directoryPaths.count + additionalEntries
        var pending = trees.map { ($0, 0) }
        while let (url, depth) = pending.popLast() {
            entries += 1
            var info = stat()
            guard entries <= 16384, depth < 64, lstat(url.path, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & 0o022 == 0, bytes <= 256 * 1024 * 1024 else { throw ProvisioningJobFailure.artifactUnavailable }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                pending += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).map { ($0, depth + 1) }
            case S_IFREG:
                guard info.st_nlink == 1, info.st_size >= 0 else { throw ProvisioningJobFailure.artifactUnavailable }
                bytes += info.st_size
            default: throw ProvisioningJobFailure.artifactUnavailable
            }
        }
        guard entries <= 16384, bytes <= 256 * 1024 * 1024 else { throw ProvisioningJobFailure.artifactUnavailable }
        try PrivateFiles.directory(root)
    }
}
