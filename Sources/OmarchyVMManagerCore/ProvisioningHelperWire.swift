import CryptoKit
import DevVMProvisioningCore
import Foundation

// Private control protocol. Raw terminal/input/source bytes have no wire type.
enum ProvisioningHelperIPCFailure: String, Error, Sendable {
    case authentication, protocolViolation, unavailable, timeout, ownership
}
struct ProvisioningHelperIdentity: Codable, Equatable, Sendable {
    let instanceID: UUID
    let executableSHA256: String
    let packageLockSHA256: String
    func validate() throws {
        guard provisioningDigest(executableSHA256), provisioningDigest(packageLockSHA256) else { throw ProvisioningHelperIPCFailure.authentication }
    }
}
struct ProvisioningHelperCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let identity: ProvisioningHelperIdentity
    let channelID: UUID
    private let secret: Data
    let registration: ProvisioningHelperWorkerRegistration?
    var description: String { "ProvisioningHelperCredentials(redacted)" }
    var debugDescription: String { description }
    init(identity: ProvisioningHelperIdentity, registration: ProvisioningHelperWorkerRegistration? = nil) throws {
        try identity.validate()
        self.identity = identity; channelID = UUID()
        self.registration = registration
        if let registration { try registration.validate(); guard registration.scope.helperIdentity == identity else { throw ProvisioningHelperIPCFailure.ownership } }
        let key = SymmetricKey(size: .bits256)
        secret = key.withUnsafeBytes { Data($0) }
    }
    private struct Bootstrap: Codable {
        let version: Int
        let identity: ProvisioningHelperIdentity
        let channelID: UUID
        let secret: Data
        let registration: ProvisioningHelperWorkerRegistration?
    }
    /// Anonymous bootstrap pipe only; never argv, environment, disk or diagnostics.
    func privateBootstrap() throws -> Data {
        try helperJSON(Bootstrap(version: registration?.delivery != nil ? 3 : registration == nil ? 1 : 2, identity: identity, channelID: channelID, secret: secret, registration: registration))
    }
    init(privateBootstrap data: Data) throws {
        guard data.count <= 4096, case .object(let fields) = try PlainDataParser.parse(data, format: .json) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        let base: Set<String> = ["version", "identity", "channelID", "secret"]
        guard (fields["version"] == .integer(1) && Set(fields.keys) == base) || ([ManifestValue.integer(2), .integer(3)].contains(fields["version"] ?? .null) && Set(fields.keys) == base.union(["registration"])) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        guard let identity = fields["identity"] else { throw ProvisioningHelperIPCFailure.protocolViolation }
        try Self.validateIdentity(identity)
        if let registration = fields["registration"] { try ProvisioningHelperWorkerRegistration.validateDocument(registration) }
        let value = try JSONDecoder().decode(Bootstrap.self, from: data)
        try value.identity.validate()
        guard value.secret.count == 32 else { throw ProvisioningHelperIPCFailure.authentication }
        self.identity = value.identity; channelID = value.channelID; secret = value.secret
        registration = value.registration
        guard (fields["version"] == .integer(3)) == (registration?.delivery != nil) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        if let registration { try registration.validate(); guard registration.scope.helperIdentity == value.identity else { throw ProvisioningHelperIPCFailure.ownership } }
    }
    static func validateIdentity(_ value: ManifestValue) throws {
        guard case .object(let fields) = value, Set(fields.keys) == ["instanceID", "executableSHA256", "packageLockSHA256"] else { throw ProvisioningHelperIPCFailure.protocolViolation }
    }
    fileprivate var key: SymmetricKey { SymmetricKey(data: secret) }
}
enum ProvisioningHelperRole: String, Codable, Sendable { case manager, helper }

