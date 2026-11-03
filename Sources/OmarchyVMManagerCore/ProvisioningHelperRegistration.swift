import DevVMProvisioningCore
import Foundation

/// Metadata-only reservation. There is no executable plan, source, target
/// credential, process invocation or start command in a registration.
struct ProvisioningHelperWorkerRegistration: Codable, Equatable, Sendable {
    var scope: ProvisioningRecoveryExpectation
    let planDigest: String
    let inputDigest: String
    let mode: ProvisioningMode
    var delivery: ProvisioningFrozenDeliveryReceipt? = nil
    func validate() throws {
        try scope.validate()
        try delivery?.validate()
        guard provisioningDigest(planDigest), provisioningDigest(inputDigest) else { throw ProvisioningHelperIPCFailure.protocolViolation }
    }
    var digest: String { get throws { KitVerifier.sha256(try helperJSON(self)) } }
    static func validateDocument(_ value: ManifestValue) throws {
        let required: Set<String> = ["scope", "planDigest", "inputDigest", "mode"]
        guard case .object(let fields) = value, required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(["delivery"])) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        try validateExpectation(fields["scope"])
        if let delivery = fields["delivery"] { try ProvisioningFrozenDeliveryReceipt.validateDocument(delivery) }
    }
}
struct ProvisioningHelperRegistrationReceipt: Codable, Sendable {
    let identity: ProvisioningHelperIdentity
    let registrationDigest: String
    let state: String
    var deliveryDigest: String? = nil
    static func decode(_ data: Data) throws -> Self {
        guard case .object(let fields) = try PlainDataParser.parse(data, format: .json),
              Set(fields.keys) == ["identity", "registrationDigest", "state"] || Set(fields.keys) == ["identity", "registrationDigest", "state", "deliveryDigest"] else { throw ProvisioningHelperIPCFailure.protocolViolation }
        guard let identity = fields["identity"] else { throw ProvisioningHelperIPCFailure.protocolViolation }
        try ProvisioningHelperCredentials.validateIdentity(identity)
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.identity.validate()
        guard value.state == "registered", provisioningDigest(value.registrationDigest) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        if fields["deliveryDigest"] != nil { guard let digest = value.deliveryDigest, provisioningDigest(digest) else { throw ProvisioningHelperIPCFailure.protocolViolation } }
        return value
    }
}
protocol ProvisioningFrozenHelperLaunching: ProvisioningHelperLaunching {
    func prepare(_ registration: ProvisioningHelperWorkerRegistration, delivery: ProvisioningFrozenDeliverySource) async throws -> ProvisioningHelperLaunchTicket
}
struct ProvisioningHelperLaunchTicket: Sendable, Equatable {
    let id: UUID
    let identity: ProvisioningHelperIdentity
    let registration: ProvisioningHelperWorkerRegistration
}
protocol ProvisioningHelperLaunching: ProvisioningRecoveryAuthorizing {
    /// No child launch here: the resulting owner must be journaled first.
    func prepare(_ registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperLaunchTicket
    func launch(_ ticket: ProvisioningHelperLaunchTicket) async throws -> ProvisioningHelperRegistrationReceipt
    func abandon(_ ticket: ProvisioningHelperLaunchTicket) async
}
