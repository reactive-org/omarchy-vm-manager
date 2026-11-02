#if DEBUG
import Foundation
import DevVMProvisioningCore
@testable import OmarchyVMManagerCore

// This code is only in the excluded debug fixture product. The shipped helper
// never contains a synthetic guest backend or a fixture-selection parameter.
enum DispatchFixtureBlueprint {
    static func request(root: URL, scope: ProvisioningRecoveryExpectation, mode: ProvisioningMode) throws -> ProvisioningRequest {
        try PrivateFiles.directory(root, create: true)
        let manifest = root.appendingPathComponent("vm.yml")
        let bytes = Data("schema_version: 1\nid: dispatch-fixture\nsetup: {features: {enable: [cli]}}\nvars: {synthetic: local-fixture-only}\n".utf8)
        if !FileManager.default.fileExists(atPath: manifest.path) {
            try bytes.write(to: manifest); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        }
        let plan = try SetupPlanner.plan(repository: root)
        let target = try GuestBinding(vmID: scope.vmID, sessionID: scope.sessionID, owner: "fixture", ownerUID: 1000, hostKeyDigest: String(repeating: "a", count: 64))
        return try .init(jobID: scope.jobID, plan: plan, repository: root, target: target, dependencyDigest: scope.dependencyDigest,
            mode: mode, inputLeaseID: mode == .apply ? scope.workerToken : nil)
    }
}
private struct DispatchFixtureProcessBackend: ProvisioningProcessRunner {
    func run(_ invocation: ProvisioningProcessInvocation) async -> ProvisioningProcessResult { .init(invocationID: invocation.id, termination: .notStarted) }
    func interrupt(invocationID: UUID) async {}
}
private struct DispatchFixtureAuthority: ProvisioningSessionAuthority {
    let target: GuestBinding
    let dependencies: String
    func revalidate(_ binding: GuestBinding, dependencyDigest: String) async throws {
        guard binding == target, dependencyDigest == dependencies else { throw SequencingFailure.identityMismatch }
    }
}
private actor DispatchFixtureGuest: ProvisioningGuestAdapter {
    private var interrupted = Set<UUID>()
    func perform(_ command: DevVMProvisioningCore.GuestCommand) async throws -> DevVMProvisioningCore.GuestReply {
        if command.operation == .configureFeatures { try await Task.sleep(for: .milliseconds(250)) }
        if interrupted.contains(command.id) { throw SequencingFailure.cancelled }
        let proof: GuestProof
        switch command.operation {
        case .verifyIdentity: proof = .identityVerified
        case .verifyGrantActive: proof = .grantActiveWithoutCachedAuthentication
        case .verifyGrantInactive: proof = .grantInactiveAndCacheCleared
        case .quiesceOwnedWork: proof = .ownedWorkStopped
        case .removePayload: proof = .payloadAbsent
        default: proof = .completed
        }
        return .init(commandID: command.id, jobID: command.context.jobID, target: command.context.target,
            dependencyDigest: command.context.dependencyDigest, proof: proof)
    }
    func interrupt(commandID: UUID, context: GuestJobContext) async { interrupted.insert(commandID) }
}
struct DispatchFixtureEngineFactory: ProvisioningHelperEnginePreparing {
    let root: URL
    let layout: ProvisioningPackageLayout
    func prepare(_ registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperEngineContext {
        let request = try DispatchFixtureBlueprint.request(root: root, scope: registration.scope, mode: registration.mode)
        let runner = try ProvisioningFencedProcessRunner(backend: DispatchFixtureProcessBackend(), scope: registration.scope, target: request.target, mode: request.mode)
        return .init(request: request, approval: .init(reviewIdentity: request.reviewIdentity, persistentGrantAcknowledged: true),
            adapter: DispatchFixtureGuest(), authority: DispatchFixtureAuthority(target: request.target, dependencies: request.dependencyDigest), runner: runner,
            admitPackage: { _ = try BundledProvisioning.inspect(layout) })
    }
}
#endif
