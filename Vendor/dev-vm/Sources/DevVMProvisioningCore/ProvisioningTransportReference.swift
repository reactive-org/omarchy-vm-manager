import Foundation

/// Explicit private metadata only: executable paths/hashes/stamps, public host
/// key and a stat-only identity reference. Never contains private-key bytes.
/// Import compares the original proofs; it does not bless replacement files.
public struct ProvisioningTransportReference: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumBytes = 64 * 1024
    public let connection: ProvisioningSSHConnection
    public let tools: ProvisioningTransportTools
    private let bytes: Data
    public var description: String { "ProvisioningTransportReference(redacted)" }
    public var debugDescription: String { description }
    public func privateData() throws -> Data { try connection.verify(); try tools.verify(); return bytes }

    private struct Binding: Codable {
        let vmID: UUID, sessionID: UUID
        let owner: String
        let ownerUID: UInt32
        let hostKeyDigest: String
        init(_ value: GuestBinding) { vmID = value.vmID; sessionID = value.sessionID; owner = value.owner; ownerUID = value.ownerUID; hostKeyDigest = value.hostKeyDigest }
        func value() throws -> GuestBinding { try .init(vmID: vmID, sessionID: sessionID, owner: owner, ownerUID: ownerUID, hostKeyDigest: hostKeyDigest) }
    }
    private struct Pin: Codable {
        let entry: String, target: String, sha256: String
        let stamp: FileStamp
        init(_ value: ProvisioningExecutablePin) { entry = value.entry.path; target = value.target.path; stamp = value.stamp; sha256 = value.sha256 }
        func value() throws -> ProvisioningExecutablePin {
            try path(entry); try path(target)
            guard matches(sha256, "[a-f0-9]{64}") else { throw SequencingFailure.invalidRequest }
            let current = try ProvisioningExecutablePin(URL(fileURLWithPath: entry))
            guard current.target.path == target, current.stamp == stamp, current.sha256 == sha256 else { throw SequencingFailure.dependencyChanged }
            return current
        }
    }
    private struct Identity: Codable {
        let path: String
        let stamp: FileStamp
        init(_ value: ProvisioningIdentityFile) { path = value.url.path; stamp = value.stamp }
        func value() throws -> ProvisioningIdentityFile {
            try ProvisioningTransportReference.path(path)
            let current = try ProvisioningIdentityFile(URL(fileURLWithPath: path))
            guard current.stamp == stamp else { throw SequencingFailure.identityMismatch }; return current
        }
    }
    private struct Document: Codable {
        let format: Int
        let binding: Binding
        let port: UInt16
        let hostKey: Data
        let identity: Identity
        let tools: [String: Pin]
    }
    public init(connection: ProvisioningSSHConnection, tools: ProvisioningTransportTools) throws {
        try connection.verify(); try tools.verify()
        let doc = Document(format: 1, binding: Binding(connection.binding), port: connection.port, hostKey: connection.hostKey,
            identity: Identity(connection.identity), tools: ["ssh": Pin(tools.ssh), "scp": Pin(tools.scp), "sftp": Pin(tools.sftp),
                "ansible-playbook": Pin(tools.playbook), "ansible-inventory": Pin(tools.inventory)])
        let data = try canonicalData(doc)
        try self.init(privateData: data, expectedBinding: connection.binding)
    }
    public init(privateData: Data, expectedBinding: GuestBinding, expectedIdentityURL: URL? = nil, expectedExecutablePaths: [String: URL]? = nil) throws {
        guard privateData.count <= Self.maximumBytes else { throw SequencingFailure.invalidRequest }
        let object = try PlainDataParser.parse(privateData, format: .json)
        let root = try fields(object, allowed: ["format", "binding", "port", "hostKey", "identity", "tools"], required: ["format", "binding", "port", "hostKey", "identity", "tools"])
        _ = try fields(root["binding"]!, allowed: ["vmID", "sessionID", "owner", "ownerUID", "hostKeyDigest"], required: ["vmID", "sessionID", "owner", "ownerUID", "hostKeyDigest"])
        let identity = try fields(root["identity"]!, allowed: ["path", "stamp"], required: ["path", "stamp"])
        try Self.stamp(identity["stamp"]!)
        let names: Set<String> = ["ssh", "scp", "sftp", "ansible-playbook", "ansible-inventory"]
        let toolFields = try fields(root["tools"]!, allowed: names, required: names)
        for value in toolFields.values {
            let pin = try fields(value, allowed: ["entry", "target", "sha256", "stamp"], required: ["entry", "target", "sha256", "stamp"])
            try Self.stamp(pin["stamp"]!)
        }
        let doc = try JSONDecoder().decode(Document.self, from: privateData)
        let binding = try doc.binding.value()
        guard doc.format == 1, binding == expectedBinding else { throw SequencingFailure.identityMismatch }
        if let expectedIdentityURL { guard doc.identity.path == expectedIdentityURL.standardizedFileURL.path else { throw SequencingFailure.identityMismatch } }
        if let expectedExecutablePaths {
            guard Set(expectedExecutablePaths.keys) == names, doc.tools.allSatisfy({ expectedExecutablePaths[$0.key]?.standardizedFileURL.path == $0.value.entry }) else { throw SequencingFailure.dependencyChanged }
        }
        connection = try .init(binding: binding, port: doc.port, identity: doc.identity.value(), ed25519HostKey: doc.hostKey)
        tools = try .init(ssh: doc.tools["ssh"]!.value(), scp: doc.tools["scp"]!.value(), sftp: doc.tools["sftp"]!.value(),
            ansiblePlaybook: doc.tools["ansible-playbook"]!.value(), ansibleInventory: doc.tools["ansible-inventory"]!.value())
        try connection.verify(); try tools.verify(); bytes = privateData
    }
    private static func path(_ value: String) throws {
        guard value.hasPrefix("/"), value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw SequencingFailure.invalidRequest }
        let url = URL(fileURLWithPath: value)
        guard url.path == value else { throw SequencingFailure.invalidRequest }
        try transportPath(url)
    }
    private static func stamp(_ value: ManifestValue) throws {
        let keys: Set<String> = ["device", "inode", "mode", "owner", "size", "modifiedSeconds", "modifiedNanos", "changedSeconds", "changedNanos", "links"]
        _ = try fields(value, allowed: keys, required: keys)
    }
}
