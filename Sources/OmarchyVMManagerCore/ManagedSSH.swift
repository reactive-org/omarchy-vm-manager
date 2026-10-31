import Darwin
import Foundation

public struct SSHOptions: Codable, Equatable, Sendable {
    public let hostPort: Int
    public let publicKeyFingerprint: String?
    public init(hostPort: Int, publicKeyFingerprint: String? = nil) {
        self.hostPort = hostPort; self.publicKeyFingerprint = publicKeyFingerprint
    }
}

public enum SSHReadiness: Equatable, Sendable {
    case disabled, stopped, provisioning, waitingForOwner, connecting
    case ready(user: String, command: String)
    case failed(String)
    public var label: String {
        switch self {
        case .disabled: "Off"
        case .stopped: "Available on next launch"
        case .provisioning: "Preparing SSH"
        case .waitingForOwner: "Waiting for guest account setup"
        case .connecting: "Checking SSH connection"
        case .ready: "Ready"
        case .failed(let message): message
        }
    }
}

public protocol HostPortProbing: Sendable { func isAvailable(_ port: Int) -> Bool }
public struct LoopbackPortProbe: HostPortProbing {
    public init() {}
    public func isAvailable(_ port: Int) -> Bool {
        guard (1024...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }
}

public enum SSHPublicKey {
    public static func canonical(_ text: String) throws -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        guard text.utf8.count <= 16_384, lines.count == 1, !text.contains("PRIVATE KEY"), !text.contains("\r") else { throw invalid() }
        let fields = lines[0].split(whereSeparator: \.isWhitespace)
        let types: Set<String> = ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"]
        guard fields.count >= 2, types.contains(String(fields[0])), let blob = Data(base64Encoded: String(fields[1])), blob.count >= 16, blob.count <= 8192 else { throw invalid() }
        var position = 0
        func field() throws -> Data {
            guard position + 4 <= blob.count else { throw invalid() }
            let length = blob.subdata(in: position..<(position + 4)).reduce(0) { ($0 << 8) | Int($1) }
            position += 4
            guard length <= blob.count - position else { throw invalid() }
            let result = blob.subdata(in: position..<(position + length)); position += length
            return result
        }
        let type = String(fields[0])
        guard try String(data: field(), encoding: .utf8) == type else { throw invalid() }
        if type == "ssh-rsa" {
            let exponent = try field(), modulus = try field()
            guard !exponent.isEmpty, exponent.count <= 8, modulus.count >= 128 else { throw invalid() }
        } else if type.contains("ed25519") {
            guard try field().count == 32 else { throw invalid() }
        } else {
            let curve = try field(), point = try field()
            guard let curveName = String(data: curve, encoding: .utf8), type.contains(curveName),
                  ["nistp256": 65, "nistp384": 97, "nistp521": 133][curveName] == point.count, point.first == 4 else { throw invalid() }
        }
        if type.hasPrefix("sk-") { let application = try field(); guard !application.isEmpty, application.count <= 1024 else { throw invalid() } }
        guard position == blob.count else { throw invalid() }
        return type + " " + blob.base64EncodedString()
    }
    public static func fingerprint(_ text: String) throws -> String {
        let key = try canonical(text)
        let blob = Data(base64Encoded: String(key.split(separator: " ")[1]))!
        return "SHA256:" + Data(hex: KitVerifier.sha256(blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    private static func invalid() -> VMFailure { VMFailure(code: "invalid-public-key", message: "Choose one valid OpenSSH .pub key. Private keys and authorized_keys options are not accepted.") }
}

private extension Data {
    init(hex: String) { self.init(stride(from: 0, to: hex.count, by: 2).map { n in UInt8(hex.dropFirst(n).prefix(2), radix: 16)! }) }
}

public struct SelectedPublicKeyStore: Sendable {
    let directory: URL
    public init(applicationSupport: URL) { directory = applicationSupport.resolvingSymlinksInPath().appendingPathComponent("Omarchy VM Manager/PublicKeys") }
    public func save(_ text: String, id: UUID) throws -> String {
        let canonical = try SSHPublicKey.canonical(text)
        try PrivateFiles.directory(directory, create: true)
        try PrivateFiles.write(Data((canonical + "\n").utf8), name: id.uuidString + ".pub", in: directory, exclusively: true)
        return try SSHPublicKey.fingerprint(canonical)
    }
    func read(_ id: UUID) throws -> String { try SSHPublicKey.canonical(String(decoding: PrivateFiles.read(directory.appendingPathComponent(id.uuidString + ".pub")), as: UTF8.self)) }
    func remove(_ id: UUID) { if (try? PrivateFiles.directory(directory)) != nil { unlink(directory.appendingPathComponent(id.uuidString + ".pub").path) } }
}

public struct ManagedSSHStorage: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public var directory: URL { root.appendingPathComponent(".manager-ssh") }
    public var bootstrap: URL { directory.appendingPathComponent("bootstrap") }
    public var clientKey: URL { directory.appendingPathComponent("client") }
    public var knownHosts: URL { directory.appendingPathComponent("known_hosts") }
    public var clientConfig: URL { directory.appendingPathComponent("config") }
    public static let manifestName = ".omarchy-managed-ssh.json"

    public struct Manifest: Codable, Sendable {
        public let schemaVersion: Int
        public let vmID: UUID
        public let sessionToken: UUID
        public let hostPort: Int
    }
    struct Bootstrap: Codable { let schemaVersion: Int; let vmID: UUID; let sessionToken: UUID; let publicKeys: [String] }

    func prepare(profile: VMProfile, sessionID: UUID, applicationSupport: URL, newRoot: Bool) throws {
        guard let options = profile.ssh, !profile.isRetainedPOC else { return }
        if !PrivateFiles.exists(directory) {
            guard newRoot else { throw VMFailure(code: "ssh-credentials-missing", message: "SSH credentials are missing. Existing VM identities will not be regenerated automatically.") }
            let stage = root.appendingPathComponent(".manager-ssh.pending")
            guard mkdir(stage.path, 0o700) == 0 else { throw PrivateFiles.failure("Incomplete SSH credential creation was preserved for recovery.") }
            let shared = stage.appendingPathComponent("bootstrap")
            try PrivateFiles.directory(shared, create: true)
            try generate(at: stage.appendingPathComponent("client"))
            try generate(at: shared.appendingPathComponent("host_ed25519"))
            if options.publicKeyFingerprint != nil {
                let key = try SelectedPublicKeyStore(applicationSupport: applicationSupport).read(profile.id)
                guard try SSHPublicKey.fingerprint(key) == options.publicKeyFingerprint else { throw PrivateFiles.failure("The selected public key changed. No credential was replaced.") }
                try PrivateFiles.write(Data((key + "\n").utf8), name: "owner.pub", in: stage, exclusively: true)
            }
            let host = try SSHPublicKey.canonical(String(decoding: PrivateFiles.read(shared.appendingPathComponent("host_ed25519.pub")), as: UTF8.self))
            try PrivateFiles.write(Data((alias(profile.id) + " " + host + "\n").utf8), name: "known_hosts", in: stage, exclusively: true)
            try FileManager.default.moveItem(at: stage, to: directory)
        }
        try validate(profile)
        var keys = [try SSHPublicKey.canonical(String(decoding: PrivateFiles.read(directory.appendingPathComponent("client.pub")), as: UTF8.self))]
        if options.publicKeyFingerprint != nil { keys.append(try SSHPublicKey.canonical(String(decoding: PrivateFiles.read(directory.appendingPathComponent("owner.pub")), as: UTF8.self))) }
        let manifest = Manifest(schemaVersion: 1, vmID: profile.id, sessionToken: sessionID, hostPort: options.hostPort)
        try PrivateFiles.write(JSONEncoder().encode(Bootstrap(schemaVersion: 1, vmID: profile.id, sessionToken: sessionID, publicKeys: keys)), name: "manifest.json", in: bootstrap)
        try PrivateFiles.write(JSONEncoder().encode(manifest), name: Self.manifestName, in: root)
    }

    func validate(_ profile: VMProfile) throws {
        try PrivateFiles.directory(directory); try PrivateFiles.directory(bootstrap)
        _ = try PrivateFiles.read(clientKey)
        _ = try PrivateFiles.read(bootstrap.appendingPathComponent("host_ed25519"))
        let host = try SSHPublicKey.canonical(String(decoding: PrivateFiles.read(bootstrap.appendingPathComponent("host_ed25519.pub")), as: UTF8.self))
        let trusted = String(decoding: try PrivateFiles.read(knownHosts), as: UTF8.self)
        guard trusted == alias(profile.id) + " " + host + "\n" else { throw VMFailure(code: "ssh-host-key-changed", message: "The pinned guest SSH identity changed. Review recovery; host keys are never accepted silently after enrollment.") }
        if let fingerprint = profile.ssh?.publicKeyFingerprint {
            let owner = String(decoding: try PrivateFiles.read(directory.appendingPathComponent("owner.pub")), as: UTF8.self)
            guard try SSHPublicKey.fingerprint(owner) == fingerprint else { throw PrivateFiles.failure("The selected public key does not match this profile.") }
        }
    }

    private func generate(at path: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "Omarchy VM Manager", "-f", path.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw VMFailure(code: "ssh-key-generation-failed", message: "SSH key generation failed; incomplete credentials were preserved.") }
        guard chmod(path.path, 0o600) == 0, chmod(path.path + ".pub", 0o600) == 0 else { throw PrivateFiles.failure("Cannot protect SSH credentials.") }
    }
    func alias(_ id: UUID) -> String { "omarchy-" + id.uuidString.lowercased() }
    func arguments(profile: VMProfile, user: String) -> [String] {
        ["-F", "/dev/null", "-T", "-p", String(profile.ssh!.hostPort), "-i", clientKey.path,
         "-o", "HostKeyAlias=" + alias(profile.id), "-o", "UserKnownHostsFile=" + quotedOption(knownHosts.path),
         "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlgorithms=ssh-ed25519",
         "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "ForwardAgent=no", "-o", "BatchMode=yes",
         "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-o", "ConnectTimeout=3", "-o", "ConnectionAttempts=1",
         user + "@127.0.0.1", "/usr/lib/try-omarchy/managed-ssh-identity"]
    }
    func command(profile: VMProfile, user: String) throws -> String {
        let config = "Host \(alias(profile.id))\n HostName 127.0.0.1\n Port \(profile.ssh!.hostPort)\n User \(user)\n IdentityFile \(quotedOption(clientKey.path))\n UserKnownHostsFile \(quotedOption(knownHosts.path))\n GlobalKnownHostsFile /dev/null\n HostKeyAlias \(alias(profile.id))\n StrictHostKeyChecking yes\n HostKeyAlgorithms ssh-ed25519\n IdentitiesOnly yes\n IdentityAgent none\n ForwardAgent no\n PasswordAuthentication no\n KbdInteractiveAuthentication no\n"
        try PrivateFiles.write(Data(config.utf8), name: "config", in: directory)
        return "/usr/bin/ssh -F '" + clientConfig.path.replacingOccurrences(of: "'", with: "'\\''") + "' " + alias(profile.id)
    }
    private func quotedOption(_ path: String) -> String { "\"" + path.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}
