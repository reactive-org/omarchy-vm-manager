import Darwin
import Foundation

public struct HomeDisk: Codable, Equatable, Sendable {
    public let id: UUID
    public var sizeGiB: Int
    public var sourceVMID: UUID?
    public init(id: UUID = UUID(), sizeGiB: Int = 64, sourceVMID: UUID? = nil) {
        self.id = id; self.sizeGiB = sizeGiB; self.sourceVMID = sourceVMID
    }
    public func validate(vmID: UUID) throws {
        guard (16...8192).contains(sizeGiB), sourceVMID != vmID else { throw Self.failure("Home disks must be 16–8192 GiB and cannot reuse themselves.") }
    }
    static func failure(_ message: String) -> VMFailure { VMFailure(code: "home-disk-unavailable", message: message) }
}

public struct DiskDefaults: Codable, Equatable, Sendable {
    public var systemDiskGiB = 64
    public var separateHome = true
    public var homeDiskGiB = 64
    public init(systemDiskGiB: Int = 64, separateHome: Bool = true, homeDiskGiB: Int = 64) {
        self.systemDiskGiB = systemDiskGiB; self.separateHome = separateHome; self.homeDiskGiB = homeDiskGiB
    }
    public func validate() throws {
        guard (64...8192).contains(systemDiskGiB), (16...8192).contains(homeDiskGiB) else {
            throw HomeDisk.failure("System disks must be 64–8192 GiB; home disks must be 16–8192 GiB.")
        }
    }
}

struct DiskDefaultsStore {
    let applicationSupport: URL
    private let channel: AppChannel
    init(applicationSupport: URL, channel: AppChannel = .current) { self.applicationSupport = applicationSupport; self.channel = channel }
    private var directory: URL { channel.directory(in: applicationSupport) }
    private struct Record: Codable { let schemaVersion: Int; let disks: DiskDefaults }
    func load() throws -> DiskDefaults {
        let path = directory.appendingPathComponent("disk-defaults.json")
        guard PrivateFiles.exists(path) else { return DiskDefaults() }
        let record = try JSONDecoder().decode(Record.self, from: PrivateFiles.read(path))
        guard record.schemaVersion == 1 else { throw HomeDisk.failure("Unsupported disk defaults. The file was preserved.") }
        try record.disks.validate(); return record.disks
    }
    func save(_ value: DiskDefaults) throws {
        try value.validate(); try PrivateFiles.directory(directory, create: true)
        if PrivateFiles.exists(directory.appendingPathComponent("disk-defaults.json")) { _ = try load() }
        try PrivateFiles.write(JSONEncoder().encode(Record(schemaVersion: 1, disks: value)), name: "disk-defaults.json", in: directory)
    }
}

