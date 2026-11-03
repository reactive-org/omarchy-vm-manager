import DevVMProvisioningCore
import Foundation

/// Supplied by a trusted helper-local provider, never decoded from a command,
/// manifest, status packet or a saved journal. No tool probes or execution here.
struct ProvisioningHelperTransportResources: Sendable {
    let connection: ProvisioningSSHConnection
    let tools: ProvisioningTransportTools
    let dependencyDigest: String
    let makeProcessRunner: @Sendable () throws -> any ProvisioningProcessRunner
}
protocol ProvisioningHelperTransportProviding: Sendable {
    func resources(for input: ProvisioningValidatedFrozenContext, registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperTransportResources
}

/// Constructs the actual shared adapter/fenced runner once per helper worker.
/// Product entry points deliberately provide no transport resource provider.
actor ProvisioningHelperTransportBackend: ProvisioningDeliveredBackendPreparing {
    private let provider: any ProvisioningHelperTransportProviding
    private let client: ProvisioningSessionClient
    private let admitPackage: @Sendable () throws -> Void
    private var used = false
    init(provider: any ProvisioningHelperTransportProviding, client: ProvisioningSessionClient, admitPackage: @escaping @Sendable () throws -> Void) {
        self.provider = provider; self.client = client; self.admitPackage = admitPackage
    }
    func prepare(_ input: ProvisioningValidatedFrozenContext, registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperEngineContext {
        guard !used, registration.sessionAuthorityVersion == 1, registration.delivery == input.receipt else { throw ProvisioningJobFailure.invalidRequest }
        used = true // Before any await, including failure. Never build/retry twice.
        try input.storage.verifyRoot(); try input.request.plan.verify(in: input.storage.directory); try admitPackage()
        let request = input.request, scope = registration.scope
        guard request.jobID == scope.jobID, request.target.vmID == scope.vmID, request.target.sessionID == scope.sessionID,
              request.mode == registration.mode, request.dependencyDigest == scope.dependencyDigest,
              request.reviewIdentity == scope.reviewDigest, input.approval.reviewIdentity == scope.reviewDigest,
              request.plan.identity == registration.planDigest, request.plan.snapshot.identity == registration.inputDigest,
              try ProvisioningCoordinator.engineIdentity(request.plan) == scope.engineDigest else { throw SequencingFailure.identityMismatch }
        let authority = try ProvisioningHelperSessionAuthority(registration: registration, target: request.target, client: client)
        try await authority.revalidate(request.target, dependencyDigest: request.dependencyDigest)
        let resources = try await provider.resources(for: input, registration: registration)
        guard resources.connection.binding == request.target, resources.dependencyDigest == request.dependencyDigest else { throw SequencingFailure.identityMismatch }
        try resources.connection.verify(); try resources.tools.verify(); try admitPackage()
        try input.storage.verifyRoot(); try request.plan.verify(in: input.storage.directory)
        try await authority.revalidate(request.target, dependencyDigest: request.dependencyDigest)
        try resources.connection.verify(); try resources.tools.verify()
        try input.storage.verifyRoot(); try request.plan.verify(in: input.storage.directory); try admitPackage()
        let runner = try ProvisioningFencedProcessRunner(backend: resources.makeProcessRunner(), scope: registration.scope,
            target: request.target, mode: request.mode, authority: authority)
        let adapter = try SSHAnsibleGuestAdapter(connection: resources.connection, tools: resources.tools, authority: authority, runner: runner)
        return .init(request: request, approval: input.approval, adapter: adapter, authority: authority, runner: runner,
            admitPackage: admitPackage, frozenContext: input)
    }
}
