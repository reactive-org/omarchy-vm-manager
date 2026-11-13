import Darwin
import DevVMProvisioningCore
import Foundation

/// Build-selected eligibility for ordinary Dev provisioning. This is not apply
/// consent, session evidence or permission to launch a guest. The trusted caller
/// supplies its own application-support base; no IPC or environment selects it.
struct ProvisioningDevelopmentAdmission: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let applicationSupport: URL
    var description: String { "ProvisioningDevelopmentAdmission(redacted)" }
    var debugDescription: String { description }

    /// The helper intentionally has an isolated HOME. Resolve the actual
    /// account home from the OS user database, never from its environment.
    static func accountApplicationSupport() throws -> URL {
        var count = 16 * 1024
        while count <= 1024 * 1024 {
            var account = passwd(), result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: count)
            let value: (Int32, String?) = buffer.withUnsafeMutableBufferPointer { bytes in
                let status = getpwuid_r(getuid(), &account, bytes.baseAddress!, bytes.count, &result)
                return (status, status == 0 && result != nil ? String(validatingCString: account.pw_dir) : nil)
            }
            if value.0 == ERANGE { count *= 2; continue }
            guard value.0 == 0, let home = value.1, home.hasPrefix("/") else { throw ProvisioningServiceFailure.unavailable }
            return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        throw ProvisioningServiceFailure.unavailable
    }

    func verify(vmID: UUID, root: URL) throws {
        guard AppChannel.current == .development else { throw ProvisioningServiceFailure.disabled }
        let storage = ManagerStorage(applicationSupport: applicationSupport, channel: .development)
        let expected = storage.vms.appendingPathComponent(vmID.uuidString)
        guard !POCProfiles.ids.contains(vmID), root.isFileURL,
              root.host == nil || root.host == "localhost",
              root.path == root.standardizedFileURL.path,
              root.lastPathComponent == vmID.uuidString,
              root.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path
        else { throw ProvisioningJobFailure.targetChanged }
        try PrivateFiles.directory(storage.directory)
        try PrivateFiles.directory(storage.vms)
        try PrivateFiles.directory(root)
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProvisioningJobFailure.targetChanged }
        defer { close(fd) }
        var held = stat(), path = stat()
        guard fstat(fd, &held) == 0 else { throw ProvisioningJobFailure.targetChanged }
        let marker = try transportFields(PlainDataParser.parse(PrivateFiles.read(root.appendingPathComponent(".omarchy-vm-manager.json")), format: .json), required: ["schemaVersion", "id"])
        guard marker["schemaVersion"] == .integer(1), marker["id"] == .string(vmID.uuidString),
              try PrivateFiles.read(root.appendingPathComponent(".omarchy-qemu-storage")) == Data("omarchy-qemu-storage-root-v1\n".utf8),
              lstat(root.path, &path) == 0, held.st_dev == path.st_dev, held.st_ino == path.st_ino,
              path.st_uid == getuid(), path.st_mode & S_IFMT == S_IFDIR, path.st_mode & 0o7777 == 0o700
        else { throw ProvisioningJobFailure.targetChanged }
    }
}