extension ManagerStorage {
    private struct HomeDiskState: Codable {
        let schemaVersion: Int
        let id: UUID
        let device: Int64
        let inode: UInt64
        let sizeGiB: Int
    }
    private func recordHomeState(_ profile: VMProfile) throws {
        guard let home = profile.homeDisk else { return }
        var info = stat()
        guard lstat(homeImage(profile).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size % 1_073_741_824 == 0 else { throw HomeDisk.failure("Cannot record the home disk identity.") }
        let state = HomeDiskState(schemaVersion: 1, id: home.id, device: Int64(info.st_dev), inode: info.st_ino, sizeGiB: Int(info.st_size / 1_073_741_824))
        try PrivateFiles.write(JSONEncoder().encode(state), name: "state.json", in: homeDirectory(profile))
    }
    func prepareHome(_ profile: VMProfile, newRoot: Bool) throws {
        guard let home = profile.homeDisk else { return }
        try withLock(profile) {
            let image = homeImage(profile)
            if !PrivateFiles.exists(image) {
                guard newRoot, home.sourceVMID == nil else { throw HomeDisk.failure("The recorded home disk is missing. It will not be replaced with an empty disk.") }
                try PrivateFiles.directory(homeDirectory(profile), create: true)
                let fd = open(image.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw HomeDisk.failure("Cannot exclusively create the home disk.") }
                defer { close(fd) }
                let header = Data(("OMARCHY_HOME_BLANK_V1\n" + home.id.uuidString.lowercased() + "\n").utf8)
                guard ftruncate(fd, Int64(home.sizeGiB) * 1_073_741_824) == 0 else { throw HomeDisk.failure("Cannot size the sparse home disk.") }
                try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: header)
                guard fsync(fd) == 0 else { throw HomeDisk.failure("Cannot flush the home disk.") }
                try recordHomeState(profile)
            } else {
                try validateHome(profile)
                let state = try JSONDecoder().decode(HomeDiskState.self, from: PrivateFiles.read(homeDirectory(profile).appendingPathComponent("state.json")))
                if state.sizeGiB == home.sizeGiB { return }
                let fd = open(image.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw HomeDisk.failure("Cannot open the home disk for growth.") }
                defer { close(fd) }
                guard ftruncate(fd, Int64(home.sizeGiB) * 1_073_741_824) == 0, fsync(fd) == 0 else { throw HomeDisk.failure("Home-disk growth failed. Existing data was preserved.") }
                try recordHomeState(profile)
            }
        }
    }
    func cloneHomeForNewRoot(_ profile: VMProfile) throws {
        guard let home = profile.homeDisk, let sourceID = home.sourceVMID else { return }
        let data = try PrivateFiles.read(directory.appendingPathComponent("registry.json"), maximum: 1_048_576)
        let source = try RegistryStore.profileForHomeReuse(in: data, id: sourceID)
        guard source.homeDisk?.id == home.id, source.homeDisk?.sizeGiB == home.sizeGiB else { throw HomeDisk.failure("The source home identity or capacity changed before copying.") }
        try withLock(source) {
            try validate(source); try requireNoSavedSession(source)
            let original = homeImage(source)
            try PrivateFiles.directory(homeDirectory(profile), create: true)
            guard !PrivateFiles.exists(homeImage(profile)), clonefile(original.path, homeImage(profile).path, UInt32(CLONE_NOFOLLOW)) == 0 else {
                throw HomeDisk.failure("The source must have an existing home disk on APFS. Its data was preserved; the replacement was not launched.")
            }
            try recordHomeState(profile)
            try validateHome(profile)
        }
    }
    func homeDirectory(_ profile: VMProfile) -> URL { root(for: profile).appendingPathComponent("home") }
    func homeImage(_ profile: VMProfile) -> URL { homeDirectory(profile).appendingPathComponent("disk.img") }
    func validateHome(_ profile: VMProfile) throws {
        let plan = root(for: profile).appendingPathComponent(".omarchy-home.json")
        guard let home = profile.homeDisk else {
            guard !PrivateFiles.exists(plan), !PrivateFiles.exists(homeDirectory(profile)) else { throw HomeDisk.failure("Unexpected home-disk storage was preserved.") }
            return
        }
        let recorded = try JSONDecoder().decode(HomeDisk.self, from: PrivateFiles.read(plan))
        try recorded.validate(vmID: profile.id)
        guard recorded.id == home.id, recorded.sourceVMID == home.sourceVMID, recorded.sizeGiB <= home.sizeGiB else { throw HomeDisk.failure("The home-disk identity differs from its profile.") }
        if PrivateFiles.exists(homeDirectory(profile)) { try PrivateFiles.directory(homeDirectory(profile)) }
        let statePath = homeDirectory(profile).appendingPathComponent("state.json")
        if PrivateFiles.exists(statePath), !PrivateFiles.exists(homeImage(profile)) { throw HomeDisk.failure("The recorded home disk is missing; storage was preserved.") }
        if PrivateFiles.exists(homeImage(profile)) {
            let fd = open(homeImage(profile).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw HomeDisk.failure("Cannot safely open the home disk.") }
            defer { close(fd) }
            var info = stat()
            let state = try JSONDecoder().decode(HomeDiskState.self, from: PrivateFiles.read(statePath))
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_mode & 0o7777 == 0o600, info.st_nlink == 1,
                  state.schemaVersion == 1, state.id == home.id, state.device == Int64(info.st_dev), state.inode == info.st_ino,
                  state.sizeGiB >= 16, state.sizeGiB <= home.sizeGiB, info.st_size == Int64(state.sizeGiB) * 1_073_741_824,
                  info.st_size >= 16 * 1_073_741_824, info.st_size <= Int64(home.sizeGiB) * 1_073_741_824 else {
                throw HomeDisk.failure("The home disk is unsafe or larger than its configured capacity. It was preserved.")
            }
        }
    }
}
