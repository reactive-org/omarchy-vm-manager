import Darwin
import Foundation

/// Private v1.3 settings coupling; the kit owns the export and guest mount.
public struct SharedFolderMapping: Codable, Equatable, Sendable {
    public var hostPath: String
    public var enabled: Bool
    public let guestPath: String
    public let access: String
    public init(hostPath: String, enabled: Bool = true) {
        self.hostPath = hostPath; self.enabled = enabled
        guestPath = "/mnt/mac"; access = "read-write"
    }
    public static var defaultPath: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Shared").path }
    public func validate() throws {
        guard guestPath == "/mnt/mac", access == "read-write", hostPath.hasPrefix("/"),
              hostPath.utf8.count <= 1024, !hostPath.contains(","),
              !hostPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !hostPath.hasSuffix("/"), !hostPath.contains("//"),
              !hostPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw SharedFolderPolicy.failure("Use an absolute host folder and the supported /mnt/mac read-write mapping.")
        }
    }
    var runtimePreference: [String: Any] { ["schemaVersion": 1, "path": hostPath, "isEnabled": enabled] }
}

public enum SharedFolderPolicy {
    static func failure(_ message: String) -> VMFailure { VMFailure(code: "unsafe-shared-folder", message: message) }
    /// Only dedicated, owned directories inside the user's home are eligible.
    /// Never create a path, chmod it, resolve a selected link, or request TCC access.
    public static func mapping(path: String, enabled: Bool = true,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> SharedFolderMapping {
        let expanded = path == "~" ? home.path : path.hasPrefix("~/") ? home.path + String(path.dropFirst()) : path
        let result = SharedFolderMapping(hostPath: expanded, enabled: enabled)
        try result.validate()
        if enabled { try validateHost(result, home: home) }
        return result
    }
    public static func validateHost(_ mapping: SharedFolderMapping,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try mapping.validate()
        // Foundation can shorten /private/tmp to /tmp on macOS; use the same
        // POSIX canonical identity as the filesystem, including in fixtures.
        func canonical(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        guard let homePath = canonical(home.path) else { throw failure("Cannot identify the home directory.") }
        let home = URL(fileURLWithPath: homePath)
        let selected = URL(fileURLWithPath: mapping.hostPath)
        guard selected.path.hasPrefix(home.path + "/"), canonical(selected.path) == selected.path else {
            throw failure("Choose a dedicated folder inside your home, without symbolic links. The whole home and external directories cannot be exposed.")
        }
        let components = selected.path.dropFirst(home.path.count + 1).split(separator: "/").map(String.init)
        let protected: Set<String> = ["Library", "Applications", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]
        guard !components.contains(where: { $0.hasPrefix(".") }),
              components.count > 1 || !protected.contains(components[0]), components.first != "Library" else {
            throw failure("Choose a dedicated sharing folder; hidden, Library and broad personal folders cannot be exposed.")
        }
        var ancestor = selected
        while ancestor.path != home.path {
            var info = stat()
            guard lstat(ancestor.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o022 == 0,
                  access(ancestor.path, R_OK | X_OK) == 0 else {
                throw failure("The sharing folder and its parents must exist, belong to you, be readable and searchable, and not be writable by other users. Create the dedicated folder yourself or choose another path.")
            }
            ancestor = ancestor.deletingLastPathComponent()
        }
        guard access(selected.path, W_OK) == 0 else { throw failure("Read-write sharing requires host write permission. No permissions were changed.") }
        // Refuse credential trees and symlinks already inside the selected folder.
        // This is a preflight check, not a content filter for files added later.
        let credentials: Set<String> = [".ssh", ".aws", ".azure", ".config", ".gnupg", ".kube", ".netrc", ".env", ".git-credentials", ".npmrc", ".docker", ".codex"]
        var failed = false, count = 0
        guard let entries = FileManager.default.enumerator(at: selected, includingPropertiesForKeys: nil,
            errorHandler: { _, _ in failed = true; return false }) else { throw failure("Cannot inspect the sharing folder.") }
        for case let entry as URL in entries {
            count += 1
            var info = stat()
            guard count <= 100_000, lstat(entry.path, &info) == 0,
                  [S_IFDIR, S_IFREG].contains(info.st_mode & S_IFMT),
                  info.st_uid == getuid(), info.st_mode & 0o022 == 0,
                  info.st_mode & S_IFMT != S_IFREG || info.st_nlink == 1,
                  !credentials.contains(entry.lastPathComponent) else {
                throw failure("The sharing folder contains a link, special file, credential location, unsafe permissions or too many entries. Choose a dedicated data folder; its contents were preserved.")
            }
        }
        guard !failed else { throw failure("Cannot completely inspect the sharing folder. Check its access permissions.") }
    }
}

public enum SharedFolderReadiness: Equatable, Sendable {
    case disabled, stopped, waitingForSSH, checking, mounted, unverified
    case failed(String)
    public var label: String {
        switch self {
        case .disabled: "Off"
        case .stopped: "Applies next start"
        case .waitingForSSH: "Waiting for authenticated SSH"
        case .checking: "Checking mount"
        case .mounted: "Mounted · Read & write"
        case .unverified: "Mount unverified"
        case .failed(let message): message
        }
    }
    public var status: String {
        switch self {
        case .disabled: "disabled"
        case .stopped: "stopped"
        case .waitingForSSH: "waiting-ssh"
        case .checking: "checking"
        case .mounted: "mounted"
        case .unverified: "unverified"
        case .failed: "failed"
        }
    }
}

public protocol SharedFolderChecking: Sendable {
    func check(_ request: VMStartRequest, user: String) async throws
}

extension GuestConfigurationPatch {
    func sharing(replacing current: SharedFolderMapping?) throws -> SharedFolderMapping? {
        guard share != nil || sharePath != nil else { return current }
        return try SharedFolderPolicy.mapping(path: sharePath ?? current?.hostPath ?? SharedFolderMapping.defaultPath,
                                              enabled: share ?? true)
    }
}

/// Read-only inspection. No sudo, guest policy, unit installation or mount controller.
public struct SSHSharedFolderProbe: SharedFolderChecking {
    private let transport: @Sendable ([String]) async throws -> SSHProbeProcess.Result
    private let pause: @Sendable () async throws -> Void
    public init() {
        transport = Self.run
        pause = { try await Task.sleep(for: .milliseconds(300)) }
    }
    init(transport: @escaping @Sendable ([String]) async throws -> SSHProbeProcess.Result,
         pause: @escaping @Sendable () async throws -> Void = {}) {
        self.transport = transport; self.pause = pause
    }
    private static func run(_ arguments: [String]) async throws -> SSHProbeProcess.Result {
        let process = SSHProbeProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached { try process.run(arguments: arguments) }.value
        } onCancel: { process.cancel() }
    }
    static let program = """
    import json,os,subprocess
    identity=json.loads(subprocess.check_output(['/usr/lib/try-omarchy/managed-ssh-identity'],timeout=2))
    mount=subprocess.run(['/usr/bin/findmnt','--json','--mountpoint','/mnt/mac','--output','SOURCE,TARGET,FSTYPE,OPTIONS'],capture_output=True,text=True,timeout=2)
    print(json.dumps({'identity':identity,'accessible':os.access('/mnt/mac',os.R_OK|os.W_OK|os.X_OK),'mount':json.loads(mount.stdout) if mount.returncode==0 else {}},separators=(',',':')))
    """
    public func check(_ request: VMStartRequest, user: String) async throws {
        let storage = ManagedSSHStorage(root: request.storageRoot)
        do { try storage.validate(request.profile) }
        catch { throw Self.failure(stage: "host-metadata") }
        guard ManagedSSHProbe.validUser(user) else { throw Self.failure(stage: "owner") }
        var arguments = storage.arguments(profile: request.profile, user: user)
        arguments[arguments.count - 1] = "/usr/bin/python3 -I -c '" + Self.program.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // A transport interruption does not establish a missing guest mount.
        // Keep retries bounded below the SSH monitor's next 30-second check.
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let result: SSHProbeProcess.Result
            do { result = try await transport(arguments) }
            catch is CancellationError { throw CancellationError() }
            catch {
                guard attempt < 2 else { throw Self.failure(stage: "ssh-process") }
                try await pause(); continue
            }
            try Task.checkCancellation()
            guard !result.hostKeyMismatch else { throw Self.failure(stage: "ssh-identity") }
            if result.status == 0 {
                try Self.validateReport(result.output, request: request, user: user)
                return
            }
            guard attempt < 2, !["configuration", "authentication", "hostname", "key-access", "host-denied", "negotiation"].contains(result.failureKind) else {
                throw Self.failure(stage: "ssh-exit-\(result.status)-\(result.failureKind)")
            }
            try await pause()
        }
    }
    static func validateReport(_ data: Data, request: VMStartRequest, user: String) throws {
        struct Report: Decodable {
            let identity: ManagedSSHProbe.Identity
            let accessible: Bool
            struct Mounts: Decodable {
                struct Mount: Decodable { let source: String; let target: String; let fstype: String; let options: String }
                let filesystems: [Mount]?
            }
            let mount: Mounts
        }
        guard data.count <= 4096, let report = try? JSONDecoder().decode(Report.self, from: data),
              report.identity.vmID == request.profile.id, report.identity.sessionToken == request.sessionID,
              report.identity.user == user, (1000..<60000).contains(report.identity.uid),
              report.accessible,
              let mounts = report.mount.filesystems, mounts.count == 1, let mount = mounts.first,
              mount.source == "mac", mount.target == "/mnt/mac", mount.fstype == "9p" else { throw failure() }
        let options = Set(mount.options.split(separator: ",").map(String.init))
        // Linux can omit the default protocol from show_options/findmnt.
        // The pinned native service supplies version=9p2000.L explicitly;
        // reject a conflicting reported version without requiring its display.
        guard options.contains("rw"), options.contains("trans=virtio"),
              options.filter({ $0.hasPrefix("version=") }).isSubset(of: ["version=9p2000.L"]),
              options.contains("cache=readahead") || options.contains("cache=0x1"),
              options.filter({ $0.hasPrefix("cache=") }).count == 1, !options.contains("ro") else { throw failure() }
    }
    static func failure(stage: String = "mount-report") -> VMFailure {
        VMFailure(code: "shared-folder-unavailable", message: "The native /mnt/mac read-write 9p mount could not be verified (\(stage)). Check the guest's omarchy-native-mac-share.service, 9p kernel support and host folder access, then Retry SSH Check or restart normally. Guest data was preserved.")
    }
}
