import Darwin
import Foundation

public struct ManagerStorage: Sendable {
    public let applicationSupport: URL
    public init(applicationSupport: URL) { self.applicationSupport = applicationSupport.resolvingSymlinksInPath() }
    public var directory: URL { applicationSupport.appendingPathComponent("Omarchy VM Manager") }
    public var vms: URL { directory.appendingPathComponent("VMs") }
    public func root(for profile: VMProfile) -> URL { vms.appendingPathComponent(profile.id.uuidString) }
    func matchesRoot(_ url: URL, profile: VMProfile) -> Bool {
        guard url.isFileURL, let requested = canonicalPath(url), let expected = canonicalPath(root(for: profile)) else { return false }
        return requested == expected
    }
    private func canonicalPath(_ url: URL) -> String? {
        var ancestor = url.standardizedFileURL
        var components: [String] = []
        while !PrivateFiles.exists(ancestor) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return nil }
            components.insert(ancestor.lastPathComponent, at: 0)
            ancestor = parent
        }
        guard let resolved = realpath(ancestor.path, nil) else { return nil }
        defer { free(resolved) }
        return components.reduce(URL(fileURLWithPath: String(cString: resolved))) { $0.appendingPathComponent($1) }.path
    }
    private struct Marker: Codable { let schemaVersion: Int; let id: UUID }
    private struct Schema: Decodable { let schemaVersion: Int }
    private struct Forwarding: Decodable { struct Mapping: Decodable { let hostPort: Int; let guestPort: Int; let `protocol`: String }; let schemaVersion: Int; let mappings: [Mapping] }
    private struct Fullscreen: Decodable { let schemaVersion: Int; let isImmersive: Bool; let usesNotch: Bool? }
    private struct ResourcePreferences: Decodable {
        struct Resources: Decodable { let cpuCount: Int; let memoryGiB: Int; let diskGiB: Int? }
        let schemaVersion: Int
        let resources: Resources
    }

    public func prepare(_ profile: VMProfile, sessionID: UUID = UUID(), ownerPassword: Data? = nil) throws -> URL {
        try RegistryStore.validate(profile)
        try PrivateFiles.directory(directory, create: true)
        try PrivateFiles.directory(vms, create: true)
        let root = root(for: profile)
        var created = false
        if !PrivateFiles.exists(root) {
            guard !profile.isRetainedPOC else { throw PrivateFiles.failure("The retained POC disk is missing; it will not be recreated.") }
            guard mkdir(root.path, 0o700) == 0 else { throw PrivateFiles.failure("The VM root appeared during creation. Existing storage was preserved.") }
            try PrivateFiles.directory(root)
            try PrivateFiles.write(JSONEncoder().encode(Marker(schemaVersion: 1, id: profile.id)), name: ".omarchy-vm-manager.json", in: root, exclusively: true)
            try PrivateFiles.write(Data("omarchy-qemu-storage-root-v1\n".utf8), name: ".omarchy-qemu-storage", in: root, exclusively: true)
            var values: [String: Any] = Dictionary(uniqueKeysWithValues: POCStorage.inheritedKeys.map { ($0, NSNull()) })
            if let ssh = profile.ssh { values["portForwardingPreferences"] = ["schemaVersion": 1, "mappings": [["hostPort": ssh.hostPort, "guestPort": 22, "protocol": "tcp"]]] }
            if profile.diskGiB != nil { values["vmResourcePreferences"] = resourcePreferences(profile) }
            let settings: [String: Any] = ["schemaVersion": 1, "settings": values]
            try PrivateFiles.write(JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), name: "settings.json", in: root, exclusively: true)
            created = true
        }
        try validate(profile)
        if !profile.isRetainedPOC, profile.diskGiB != nil || profile.immersiveMode != nil {
            try withLock(profile) {
                try validate(profile)
                var settings = try settings(profile)
                var values = settings["settings"] as! [String: Any]
                let resourcesMatch = profile.diskGiB == nil || jsonEqual(values["vmResourcePreferences"], resourcePreferences(profile))
                let fullscreenMatches = profile.immersiveMode == nil || {
                    guard let current = values["fullscreenPreferences"] as? [String: Any] else { return false }
                    return current["isImmersive"] as? Bool == profile.immersiveMode
                }()
                if resourcesMatch, fullscreenMatches { return }
                let fingerprint = try settingsFingerprint(profile)
                guard created || fingerprint == profile.settingsFingerprint else {
                    throw VMFailure(code: "settings-changed", message: "VM settings changed outside the manager. They were preserved. Review and save the configuration again before launching.")
                }
                if !resourcesMatch { values["vmResourcePreferences"] = resourcePreferences(profile) }
                if !fullscreenMatches, let immersive = profile.immersiveMode {
                    values["fullscreenPreferences"] = ["schemaVersion": 1, "isImmersive": immersive, "usesNotch": true]
                }
                settings["settings"] = values
                try PrivateFiles.write(JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), name: "settings.json", in: root)
            }
        }
        if profile.ssh != nil {
            try withLock(profile) { try ManagedSSHStorage(root: root).prepare(profile: profile, sessionID: sessionID, applicationSupport: applicationSupport, newRoot: created) }
        } else if PrivateFiles.exists(root.appendingPathComponent(ManagedSSHStorage.manifestName)) {
            throw PrivateFiles.failure("Unexpected managed SSH metadata is present. No existing access was changed.")
        }
        if profile.ownerSetup != nil {
            try withLock(profile) { try ManagedOwnerStorage(root: root).prepare(profile, sessionID: sessionID, password: ownerPassword, newRoot: created) }
        } else if PrivateFiles.exists(root.appendingPathComponent(".manager-setup")) || PrivateFiles.exists(root.appendingPathComponent(ManagedOwnerStorage.launchName)) {
            throw PrivateFiles.failure("Unexpected unattended setup metadata is present. Existing storage was preserved.")
        }
        return root
    }

    public func validate(_ profile: VMProfile) throws {
        try PrivateFiles.directory(directory)
        try PrivateFiles.directory(vms)
        let root = root(for: profile)
        try PrivateFiles.directory(root)
        let marker = try JSONDecoder().decode(Marker.self, from: PrivateFiles.read(root.appendingPathComponent(".omarchy-vm-manager.json")))
        guard marker.schemaVersion == 1, marker.id == profile.id,
              try PrivateFiles.read(root.appendingPathComponent(".omarchy-qemu-storage")) == Data("omarchy-qemu-storage-root-v1\n".utf8) else {
            throw PrivateFiles.failure("The VM ownership markers are invalid. Storage was preserved.")
        }
        _ = try settings(profile)
        for name in ["shell", "shell-factory"] {
            let path = root.appendingPathComponent(name)
            if PrivateFiles.exists(path) { try PrivateFiles.directory(path) }
        }
        let disk = root.appendingPathComponent("shell/disk.img")
        if PrivateFiles.exists(disk) {
            var s = stat()
            guard lstat(disk.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(),
                  s.st_nlink == 1, s.st_mode & 0o077 == 0 else { throw PrivateFiles.failure("The VM disk is unsafe; it was preserved.") }
        }
    }

    private func settings(_ profile: VMProfile) throws -> [String: Any] {
        let data = try PrivateFiles.read(root(for: profile).appendingPathComponent("settings.json"))
        guard try JSONDecoder().decode(Schema.self, from: data).schemaVersion == 1,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "settings"], let version = object["schemaVersion"] as? Int, version == 1,
              let values = object["settings"] as? [String: Any], Set(values.keys) == POCStorage.inheritedKeys else {
            throw PrivateFiles.failure("Unknown or damaged VM settings. The file was preserved.")
        }
        if let ssh = profile.ssh {
            guard let value = values["portForwardingPreferences"], !(value is NSNull),
                  let forwarding = try? JSONDecoder().decode(Forwarding.self, from: JSONSerialization.data(withJSONObject: value)),
                  forwarding.schemaVersion == 1, forwarding.mappings.count == 1,
                  forwarding.mappings[0].hostPort == ssh.hostPort, forwarding.mappings[0].guestPort == 22, forwarding.mappings[0].protocol == "tcp" else {
                throw PrivateFiles.failure("The managed SSH forwarding setting changed. It was preserved; this endpoint will not be silently redirected.")
            }
        }
        for (key, value) in values where !(value is NSNull) {
            if key == "portForwardingPreferences", profile.ssh != nil { continue }
            if key == "vmResourcePreferences", profile.diskGiB != nil,
               let payload = value as? [String: Any], Set(payload.keys) == ["schemaVersion", "resources"],
               payload["schemaVersion"] as? Int == 1, let resources = payload["resources"] as? [String: Any],
               Set(resources.keys) == ["cpuCount", "memoryGiB", "diskGiB"],
               let typed = try? JSONDecoder().decode(ResourcePreferences.self, from: JSONSerialization.data(withJSONObject: payload)),
               typed.schemaVersion == 1, (4...1024).contains(typed.resources.cpuCount),
               (4...1024).contains(typed.resources.memoryGiB),
               typed.resources.diskGiB.map({ (64...8192).contains($0) }) == true { continue }
            guard key == "fullscreenPreferences", let fullscreen = value as? [String: Any],
                  Set(fullscreen.keys).isSubset(of: ["schemaVersion", "isImmersive", "usesNotch"]),
                  fullscreen["schemaVersion"] as? Int == 1, fullscreen["isImmersive"] is Bool,
                  fullscreen["usesNotch"] == nil || fullscreen["usesNotch"] is Bool,
                  let typed = try? JSONDecoder().decode(Fullscreen.self, from: JSONSerialization.data(withJSONObject: fullscreen)),
                  typed.schemaVersion == 1 else {
                throw VMFailure(code: "unsupported-settings", message: "This VM has settings outside the current manager policy. Restore the known settings or wait for the effective-settings support; the file was preserved.")
            }
        }
        return object
    }

    public func diskCapacityGiB(_ profile: VMProfile) throws -> Int? {
        let disk = root(for: profile).appendingPathComponent("shell/disk.img")
        guard PrivateFiles.exists(disk) else { return nil }
        var info = stat()
        guard lstat(disk.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            throw PrivateFiles.failure("The VM disk is unsafe; its capacity was not changed.")
        }
        return Int((UInt64(info.st_size) + 1_073_741_823) / 1_073_741_824)
    }

    private func resourcePreferences(_ profile: VMProfile) -> [String: Any] {
        ["schemaVersion": 1, "resources": [
            "cpuCount": profile.cpus, "memoryGiB": profile.memoryMiB / 1024, "diskGiB": profile.diskGiB!
        ]]
    }

    private func jsonEqual(_ current: Any?, _ desired: [String: Any]) -> Bool {
        guard let current = current as? [String: Any] else { return false }
        return NSDictionary(dictionary: current).isEqual(to: desired)
    }

    func withLock<T>(_ profile: VMProfile, _ body: () throws -> T) throws -> T {
        let shell = root(for: profile).appendingPathComponent("shell")
        try PrivateFiles.directory(shell, create: true)
        let fd = open(shell.appendingPathComponent("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PrivateFiles.failure("Cannot safely open the VM lock.") }
        defer { close(fd) }
        var s = stat(); var lock = flock()
        lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET)
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1,
              s.st_mode & 0o7777 == 0o600, fcntl(fd, F_SETLK, &lock) == 0 else {
            throw VMFailure(code: "vm-already-open", message: "This VM is open in another process or its lock is unsafe. Shut it down before changing its storage.")
        }
        return try body()
    }

    public func settingsFingerprint(_ profile: VMProfile) throws -> String {
        try KitVerifier.sha256(PrivateFiles.read(root(for: profile).appendingPathComponent("settings.json")))
    }

    public func deletionIdentity(_ profile: VMProfile) throws -> String {
        try validate(profile)
        let disk = root(for: profile).appendingPathComponent("shell/disk.img")
        var signature = "no-disk"
        if PrivateFiles.exists(disk) {
            var s = stat()
            guard lstat(disk.path, &s) == 0 else { throw PrivateFiles.failure("Cannot identify the VM disk.") }
            signature = "\(s.st_dev):\(s.st_ino):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec)"
        }
        return try identity(root(for: profile)) + ":" + signature + ":" + settingsFingerprint(profile)
    }

    private func identity(_ url: URL) throws -> String {
        var s = stat()
        guard lstat(url.path, &s) == 0 else { throw PrivateFiles.failure("The VM changed; review it again.") }
        return "\(s.st_dev):\(s.st_ino)"
    }

    public func trash(_ profile: VMProfile, expectedIdentity: String,
                      recycle: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        guard !profile.isRetainedPOC else { throw VMFailure(code: "retained-poc", message: "The retained POC disks are protected from deletion.") }
        try validate(profile)
        try withLock(profile) {
            guard try deletionIdentity(profile) == expectedIdentity else { throw PrivateFiles.failure("The selected VM changed since confirmation. Nothing was moved.") }
            try rejectUnsafeTree(root(for: profile))
            guard try deletionIdentity(profile) == expectedIdentity else { throw PrivateFiles.failure("The selected VM changed during validation. Nothing was moved.") }
            try recycle(root(for: profile))
        }
    }

    private func rejectUnsafeTree(_ root: URL) throws {
        var enumerationFailed = false
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw PrivateFiles.failure("Cannot inspect the VM directory.") }
        for case let url as URL in files {
            var s = stat()
            guard lstat(url.path, &s) == 0, s.st_uid == getuid(),
                  (s.st_mode & S_IFMT == S_IFDIR || (s.st_mode & S_IFMT == S_IFREG && s.st_nlink == 1)),
                  s.st_mode & 0o022 == 0 else { throw PrivateFiles.failure("The VM contains a link, special file or unsafe ownership/permissions. Nothing was moved.") }
        }
        guard !enumerationFailed else { throw PrivateFiles.failure("Cannot completely inspect the VM directory. Nothing was moved.") }
    }
}

public struct TrashRequest: Codable, Sendable {
    public let profile: VMProfile
    public let expectedIdentity: String
    public init(profile: VMProfile, expectedIdentity: String) { self.profile = profile; self.expectedIdentity = expectedIdentity }
}

public protocol VMTrashService: Sendable {
    func moveToTrash(_ request: TrashRequest) async throws
}

public struct HelperTrashService: VMTrashService {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }
    public func moveToTrash(_ request: TrashRequest) async throws {
        let executable = self.executable
        try await Task.detached {
            let process = Process(); process.executableURL = executable
            process.arguments = ["--trash", request.profile.id.uuidString, request.expectedIdentity]
            let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
            let data = try output.fileHandleForReading.read(upToCount: 8193) ?? Data()
            if data.count >= 8192 { process.terminate() }
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count < 8192,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["ok"] as? Bool == true, object["id"] as? String == request.profile.id.uuidString else {
                throw VMFailure(code: "trash-refused", message: "Storage could not be moved to Trash. It may be open, changed or unsafe. The registry entry was retained.")
            }
        }.value
    }
}
