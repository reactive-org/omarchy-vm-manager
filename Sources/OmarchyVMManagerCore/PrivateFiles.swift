import Darwin
import Foundation

public enum PrivateFiles {
    static func failure(_ message: String) -> VMFailure { VMFailure(code: "unsafe-storage", message: message) }

    public static func directory(_ url: URL, create: Bool = false) throws {
        if create, mkdir(url.path, 0o700) != 0, errno != EEXIST { throw failure("Cannot create \(url.lastPathComponent).") }
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR,
              s.st_uid == getuid(), s.st_mode & 0o7777 == 0o700,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else {
            throw failure("\(url.lastPathComponent) must be an owned, private directory without symbolic links.")
        }
    }

    static func exists(_ url: URL) -> Bool {
        var s = stat()
        return lstat(url.path, &s) == 0 || errno != ENOENT
    }

    public static func read(_ url: URL, maximum: Int = 65_536) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Cannot safely read \(url.lastPathComponent).") }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(),
              s.st_mode & 0o7777 == 0o600, s.st_nlink == 1, s.st_size <= maximum else {
            throw failure("\(url.lastPathComponent) has unsafe permissions, ownership, type or size.")
        }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw failure("\(url.lastPathComponent) is too large.") }
        return data
    }

    static func write(_ data: Data, name: String, in directory: URL, exclusively: Bool = false) throws {
        try Self.directory(directory)
        let target = directory.appendingPathComponent(name)
        if exclusively, exists(target) { throw failure("\(name) already exists; it was preserved.") }
        if !exclusively, exists(target) { _ = try read(target, maximum: 1_048_576) }
        let temporary = directory.appendingPathComponent(".manager-write-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Cannot create private metadata.") }
        defer { close(fd); unlink(temporary.path) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0 else { throw failure("Cannot flush private metadata.") }
        if exclusively {
            guard link(temporary.path, target.path) == 0 else { throw failure("Cannot publish \(name); existing data was preserved.") }
            unlink(temporary.path)
        } else {
            guard rename(temporary.path, target.path) == 0 else { throw failure("Cannot replace \(name).") }
        }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw failure("Cannot flush metadata directory.") }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw failure("Cannot flush metadata directory.") }
    }
}

public final class RegistryStore: @unchecked Sendable {
    public let directory: URL
    private let lockFD: Int32
    private var revision: Data?
    private var loaded = false
    private var schemaVersion = 1
    private var cachedProfiles: [VMProfile] = []
    private var pending: Set<UUID> = []
    private let access = NSRecursiveLock()

