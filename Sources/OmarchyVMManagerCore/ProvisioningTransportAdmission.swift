import Darwin
import DevVMProvisioningCore
import Foundation

/// Explicit internal fixture policy only. No wire/environment/CLI flag chooses it.
enum ProvisioningTransportPolicy: Sendable {
    case host
    case fixture(URL)
    func allows(_ path: String, tool: ProvisioningTool) -> Bool {
        switch self {
        case .host:
            if [.bash, .ssh, .scp, .sftp].contains(tool) { return path == (tool == .bash ? "/bin/bash" : "/usr/bin/" + tool.rawValue) }
            return true // Homebrew membership and matching expected entry checked below.
        case .fixture(let root):
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
        }
    }
}
struct ProvisioningTransportToolEvidence: Codable, Equatable, Sendable {
    let provider: String
    let version: String?
    let executable: ProvisioningToolIdentity
    let installation: ProvisioningToolIdentity?
    init(_ value: ProvisioningToolResult) throws {
        guard value.status == .available, let executable = value.executable else { throw ProvisioningJobFailure.dependencyChanged }
        provider = value.provider; version = value.version; self.executable = executable; installation = value.installation
    }
}
struct ProvisioningTransportToolAdmission: Codable, Sendable {
    let tools: [String: ProvisioningTransportToolEvidence]
    static let required: Set<ProvisioningTool> = [.brew, .bash, .ssh, .scp, .sftp, .ansiblePlaybook, .ansibleInventory]
    init(report: ProvisioningToolReport, policy: ProvisioningTransportPolicy) throws {
        guard report.schemaVersion == 2, Set(report.tools.map(\.tool)).count == report.tools.count else { throw ProvisioningJobFailure.dependencyChanged }
        tools = try Dictionary(uniqueKeysWithValues: Self.required.map { tool in
            guard let value = report.tool(tool) else { throw ProvisioningJobFailure.dependencyChanged }
            return (tool.rawValue, try ProvisioningTransportToolEvidence(value))
        })
        try verify(policy: policy)
    }
    func verify(policy: ProvisioningTransportPolicy) throws {
        guard Set(tools.keys) == Set(Self.required.map(\.rawValue)) else { throw ProvisioningJobFailure.dependencyChanged }
        let files = LocalProvisioningToolFiles()
        for (name, value) in tools {
            guard let tool = ProvisioningTool(rawValue: name), provisioningDigest(value.executable.fingerprint),
                  ProvisioningToolConfiguration.validPath(value.executable.path), policy.allows(value.executable.path, tool: tool),
                  files.executable(value.executable.path)?.identity == value.executable else { throw ProvisioningJobFailure.dependencyChanged }
            if [.bash, .ssh, .scp, .sftp].contains(tool) {
                guard value.provider == "macOS", value.installation == nil else { throw ProvisioningJobFailure.dependencyChanged }
                if tool == .bash || tool == .ssh { guard value.version != nil else { throw ProvisioningJobFailure.dependencyChanged } }
            }
        }
        guard let brew = tools["brew"], brew.version?.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              ["host", "override"].contains(brew.provider), brew.installation == nil,
              let playbook = tools["ansible-playbook"], let inventory = tools["ansible-inventory"],
              let installation = playbook.installation, inventory.installation == installation,
              provisioningDigest(installation.fingerprint), let current = files.directory(installation.path), current.identity == installation,
              playbook.version == inventory.version, playbook.version?.range(of: "^2\\.21\\.[0-9]+$", options: .regularExpression) != nil else { throw ProvisioningJobFailure.dependencyChanged }
        for name in ["ansible-playbook", "ansible-inventory"] {
            let item = tools[name]!
            guard ["homebrew", "override"].contains(item.provider), URL(fileURLWithPath: item.executable.path).lastPathComponent == name,
                  let actual = files.executable(item.executable.path), let expected = files.executable(installation.path + "/bin/" + name),
                  actual.resolvedPath == expected.resolvedPath, actual.resolvedPath.hasPrefix(current.resolvedPath + "/"),
                  URL(fileURLWithPath: actual.resolvedPath).lastPathComponent == name else { throw ProvisioningJobFailure.dependencyChanged }
        }
    }
    var executablePaths: [String: URL] {
        Dictionary(uniqueKeysWithValues: ["ssh", "scp", "sftp", "ansible-playbook", "ansible-inventory"].map { ($0, URL(fileURLWithPath: tools[$0]!.executable.path).standardizedFileURL) })
    }
    func sharedTools() throws -> ProvisioningTransportTools {
        func pin(_ name: String) throws -> ProvisioningExecutablePin { try .init(executablePaths[name]!) }
        return try .init(ssh: pin("ssh"), scp: pin("scp"), sftp: pin("sftp"), ansiblePlaybook: pin("ansible-playbook"), ansibleInventory: pin("ansible-inventory"))
    }
    static func validateDocument(_ value: ManifestValue) throws {
        let fields = try transportFields(value, required: ["tools"])
        let tools = try transportFields(fields["tools"]!, required: Set(Self.required.map(\.rawValue)))
        for value in tools.values {
            let item = try transportFields(value, required: ["provider", "executable"], optional: ["version", "installation"])
            _ = try transportFields(item["executable"]!, required: ["path", "fingerprint"])
            if let installation = item["installation"] { _ = try transportFields(installation, required: ["path", "fingerprint"]) }
            if let version = item["version"] { guard case .string = version else { throw ProvisioningJobFailure.invalidRequest } }
        }
    }
}

