import DevVMProvisioningCore
import Foundation

/// Public observation keeps readiness consumers source-compatible. Authenticated
/// evidence is internal, ephemeral and supplied only by the pinned SSH monitor.
public struct SSHReadinessObservation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "SSHReadinessObservation(redacted)" }
    public var debugDescription: String { description }
    public let readiness: SSHReadiness
    let identity: ProvisioningAuthenticatedIdentity?
    public init(readiness: SSHReadiness) { self.readiness = readiness; identity = nil }
    init(readiness: SSHReadiness, identity: ProvisioningAuthenticatedIdentity) { self.readiness = readiness; self.identity = identity }
}
struct ProvisioningAuthenticatedIdentity: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let connection: ProvisioningSSHConnection
    let endpoint: ProvisioningManagedEndpoint
    let observedAt: ContinuousClock.Instant
    var description: String { "ProvisioningAuthenticatedIdentity(redacted)" }
    var debugDescription: String { description }
    func verify(now: ContinuousClock.Instant = .now) throws {
        guard observedAt <= now, now - observedAt <= .seconds(45) else { throw ProvisioningJobFailure.targetChanged }
        try connection.verify(); try endpoint.verify(target: connection.binding)
    }
}
/// Capture local pins before authentication, then validate the bounded identity
/// reply and the same files after it. No key bytes, guest-status UID or saved
/// journal can manufacture this evidence; construction itself starts no process.
struct ProvisioningSSHIdentityChallenge: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "ProvisioningSSHIdentityChallenge(redacted)" }
    var debugDescription: String { description }
    let request: VMStartRequest
    let user: String
    let endpoint: ProvisioningManagedEndpoint
    let hostKey: Data
    let identity: ProvisioningIdentityFile
    init(request: VMStartRequest, user: String) throws {
        guard ManagedSSHProbe.validUser(user), !request.profile.isRetainedPOC, let port = request.profile.ssh?.hostPort,
              (1024...65535).contains(port), request.profile.ownerSetup.map({ $0.configuration.username == user }) ?? true else { throw ProvisioningJobFailure.targetChanged }
        let observed = try ProvisioningManagedEndpoint.observe(root: request.storageRoot, port: UInt16(port), vmID: request.profile.id, sessionID: request.sessionID)
        self.request = request; self.user = user; endpoint = observed.endpoint; hostKey = observed.hostKey
        identity = try .init(ManagedSSHStorage(root: request.storageRoot).clientKey.standardizedFileURL)
    }
    func complete(_ result: SSHProbeProcess.Result, now: ContinuousClock.Instant = .now) throws -> ProvisioningAuthenticatedIdentity {
        guard result.status == 0, !result.hostKeyMismatch, result.output.count <= 4096,
              case .object(let fields) = try PlainDataParser.parse(result.output, format: .json), Set(fields.keys) == ["vmID", "sessionToken", "user", "uid"],
              fields["vmID"] == .string(request.profile.id.uuidString) || fields["vmID"] == .string(request.profile.id.uuidString.lowercased()),
              fields["sessionToken"] == .string(request.sessionID.uuidString) || fields["sessionToken"] == .string(request.sessionID.uuidString.lowercased()),
              fields["user"] == .string(user), case .integer(let uid) = fields["uid"], (1000..<60000).contains(uid) else { throw ProvisioningJobFailure.targetChanged }
        let binding = try GuestBinding(vmID: request.profile.id, sessionID: request.sessionID, owner: user, ownerUID: UInt32(uid), hostKeyDigest: KitVerifier.sha256(hostKey))
        let connection = try ProvisioningSSHConnection(binding: binding, port: endpoint.port, identity: identity, ed25519HostKey: hostKey)
        let value = ProvisioningAuthenticatedIdentity(connection: connection, endpoint: endpoint, observedAt: now)
        try value.verify(now: now); return value
    }
}
