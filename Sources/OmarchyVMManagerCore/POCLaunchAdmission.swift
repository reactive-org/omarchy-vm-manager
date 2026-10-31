import Darwin
import Foundation
import TryOmarchyKitClient

public struct POCStorage: Sendable {
    public let applicationSupport: URL
    public init(applicationSupport: URL) { self.applicationSupport = applicationSupport }

    public static let inheritedKeys: Set<String> = [
        "vmResourcePreferences", "memoryPreferences", "networkPreferences", "portForwardingPreferences",
        "sharedFolderPreferences", "usbDevicePreferences", "fullscreenPreferences"
    ]

    public func root(for profile: VMProfile) -> URL {
        POCProfiles.root(for: profile, applicationSupport: applicationSupport)
    }

    public func prepare(_ profile: VMProfile) throws -> URL {
        guard POCProfiles.all.contains(profile) else { throw failure("Only the two fixed disposable POC profiles are allowed.") }
        let manager = applicationSupport.appendingPathComponent("Omarchy VM Manager", isDirectory: true)
        let vms = manager.appendingPathComponent("VMs", isDirectory: true)
        try ensureDirectory(manager)
        try ensureDirectory(vms)
        let root = root(for: profile)
        if mkdir(root.path, 0o700) == 0 {
            let marker = try JSONEncoder().encode(Marker(schemaVersion: 1, id: profile.id))
            try createPrivate(marker, at: root.appendingPathComponent(".omarchy-vm-manager.json"))
            try createPrivate(Data("omarchy-qemu-storage-root-v1\n".utf8), at: root.appendingPathComponent(".omarchy-qemu-storage"))
            let settings: [String: Any] = ["schemaVersion": 1, "settings": Dictionary(uniqueKeysWithValues: Self.inheritedKeys.map { ($0, NSNull()) })]
            try createPrivate(JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]),
                              at: root.appendingPathComponent("settings.json"))
        } else if errno != EEXIST { throw failure("Cannot create the disposable VM root (errno \(errno)).") }
        try validate(profile)
        return root
    }

    public func validate(_ profile: VMProfile) throws {
        let root = root(for: profile)
        try validateDirectory(root.deletingLastPathComponent().deletingLastPathComponent())
        try validateDirectory(root.deletingLastPathComponent())
        try validateDirectory(root)
        let marker = try JSONDecoder().decode(Marker.self, from: readPrivate(root.appendingPathComponent(".omarchy-vm-manager.json")))
        guard marker.schemaVersion == 1, marker.id == profile.id else { throw failure("The VM ownership marker does not match this profile.") }
        guard try readPrivate(root.appendingPathComponent(".omarchy-qemu-storage")) == Data("omarchy-qemu-storage-root-v1\n".utf8) else {
            throw failure("The upstream storage marker is invalid.")
        }
        let data = try readPrivate(root.appendingPathComponent("settings.json"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "settings"],
              let settings = object["settings"] as? [String: Any], Set(settings.keys) == Self.inheritedKeys,
              settings.values.allSatisfy({ $0 is NSNull }) else {
            throw failure("This POC requires the initialized null resource, networking, sharing and device settings. Changed or unknown settings are refused without rewriting them.")
        }
        let schema = try JSONDecoder().decode(Schema.self, from: data)
        guard schema.schemaVersion == 1 else { throw failure("Unknown settings schema.") }
        for name in ["shell", "shell-factory"] {
            let directory = root.appendingPathComponent(name)
            var info = stat()
            if lstat(directory.path, &info) == 0 { try validateDirectory(directory) }
            else if errno != ENOENT { throw failure("Cannot inspect VM storage.") }
        }
    }

    private struct Marker: Codable { let schemaVersion: Int; let id: UUID }
    private struct Schema: Decodable { let schemaVersion: Int }

    private func ensureDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw failure("Cannot create the manager directory (errno \(errno)).") }
        try validateDirectory(url)
    }

    private func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw failure("A manager storage directory is missing, symlinked, unowned or not mode 0700: \(url.lastPathComponent)")
        }
    }

    private func readPrivate(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Cannot safely open \(url.lastPathComponent).") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size <= 65_536 else {
            throw failure("Unsafe ownership, type, size or permissions for \(url.lastPathComponent).")
        }
        let data = try file.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw failure("Storage metadata is too large.") }
        return data
    }

    private func createPrivate(_ data: Data, at url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Cannot exclusively create \(url.lastPathComponent).") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        guard fsync(fd) == 0 else { throw failure("Cannot flush VM metadata.") }
        try file.close()
    }

    private func failure(_ message: String) -> VMFailure { VMFailure(code: "poc-storage-unsafe", message: message) }
}

public struct POCLaunchAdmission: Sendable {
    public let kit: TryOmarchyKit
    public let lockData: Data
    public let storage: POCStorage

    public init(kit: TryOmarchyKit, lockData: Data, applicationSupport: URL) {
        self.kit = kit
        self.lockData = lockData
        storage = POCStorage(applicationSupport: applicationSupport)
    }

    public func admit(_ request: VMStartRequest) throws {
        #if !DEBUG
        throw VMFailure(code: "private-poc-only", message: "The development POC kit is refused by release builds.")
        #else
        guard POCProfiles.all.contains(request.profile),
              request.storageRoot.standardizedFileURL == storage.root(for: request.profile).standardizedFileURL else {
            throw VMFailure(code: "poc-root-refused", message: "Only the two fixed manager-owned disposable roots may launch.")
        }
        let diagnostic = try KitVerifier.inspect(kit: kit, lockData: lockData,
                                                 expectedLockSHA256: RuntimePin.lockSHA256, policy: .debugPOC)
        if let failure = diagnostic.preflightFailure { throw VMFailure(code: "host-preflight-failed", message: failure) }
        let signature = Process()
        signature.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signature.arguments = ["--verify", "--deep", "--strict", kit.bundleURL.path]
        signature.standardOutput = FileHandle.nullDevice
        signature.standardError = FileHandle.nullDevice
        try signature.run()
        signature.waitUntilExit()
        guard signature.terminationStatus == 0 else { throw VMFailure(code: "kit-signature-invalid", message: "The embedded kit signature is invalid.") }
        guard request.profile.cpus >= POCHostPolicy.minimumVMCPUs,
              request.profile.cpus <= ProcessInfo.processInfo.processorCount else {
            throw VMFailure(code: "unsupported-cpu-count", message: "The pinned runtime requires 4 through the host CPU count per VM.")
        }
        let required = TryOmarchyStorage.requiredFreeBytes(at: request.storageRoot) + 2_147_483_648
        guard let free = TryOmarchyStorage.freeBytes(at: request.storageRoot), free >= required else {
            throw VMFailure(code: "not-enough-space", message: "The VM requires \(required) free bytes including the manager margin.")
        }
        _ = try storage.prepare(request.profile)
        #endif
    }
}

public enum POCHostPolicy {
    public static let minimumVMCPUs = 4
    public static func validate(memoryMiB: Int, cpus: Int, physicalMemoryMiB: Int, logicalCPUs: Int) throws {
        let reserve = max(4096, physicalMemoryMiB / 4)
        guard memoryMiB <= physicalMemoryMiB - reserve else {
            throw VMFailure(code: "memory-budget-exceeded", message: "Requested \(memoryMiB) MiB exceeds the \(physicalMemoryMiB - reserve) MiB guest budget (\(reserve) MiB reserved for macOS).")
        }
        guard cpus <= 2 * logicalCPUs else { throw VMFailure(code: "cpu-budget-exceeded", message: "The POC exceeds twice the host CPU count.") }
    }
}