/// Public managed-SSH metadata and a stat-only credential reference, all rooted
/// in one exact manager-owned UUID tree. No prepare/generate/validate(key-read).
struct ProvisioningManagedEndpoint: Codable, Equatable, Sendable {
    let root: String
    let rootDevice: Int64, rootInode: UInt64
    let port: UInt16
    let manifestSHA256: String, bootstrapSHA256: String, knownHostsSHA256: String
    static func observe(root: URL, port: UInt16, vmID: UUID, sessionID: UUID) throws -> (endpoint: Self, hostKey: Data) {
        guard root.isFileURL, root.path.hasPrefix("/"), root.path.utf8.count <= 4096,
              !root.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !root.path.split(separator: "/").contains("..") else { throw ProvisioningJobFailure.invalidRequest }
        try PrivateFiles.directory(root)
        let storage = ManagedSSHStorage(root: root)
        try PrivateFiles.directory(storage.directory); try PrivateFiles.directory(storage.bootstrap)
        var info = stat(); guard lstat(root.path, &info) == 0, port >= 1024 else { throw ProvisioningJobFailure.targetChanged }
        let manifest = try PrivateFiles.read(root.appendingPathComponent(ManagedSSHStorage.manifestName))
        let bootstrap = try PrivateFiles.read(storage.bootstrap.appendingPathComponent("manifest.json"))
        func document(_ data: Data, bootstrap: Bool) throws {
            let fields = try transportFields(PlainDataParser.parse(data, format: .json), required: bootstrap ? ["schemaVersion", "vmID", "sessionToken", "publicKeys"] : ["schemaVersion", "vmID", "sessionToken", "hostPort"])
            guard fields["schemaVersion"] == .integer(1), fields["vmID"] == .string(vmID.uuidString),
                  fields["sessionToken"] == .string(sessionID.uuidString) else { throw ProvisioningJobFailure.targetChanged }
            if bootstrap {
                guard case .array(let keys) = fields["publicKeys"], !keys.isEmpty, keys.count <= 16 else { throw ProvisioningJobFailure.targetChanged }
                for key in keys { guard case .string(let text) = key else { throw ProvisioningJobFailure.targetChanged }; _ = try SSHPublicKey.canonical(text) }
            } else { guard fields["hostPort"] == .integer(Int64(port)) else { throw ProvisioningJobFailure.targetChanged } }
        }
        try document(manifest, bootstrap: false); try document(bootstrap, bootstrap: true)
        let known = try PrivateFiles.read(storage.knownHosts)
        guard let text = String(data: known, encoding: .utf8) else { throw ProvisioningJobFailure.targetChanged }
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3, fields[0] == Substring(storage.alias(vmID)), fields[1] == "ssh-ed25519",
              let blob = Data(base64Encoded: String(fields[2])), blob.count == 51,
              text == storage.alias(vmID) + " ssh-ed25519 " + blob.base64EncodedString() + "\n" else { throw ProvisioningJobFailure.targetChanged }
        _ = try SSHPublicKey.canonical("ssh-ed25519 " + blob.base64EncodedString())
        _ = try ProvisioningIdentityFile(storage.clientKey.standardizedFileURL)
        return (.init(root: root.standardizedFileURL.path, rootDevice: Int64(info.st_dev), rootInode: UInt64(info.st_ino), port: port,
            manifestSHA256: KitVerifier.sha256(manifest), bootstrapSHA256: KitVerifier.sha256(bootstrap), knownHostsSHA256: KitVerifier.sha256(known)), blob)
    }
    static func load(root: URL, port: UInt16, target: GuestBinding) throws -> Self {
        let observed = try observe(root: root, port: port, vmID: target.vmID, sessionID: target.sessionID)
        let storage = ManagedSSHStorage(root: root)
        _ = try ProvisioningSSHConnection(binding: target, port: port, identity: ProvisioningIdentityFile(storage.clientKey.standardizedFileURL), ed25519HostKey: observed.hostKey)
        return observed.endpoint
    }
    func verify(target: GuestBinding) throws {
        guard self == (try Self.load(root: URL(fileURLWithPath: root), port: port, target: target)) else { throw ProvisioningJobFailure.targetChanged }
    }
    func connection(target: GuestBinding) throws -> ProvisioningSSHConnection {
        try verify(target: target)
        let storage = ManagedSSHStorage(root: URL(fileURLWithPath: root))
        let known = String(decoding: try PrivateFiles.read(storage.knownHosts), as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard known.count == 3, let key = Data(base64Encoded: String(known[2])) else { throw ProvisioningJobFailure.targetChanged }
        return try .init(binding: target, port: port, identity: ProvisioningIdentityFile(storage.clientKey.standardizedFileURL), ed25519HostKey: key)
    }
    static func validateDocument(_ value: ManifestValue) throws {
        _ = try transportFields(value, required: ["root", "rootDevice", "rootInode", "port", "manifestSHA256", "bootstrapSHA256", "knownHostsSHA256"])
    }
}
func transportFields(_ value: ManifestValue, required: Set<String>, optional: Set<String> = []) throws -> [String: ManifestValue] {
    guard case .object(let fields) = value, required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(optional)) else { throw ProvisioningJobFailure.invalidRequest }
    return fields
}

