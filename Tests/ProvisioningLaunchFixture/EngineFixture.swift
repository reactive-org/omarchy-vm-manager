#if DEBUG
import Darwin
import Foundation
import DevVMProvisioningCore
@testable import OmarchyVMManagerCore

// This code is only in the excluded debug fixture product. The shipped helper
// never contains a synthetic guest backend or a fixture-selection parameter.
enum DispatchFixtureBlueprint {
    static func request(root: URL, scope: ProvisioningRecoveryExpectation, mode: ProvisioningMode, delivered: Bool = false, transport: Bool = false, cancelTransport: Bool = false) throws -> ProvisioningRequest {
        try PrivateFiles.directory(root, create: true)
        let path = delivered ? "config/dev-vm.yml" : "vm.yml"
        if delivered {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("assets/empty"), withIntermediateDirectories: true)
            try Data(repeating: 0xFF, count: 96 * 1024).write(to: root.appendingPathComponent("assets/binary"))
            chmod(root.appendingPathComponent("assets/binary").path, 0o640)
        }
        let manifest = root.appendingPathComponent(path)
        let bytes = Data(((delivered ? "assets: [assets]\n" : "") + "schema_version: 1\nid: dispatch-fixture\nsetup: {features: {enable: [cli]}}\nvars: {synthetic: local-fixture-only, cancel_transport_fixture: \(cancelTransport)}\n").utf8)
        if !FileManager.default.fileExists(atPath: manifest.path) {
            try bytes.write(to: manifest); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        }
        let plan = try SetupPlanner.plan(repository: root, manifest: path)
        let target = try GuestBinding(vmID: scope.vmID, sessionID: scope.sessionID, owner: "fixture", ownerUID: 1000, hostKeyDigest: transport ? KitVerifier.sha256(FixtureTransportProvider.hostKey) : String(repeating: "a", count: 64))
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
struct DispatchFixtureDeliveredBackend: ProvisioningDeliveredBackendPreparing {
    let layout: ProvisioningPackageLayout
    func prepare(_ input: ProvisioningValidatedFrozenContext, registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperEngineContext {
        let request = input.request
        // No original checkout path or fixed helper-side blueprint is consulted.
        guard request.plan.manifestPath == "config/dev-vm.yml",
              request.plan.snapshot.data(for: "assets/binary")?.count == 96 * 1024 else { throw ProvisioningJobFailure.invalidRequest }
        let runner = try ProvisioningFencedProcessRunner(backend: DispatchFixtureProcessBackend(), scope: registration.scope, target: request.target, mode: request.mode)
        return .init(request: request, approval: .init(reviewIdentity: request.reviewIdentity, persistentGrantAcknowledged: true),
            adapter: DispatchFixtureGuest(), authority: DispatchFixtureAuthority(target: request.target, dependencies: request.dependencyDigest), runner: runner,
            admitPackage: { _ = try BundledProvisioning.inspect(layout) })
    }
}

/// Excluded Debug provider: pins only inert local files and supplies a synthetic
/// process runner. It never launches an executable or reads a real credential.
struct FixtureTransportProvider: ProvisioningHelperTransportProviding {
    static let hostKey = Data([0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32] + Array(repeating: UInt8(42), count: 32))
    func resources(for input: ProvisioningValidatedFrozenContext, registration: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperTransportResources {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("transport-" + UUID().uuidString)
        try PrivateFiles.directory(directory, create: true)
        let identity = directory.appendingPathComponent("synthetic-identity").standardizedFileURL
        try PrivateFiles.write(Data("not-a-credential".utf8), name: identity.lastPathComponent, in: directory, exclusively: true)
        func pin(_ name: String) throws -> ProvisioningExecutablePin {
            let url = directory.appendingPathComponent(name).standardizedFileURL
            try Data("fixture-only-never-execute".utf8).write(to: url); chmod(url.path, 0o700)
            return try ProvisioningExecutablePin(url.standardizedFileURL)
        }
        let tools = try ProvisioningTransportTools(ssh: pin("ssh"), scp: pin("scp"), sftp: pin("sftp"), ansiblePlaybook: pin("ansible-playbook"), ansibleInventory: pin("ansible-inventory"))
        let connection = try ProvisioningSSHConnection(binding: input.request.target, port: 22222, identity: ProvisioningIdentityFile(identity.standardizedFileURL), ed25519HostKey: Self.hostKey)
        let manifest = input.request.plan.snapshot.data(for: input.request.plan.manifestPath) ?? Data()
        let hold = String(decoding: manifest, as: UTF8.self).contains("cancel_transport_fixture: true")
        return .init(connection: connection, tools: tools, dependencyDigest: input.request.dependencyDigest, makeProcessRunner: { FixtureTransportRunner(holdFeatures: hold) })
    }
}
private actor FixtureTransportRunner: ProvisioningProcessRunner {
    private var interrupted = Set<UUID>()
    private let holdFeatures: Bool
    init(holdFeatures: Bool) { self.holdFeatures = holdFeatures }
    func run(_ invocation: ProvisioningProcessInvocation) async -> ProvisioningProcessResult {
        if invocation.purpose == .features {
            if holdFeatures {
                let end = ContinuousClock.now + .seconds(5)
                while !interrupted.contains(invocation.id), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
            } else { try? await Task.sleep(for: .milliseconds(250)) }
        }
        var object: [String: Any] = ["protocol": 1, "job": invocation.context.jobID.uuidString.lowercased(), "payload": invocation.context.payloadID.uuidString.lowercased(), "uid": invocation.context.target.ownerUID]
        switch invocation.purpose {
        case .identity: object = ["uid": invocation.context.target.ownerUID, "owner": invocation.context.target.owner, "system": "Linux", "architecture": "aarch64"]
        case .bootstrap: object["state"] = "staged"
        case .preparePayload: object["state"] = "ready"
        case .quiesce: object["state"] = "quiescent"
        case .remove: object["state"] = "absent"
        default: object = [:]
        }
        let stdout = object.isEmpty ? Data() : try! JSONSerialization.data(withJSONObject: object)
        return .init(invocationID: invocation.id, termination: .exited(status: interrupted.contains(invocation.id) ? 143 : 0,
            reason: interrupted.contains(invocation.id) ? .cancelled : .normal), stdout: stdout)
    }
    func interrupt(invocationID: UUID) async { interrupted.insert(invocationID) }
}
actor FixtureSessionChecks {
    private(set) var count = 0
    func validate(_ request: ProvisioningSessionRequest, activation: ProvisioningHelperActivation) throws {
        guard request.scope.sameWorker(as: activation.scope), request.registrationDigest == activation.registrationDigest else { throw SequencingFailure.identityMismatch }
        count += 1
    }
}

#endif
