import DevVMProvisioningCore
import Foundation

/// Activation names a locally prepared context; it transports no plan, path,
/// executable, credential, terminal byte or guest-discovery parameter.
struct ProvisioningHelperActivation: Codable, Equatable, Sendable {
    let activationID: UUID
    let registrationDigest: String
    let scope: ProvisioningRecoveryExpectation
    var customTasksReviewed = false
    var persistentGrantAcknowledged = false
    var dockerRootAccessAcknowledged = false
    var digest: String { get throws { KitVerifier.sha256(try helperJSON(self)) } }
    func validate() throws {
        try scope.validate()
        guard scope.helperIdentity != nil, provisioningDigest(registrationDigest) else { throw ProvisioningHelperIPCFailure.protocolViolation }
    }
    static func validateDocument(_ value: ManifestValue?) throws {
        guard case .object(let fields) = value, Set(fields.keys) == ["activationID", "registrationDigest", "scope", "customTasksReviewed", "persistentGrantAcknowledged", "dockerRootAccessAcknowledged"] else { throw ProvisioningHelperIPCFailure.protocolViolation }
        try validateExpectation(fields["scope"])
    }
}
enum ProvisioningHelperDispatchKind: String, Codable, Sendable { case activate, status, cancel }
enum ProvisioningHelperDispatchDenial: String, Codable, Error, Sendable {
    case executionUnavailable, ownership, activationConflict, fenced
}
enum ProvisioningHelperWorkerPhase: String, Codable, Sendable { case preparing, running, cancelling, finalizing, completed, fenced }
struct ProvisioningHelperWorkerSnapshot: Codable, Sendable, Equatable {
    let activationID: UUID
    let activationDigest: String
    let sequence: UInt64
    let phase: ProvisioningHelperWorkerPhase
    let operation: GuestOperation?
    let commandID: UUID?
    let outcome: ProvisioningOutcome?
    let primaryFailure: SequencingFailure?
    let cleanupFailures: [SequencingFailure]
    let cleanupRequired: Bool
    var terminal: Bool { [.completed, .fenced].contains(phase) && outcome != nil }
    func validate() throws {
        guard sequence > 0, sequence <= UInt64(Int64.max), provisioningDigest(activationDigest), cleanupFailures.count <= 32,
              outcome == nil || [.completed, .fenced].contains(phase),
              ![.completed, .fenced].contains(phase) || outcome != nil,
              (operation == nil) == (commandID == nil),
              ![.applied, .appliedRestartRequired, .checked, .cleanupConfirmed].contains(outcome) || !cleanupRequired,
              outcome != .cleanupRequired || cleanupRequired else { throw ProvisioningHelperIPCFailure.protocolViolation }
    }
    static func validateDocument(_ value: ManifestValue) throws {
        let required: Set<String> = ["activationID", "activationDigest", "sequence", "phase", "cleanupFailures", "cleanupRequired"]
        guard case .object(let fields) = value, required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(["operation", "commandID", "outcome", "primaryFailure"])) else { throw ProvisioningHelperIPCFailure.protocolViolation }
    }
}
struct ProvisioningHelperDispatchRequest: Codable, Sendable {
    let kind: ProvisioningHelperDispatchKind
    let requestID: UUID
    let activation: ProvisioningHelperActivation
    static func decode(_ data: Data) throws -> Self {
        let object = try helperObject(data, keys: ["kind", "requestID", "activation"])
        try ProvisioningHelperActivation.validateDocument(object["activation"])
        let value = try JSONDecoder().decode(Self.self, from: data); try value.activation.validate(); return value
    }
}
struct ProvisioningHelperDispatchResponse: Codable, Sendable {
    let kind: ProvisioningHelperDispatchKind
    let requestID: UUID
    let activation: ProvisioningHelperActivation
    let status: ProvisioningHelperWorkerSnapshot?
    let denial: ProvisioningHelperDispatchDenial?
    static func decode(_ data: Data) throws -> Self {
        guard case .object(let fields) = try PlainDataParser.parse(data, format: .json),
              Set(fields.keys) == ["kind", "requestID", "activation", "status"] || Set(fields.keys) == ["kind", "requestID", "activation", "denial"] else { throw ProvisioningHelperIPCFailure.protocolViolation }
        try ProvisioningHelperActivation.validateDocument(fields["activation"])
        if let status = fields["status"] { try ProvisioningHelperWorkerSnapshot.validateDocument(status) }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.activation.validate(); try value.status?.validate(); return value
    }
}
protocol ProvisioningHelperDispatching: ProvisioningHelperLaunching {
    func dispatch(_ kind: ProvisioningHelperDispatchKind, activation: ProvisioningHelperActivation) async throws -> ProvisioningHelperWorkerSnapshot
    func abort(_ activation: ProvisioningHelperActivation) async
}

/// Trusted helper-local preparation only. It must not launch processes or run
/// guest operations. Product entry points supply no transport resource provider.
protocol ProvisioningHelperEnginePreparing: Sendable {
    func prepare(_ registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperEngineContext
}
struct ProvisioningHelperEngineContext: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let request: ProvisioningRequest
    let approval: ProvisioningApproval
    let adapter: any ProvisioningGuestAdapter
    let authority: any ProvisioningSessionAuthority
    let runner: ProvisioningFencedProcessRunner
    var admitPackage: @Sendable () throws -> Void = {}
    var frozenContext: ProvisioningValidatedFrozenContext? = nil
    var description: String { "ProvisioningHelperEngineContext(redacted)" }
    var debugDescription: String { description }
}
