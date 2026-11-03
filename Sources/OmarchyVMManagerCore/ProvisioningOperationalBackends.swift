import DevVMProvisioningCore
import Foundation

/// Build-time acceptance gate only. No environment, manifest, tool readiness,
/// command-line option or saved receipt can enable product execution.
enum ProvisioningProductExecution { static let enabled = false }

struct ProvisioningRecoveryTransportAuthority: ProvisioningSessionAuthority {
    let manager: VMManager
    let admission: ProvisioningTransportAdmission
    let admitPackage: @Sendable () throws -> Void
    func revalidate(_ binding: GuestBinding, dependencyDigest: String) async throws {
        guard binding == admission.target, dependencyDigest == admission.dependencyDigest else { throw SequencingFailure.identityMismatch }
        try admitPackage()
        guard try await manager.resolveProvisioningTarget(vmID: binding.vmID, sessionID: binding.sessionID, cleanup: true) == binding else { throw SequencingFailure.identityMismatch }
        try await manager.validateProvisioningTransport(admission, cleanup: true)
        try admitPackage()
    }
}
/// Trusted inert constructors. Worker use is behind frozen-input, inherited IPC,
/// original registration, transport, manager authority and the product gate.
/// Recovery construction is additionally behind original-worker fencing and the
/// deferred cleanup-only command scope; this is never a public adapter factory.
enum ProvisioningOperationalBackends {
    static func worker(input: ProvisioningValidatedFrozenContext, terminal: ProvisioningTerminal, layout: ProvisioningPackageLayout) throws -> any ProvisioningProcessRunner {
        try BundledProvisioning.localRuntime(for: input, layout: layout, terminal: terminal).runner
    }
    static func recovery(admission: ProvisioningTransportAdmission, authority: any ProvisioningSessionAuthority,
                         admitPackage: @Sendable () throws -> Void,
                         makeRunner: @Sendable () throws -> any ProvisioningProcessRunner) throws -> any ProvisioningGuestAdapter {
        try admitPackage()
        let reference = try admission.selection.verify(target: admission.target, policy: admission.policy)
        try reference.connection.verify(); try reference.tools.verify(); try admitPackage()
        return try SSHAnsibleGuestAdapter(connection: reference.connection, tools: reference.tools, authority: authority, runner: makeRunner())
    }
}