/// Direction, peer launch identity, connection and monotonically increasing
/// sequence are authenticated along with the exact payload bytes.
struct ProvisioningHelperFrameCodec: Sendable {
    private let credentials: ProvisioningHelperCredentials
    let role: ProvisioningHelperRole
    private var sending: UInt64 = 0, receiving: UInt64 = 0
    private struct Signed: Codable {
        let version: Int
        let identity: ProvisioningHelperIdentity
        let channelID: UUID
        let role: ProvisioningHelperRole
        let sequence: UInt64
        let payload: Data
    }
    private struct Envelope: Codable { let signed: Signed; let mac: Data }
    static let maximumFrameBytes = 24 * 1024
    init(credentials: ProvisioningHelperCredentials, role: ProvisioningHelperRole) { self.credentials = credentials; self.role = role }
    mutating func encode(_ payload: Data) throws -> Data {
        guard sending < UInt64(Int64.max), payload.count <= 12 * 1024 else { throw ProvisioningHelperIPCFailure.protocolViolation }
        let signed = Signed(version: 1, identity: credentials.identity, channelID: credentials.channelID, role: role, sequence: sending + 1, payload: payload)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: try helperJSON(signed), using: credentials.key))
        let result = try helperJSON(Envelope(signed: signed, mac: mac))
        guard result.count <= Self.maximumFrameBytes else { throw ProvisioningHelperIPCFailure.protocolViolation }
        sending += 1; return result
    }
    mutating func decode(_ data: Data) throws -> Data {
        guard data.count <= Self.maximumFrameBytes else { throw ProvisioningHelperIPCFailure.protocolViolation }
        let envelope = try helperObject(data, keys: ["signed", "mac"])
        guard case .object(let signed) = envelope["signed"], Set(signed.keys) == ["version", "identity", "channelID", "role", "sequence", "payload"],
              let identity = signed["identity"] else { throw ProvisioningHelperIPCFailure.protocolViolation }
        try ProvisioningHelperCredentials.validateIdentity(identity)
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        guard value.signed.version == 1, value.signed.identity == credentials.identity,
              value.signed.channelID == credentials.channelID, value.signed.role != role,
              receiving < UInt64(Int64.max), value.signed.sequence == receiving + 1,
              value.signed.payload.count <= 12 * 1024, value.mac.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(value.mac, authenticating: try helperJSON(value.signed), using: credentials.key)
        else { throw ProvisioningHelperIPCFailure.authentication }
        receiving += 1; return value.signed.payload
    }
}
struct ProvisioningHelperReconcileRequest: Codable, Sendable {
    let requestID: UUID
    let expectation: ProvisioningRecoveryExpectation
    static func decode(_ data: Data) throws -> Self {
        let object = try helperObject(data, keys: ["requestID", "expectation"])
        try validateExpectation(object["expectation"])
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.expectation.validate(); return value
    }
}
struct ProvisioningHelperReconcileResponse: Codable, Sendable {
    let requestID: UUID
    let expectation: ProvisioningRecoveryExpectation
    let priorWorker: ProvisioningPriorWorkerState
    static func decode(_ data: Data) throws -> Self {
        let object = try helperObject(data, keys: ["requestID", "expectation", "priorWorker"])
        try validateExpectation(object["expectation"])
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.expectation.validate(); return value
    }
}
func validateExpectation(_ value: ManifestValue?) throws {
    let required: Set<String> = ["challenge", "jobID", "vmID", "sessionID", "payloadID", "workerToken", "engineDigest", "dependencyDigest", "bindingDigest", "reviewDigest", "checkpointDigest"]
    guard case .object(let fields) = value, required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(["helperIdentity"])) else { throw ProvisioningHelperIPCFailure.protocolViolation }
    if let identity = fields["helperIdentity"] { try ProvisioningHelperCredentials.validateIdentity(identity) }
}
func helperJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
func helperObject(_ data: Data, keys: Set<String>) throws -> [String: ManifestValue] {
    guard data.count <= ProvisioningHelperFrameCodec.maximumFrameBytes,
          case .object(let object) = try PlainDataParser.parse(data, format: .json), Set(object.keys) == keys
    else { throw ProvisioningHelperIPCFailure.protocolViolation }
    return object
}
