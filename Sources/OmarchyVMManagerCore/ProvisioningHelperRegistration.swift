import DevVMProvisioningCore
import Foundation

/// Metadata-only reservation. There is no executable plan, source, target
/// credential, process invocation or start command in a registration.
struct ProvisioningHelperWorkerRegistration: Codable, Equatable, Sendable {
    var scope: ProvisioningRecoveryExpectation
    let planDigest: String
    let inputDigest: String
    let mode: ProvisioningMode
    func validate() throws {
        try scope.validate()
        guard provisioningDigest(planDigest), provisioningDigest(inputDigest) else { throw ProvisioningHelperIPCFailure.protocolViolation }
    }
    var digest: String { get throws { KitVerifier.sha256(try helperJSON(self)) } }
    static func validateDocument(_ value: ManifestValue) throws {
        guard case .object(let fields) = value, Set(fields.keys) == ["scope", "planDigest", "inputDigest", "mode"] else { throw ProvisioningHelperIPCFailure.protocolViolation }
        try validateExpectation(fields["scope"])
    }
}
struct ProvisioningHelperRegistrationReceipt: Codable, Sendable {
    let identity: ProvisioningHelperIdentity
    let registrationDigest: String
    let state: String
    static func decode(_ data: Data) throws -> Self {
        let fields = try helperObject(data, keys: ["identity", "registrationDigest", "state"])
        guard let identity = fields["identity"] else { throw ProvisioningHelperIPCFailure.protocolViolation }
        try ProvisioningHelperCredentials.validateIdentity(identity)
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.identity.validate()
        guard value.state == "registered", provisioningDigest(value.registrationDigest) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        return value
    }
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