    public init(applicationSupport: URL) throws {
        directory = applicationSupport.resolvingSymlinksInPath().appendingPathComponent("Omarchy VM Manager")
        try PrivateFiles.directory(directory, create: true)
        let lock = directory.appendingPathComponent(".manager.lock")
        let descriptor = open(lock.path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw VMFailure(code: "manager-already-open", message: "Another manager is open, or the manager lock is unsafe. Quit the other manager before retrying.") }
        var s = stat()
        guard fstat(descriptor, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1, s.st_mode & 0o7777 == 0o600 else {
            close(descriptor); throw PrivateFiles.failure("The manager lock is unsafe.")
        }
        lockFD = descriptor
    }

    deinit { close(lockFD) }
    private var file: URL { directory.appendingPathComponent("registry.json") }
    private struct Registry: Codable { let schemaVersion: Int; let profiles: [VMProfile]; let pendingDeletions: Set<UUID>? }
    public var pendingDeletions: Set<UUID> { access.withLock { pending } }

    func markDeletion(_ id: UUID) throws {
        try access.withLock {
            let before = pending
            pending.insert(id)
            do { try saveLocked(cachedProfiles) } catch { pending = before; throw error }
        }
    }

    func clearDeletion(_ id: UUID) throws {
        try access.withLock {
            let before = pending
            pending.remove(id)
            do { try saveLocked(cachedProfiles) } catch { pending = before; throw error }
        }
    }

    public func load() throws -> [VMProfile] { try access.withLock { try loadLocked() } }
    private func loadLocked() throws -> [VMProfile] {
        guard !loaded else { throw PrivateFiles.failure("The registry has already been loaded.") }
        if PrivateFiles.exists(file) {
            let data = try PrivateFiles.read(file, maximum: 1_048_576)
            let registry = try JSONDecoder().decode(Registry.self, from: data)
            guard (1...4).contains(registry.schemaVersion) else { throw PrivateFiles.failure("Unknown registry version. The original file was preserved.") }
            try Self.validate(registry.profiles)
            let pending = registry.pendingDeletions ?? []
            guard pending.isSubset(of: Set(registry.profiles.map(\.id))) else { throw PrivateFiles.failure("Invalid pending deletion metadata; the registry was preserved.") }
            self.pending = pending; cachedProfiles = registry.profiles; schemaVersion = registry.schemaVersion
            revision = data; loaded = true
            return registry.profiles
        }
        loaded = true
        let storage = ManagerStorage(applicationSupport: directory.deletingLastPathComponent())
        var retained: [VMProfile] = []
        for profile in POCProfiles.all where PrivateFiles.exists(storage.root(for: profile)) {
            try storage.validate(profile)
            retained.append(profile)
        }
        try save(retained)
        return retained
    }

    func checkRevision() throws {
        try access.withLock {
            try PrivateFiles.directory(directory)
            guard loaded, let revision, try PrivateFiles.read(file, maximum: 1_048_576) == revision else {
                throw PrivateFiles.failure("The registry changed outside the manager. It was preserved; quit and reopen to review it before launching.")
            }
        }
    }

    public func save(_ profiles: [VMProfile]) throws { try access.withLock { try saveLocked(profiles) } }
    private func saveLocked(_ profiles: [VMProfile]) throws {
        guard loaded else { throw PrivateFiles.failure("Load the registry before changing it.") }
        try Self.validate(profiles)
        try PrivateFiles.directory(directory)
        if let revision {
            guard try PrivateFiles.read(file, maximum: 1_048_576) == revision else {
                throw PrivateFiles.failure("The registry changed outside the manager. It was preserved; quit and reopen to review it.")
            }
        } else if PrivateFiles.exists(file) { throw PrivateFiles.failure("A registry appeared during initialization. It was preserved.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let nextPending = pending.intersection(Set(profiles.map(\.id)))
        let nextSchema = max(schemaVersion, profiles.contains(where: { $0.diskGiB != nil }) ? 4 : (profiles.contains(where: { $0.ownerSetup != nil }) ? 3 : (profiles.contains(where: { $0.ssh != nil }) ? 2 : 1)))
        let data = try encoder.encode(Registry(schemaVersion: nextSchema, profiles: profiles, pendingDeletions: nextPending))
        guard data.count <= 1_048_576 else { throw PrivateFiles.failure("The registry is too large.") }
        try PrivateFiles.write(data, name: "registry.json", in: directory, exclusively: revision == nil)
        revision = data; cachedProfiles = profiles; pending = nextPending; schemaVersion = nextSchema
    }

    static func validate(_ profiles: [VMProfile]) throws {
        guard profiles.count <= 1000, Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map { $0.name.lowercased() }).count == profiles.count,
              Set(profiles.compactMap { $0.ssh?.hostPort }).count == profiles.compactMap({ $0.ssh?.hostPort }).count else {
            throw PrivateFiles.failure("The registry contains duplicate profiles or too many entries.")
        }
        for profile in profiles { try validate(profile) }
    }

    public static func validate(_ profile: VMProfile) throws {
        if let poc = POCProfiles.all.first(where: { $0.id == profile.id }) {
            guard profile.name == poc.name, profile.memoryMiB == poc.memoryMiB, profile.cpus == poc.cpus,
                  profile.diskGiB == nil, profile.clipboardEnabled == poc.clipboardEnabled, profile.immersiveMode == nil,
                  profile.settingsFingerprint == nil, profile.ssh == nil, profile.ownerSetup == nil, profile.factory == nil else {
                throw PrivateFiles.failure("Retained POC metadata is protected. Restore its original profile; its disk was preserved.")
            }
        }
        try profile.factory?.validate()
        try profile.ownerSetup?.validate(for: profile.id)
        if let ssh = profile.ssh {
            guard (1024...65535).contains(ssh.hostPort), ssh.publicKeyFingerprint == nil || ssh.publicKeyFingerprint!.range(of: "^SHA256:[A-Za-z0-9+/]{43}$", options: .regularExpression) != nil else {
                throw PrivateFiles.failure("Invalid managed SSH endpoint or public-key reference.")
            }
        }
        if let fingerprint = profile.settingsFingerprint {
            guard fingerprint.count == 64, fingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw PrivateFiles.failure("Invalid settings revision in the registry.") }
        }
        guard !profile.name.isEmpty, profile.name.count <= 64, profile.name.utf8.count <= 251,
              profile.name == profile.name.trimmingCharacters(in: .whitespacesAndNewlines),
              !profile.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !profile.name.contains("/"), profile.name != ".", profile.name != "..",
              (4096...1_048_576).contains(profile.memoryMiB), profile.memoryMiB % 1024 == 0,
              (4...1024).contains(profile.cpus), profile.diskGiB == nil || (64...8192).contains(profile.diskGiB!),
              profile.createdAt.timeIntervalSince1970.isFinite else {
            throw VMFailure(code: "invalid-profile", message: "Use a unique name of 1–64 characters without slashes, at least 4 GiB memory, at least four CPU cores and a disk capacity from 64 to 8192 GiB.")
        }
    }
}
