import DevVMProvisioningCore
import Foundation

struct ProvisioningTransportReceipt: Codable, Equatable, Sendable {
    let format: Int
    let sha256: String
    let byteCount: Int
    let dependencyDigest: String
    func validate() throws {
        guard format == 1, byteCount > 2, byteCount <= ProvisioningTransportHandoff.maximumBytes,
              provisioningDigest(sha256), provisioningDigest(dependencyDigest) else { throw ProvisioningJobFailure.invalidRequest }
    }
    static func validateDocument(_ value: ManifestValue) throws { _ = try transportFields(value, required: ["format", "sha256", "byteCount", "dependencyDigest"]) }
}
/// Ephemeral private metadata. Never persisted or placed in control/terminal
/// frames. Only its non-secret receipt enters registration/journal/status.
struct ProvisioningTransportHandoff: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumBytes = 128 * 1024
    let bytes: Data
    let receipt: ProvisioningTransportReceipt
    let admission: ProvisioningTransportAdmission
    var description: String { "ProvisioningTransportHandoff(redacted)" }
    var debugDescription: String { description }
    fileprivate struct Document: Codable {
        let format: Int
        let scope: ProvisioningRecoveryExpectation
        let planDigest: String, inputDigest: String
        let mode: ProvisioningMode
        let selection: ProvisioningTransportSelection
    }
    init(admission: ProvisioningTransportAdmission, registration: ProvisioningHelperWorkerRegistration) throws {
        try admission.verify()
        guard registration.sessionAuthorityVersion == 1, registration.delivery != nil,
              admission.dependencyDigest == registration.scope.dependencyDigest,
              try ProvisioningCoordinator.bindingIdentity(admission.target) == registration.scope.bindingDigest else { throw ProvisioningJobFailure.invalidRequest }
        var scope = registration.scope; scope.helperIdentity = nil
        let document = Document(format: 1, scope: scope, planDigest: registration.planDigest, inputDigest: registration.inputDigest, mode: registration.mode, selection: admission.selection)
        bytes = try helperJSON(document)
        receipt = .init(format: 1, sha256: KitVerifier.sha256(bytes), byteCount: bytes.count, dependencyDigest: admission.dependencyDigest)
        try receipt.validate(); self.admission = admission
    }
    func verify(_ registration: ProvisioningHelperWorkerRegistration) throws {
        guard registration.transport == receipt else { throw ProvisioningJobFailure.invalidRequest }
        try admission.verify()
        _ = try Self.document(bytes, registration: registration)
    }
    fileprivate static func document(_ bytes: Data, registration: ProvisioningHelperWorkerRegistration) throws -> Document {
        guard let receipt = registration.transport else { throw ProvisioningJobFailure.invalidRequest }
        try receipt.validate()
        guard bytes.count == receipt.byteCount, bytes.count <= maximumBytes, KitVerifier.sha256(bytes) == receipt.sha256 else { throw ProvisioningJobFailure.invalidRequest }
        let fields = try transportFields(PlainDataParser.parse(bytes, format: .json), required: ["format", "scope", "planDigest", "inputDigest", "mode", "selection"])
        try validateExpectation(fields["scope"]); try ProvisioningTransportSelection.validateDocument(fields["selection"]!)
        let document = try JSONDecoder().decode(Document.self, from: bytes)
        var expected = registration.scope; expected.helperIdentity = nil
        guard document.format == 1, document.scope == expected, document.planDigest == registration.planDigest,
              document.inputDigest == registration.inputDigest, document.mode == registration.mode,
              try document.selection.dependencyDigest == receipt.dependencyDigest,
              receipt.dependencyDigest == registration.scope.dependencyDigest else { throw ProvisioningJobFailure.invalidRequest }
        return document
    }
}
struct ProvisioningValidatedTransport: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let receipt: ProvisioningTransportReceipt
    let selection: ProvisioningTransportSelection
    let target: GuestBinding
    let policy: ProvisioningTransportPolicy
    var description: String { "ProvisioningValidatedTransport(redacted)" }
    var debugDescription: String { description }
    static func load(_ bytes: Data, registration: ProvisioningHelperWorkerRegistration, input: ProvisioningValidatedFrozenContext, policy: ProvisioningTransportPolicy) throws -> Self {
        try registration.validate()
        let document = try ProvisioningTransportHandoff.document(bytes, registration: registration)
        guard input.receipt == registration.delivery, input.request.reviewIdentity == registration.scope.reviewDigest,
              input.request.dependencyDigest == (try document.selection.dependencyDigest) else { throw ProvisioningJobFailure.invalidRequest }
        _ = try document.selection.verify(target: input.request.target, policy: policy)
        return .init(receipt: registration.transport!, selection: document.selection, target: input.request.target, policy: policy)
    }
    func verify() throws -> ProvisioningTransportReference { try selection.verify(target: target, policy: policy) }
}
struct ProvisioningDeliveredTransportProvider: ProvisioningHelperTransportProviding {
    let transport: ProvisioningValidatedTransport
    let makeProcessRunner: @Sendable () throws -> any ProvisioningProcessRunner
    func resources(for input: ProvisioningValidatedFrozenContext, registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperTransportResources {
        guard registration.transport == transport.receipt, input.request.target == transport.target,
              input.request.dependencyDigest == transport.receipt.dependencyDigest else { throw ProvisioningJobFailure.invalidRequest }
        let reference = try transport.verify()
        return .init(connection: reference.connection, tools: reference.tools, dependencyDigest: transport.receipt.dependencyDigest, makeProcessRunner: makeProcessRunner)
    }
}
protocol ProvisioningTransportHelperLaunching: ProvisioningManagerSessionLaunching {
    func prepare(_ registration: ProvisioningHelperWorkerRegistration, delivery: ProvisioningFrozenDeliverySource, transport: ProvisioningTransportHandoff) async throws -> ProvisioningHelperLaunchTicket
}
