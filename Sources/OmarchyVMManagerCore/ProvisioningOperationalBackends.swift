import DevVMProvisioningCore
import Foundation

/// Build-time acceptance gate only. No environment, manifest, tool readiness,
/// command-line option or saved receipt can enable product execution.
enum ProvisioningProductExecution {
    // Optional private acceptance overlays retain their exact original scope,
    // even in Dev. Ordinary Dev builds use verified manager-owned Dev roots.
    // Neither policy can be chosen from writable metadata or a received packet.
    static let disposableApproval: ProvisioningDisposableAdmission? = nil
    static var enabled: Bool { disposableApproval != nil || AppChannel.current == .development }
    static func admission(applicationSupport: URL) -> ProvisioningExecutionAdmission {
        if let disposableApproval { return .disposable(disposableApproval) }
        guard AppChannel.current == .development else { return .disabled }
        return .development(.init(applicationSupport: applicationSupport))
    }
    static var admission: ProvisioningExecutionAdmission {
        if let disposableApproval { return .disposable(disposableApproval) }
        guard AppChannel.current == .development,
              let support = try? ProvisioningDevelopmentAdmission.accountApplicationSupport() else { return .disabled }
        return admission(applicationSupport: support)
    }
}

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
                         makeRunner: @Sendable () throws -> any ProvisioningProcessRunner,
                         executionAdmission: ProvisioningExecutionAdmission = .fixture) throws -> any ProvisioningGuestAdapter {
        try executionAdmission.verify(vmID: admission.target.vmID, root: URL(fileURLWithPath: admission.selection.endpoint.root))
        try admitPackage()
        let reference = try admission.selection.verify(target: admission.target, policy: admission.policy)
        try reference.connection.verify(); try reference.tools.verify(); try admitPackage()
        try executionAdmission.verify(vmID: admission.target.vmID, root: URL(fileURLWithPath: admission.selection.endpoint.root))
        return try SSHAnsibleGuestAdapter(connection: reference.connection, tools: reference.tools, authority: authority, runner: makeRunner())
    }
}