struct ProvisioningTransportSelection: Codable, Sendable {
    let format: Int
    let endpoint: ProvisioningManagedEndpoint
    let report: ProvisioningTransportToolAdmission
    let reference: Data
    var dependencyDigest: String { get throws { KitVerifier.sha256(try helperJSON(self)) } }
    func verify(target: GuestBinding, policy: ProvisioningTransportPolicy) throws -> ProvisioningTransportReference {
        guard format == 1, reference.count <= ProvisioningTransportReference.maximumBytes else { throw ProvisioningJobFailure.invalidRequest }
        try endpoint.verify(target: target); try report.verify(policy: policy)
        let identity = ManagedSSHStorage(root: URL(fileURLWithPath: endpoint.root)).clientKey.standardizedFileURL
        let value = try ProvisioningTransportReference(privateData: reference, expectedBinding: target, expectedIdentityURL: identity, expectedExecutablePaths: report.executablePaths)
        guard value.connection.port == endpoint.port else { throw ProvisioningJobFailure.targetChanged }
        try endpoint.verify(target: target); try report.verify(policy: policy); return value
    }
    static func validateDocument(_ value: ManifestValue) throws {
        let fields = try transportFields(value, required: ["format", "endpoint", "report", "reference"])
        try ProvisioningManagedEndpoint.validateDocument(fields["endpoint"]!); try ProvisioningTransportToolAdmission.validateDocument(fields["report"]!)
    }
}
final class ProvisioningTransportAdmission: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let target: GuestBinding
    let selection: ProvisioningTransportSelection
    let policy: ProvisioningTransportPolicy
    let dependencyDigest: String
    var description: String { "ProvisioningTransportAdmission(redacted)" }
    var debugDescription: String { description }
    init(root: URL, port: UInt16, target: GuestBinding, report: ProvisioningToolReport, policy: ProvisioningTransportPolicy) throws {
        let endpoint = try ProvisioningManagedEndpoint.load(root: root, port: port, target: target)
        let tools = try ProvisioningTransportToolAdmission(report: report, policy: policy)
        let connection = try endpoint.connection(target: target)
        let reference = try ProvisioningTransportReference(connection: connection, tools: tools.sharedTools())
        selection = try .init(format: 1, endpoint: endpoint, report: tools, reference: reference.privateData())
        self.target = target; self.policy = policy; dependencyDigest = try selection.dependencyDigest
        _ = try selection.verify(target: target, policy: policy)
    }
    func verify() throws { _ = try selection.verify(target: target, policy: policy) }
}
