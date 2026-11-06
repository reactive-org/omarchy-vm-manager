import Darwin
@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

struct TransportFixturePorts: HostPortProbing { func isAvailable(_ port: Int) -> Bool { true } }
func seedTransportEndpoint(root: URL, target: GuestBinding, port: UInt16) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let storage = ManagedSSHStorage(root: root)
    try PrivateFiles.directory(storage.directory, create: true); try PrivateFiles.directory(storage.bootstrap, create: true)
    if !PrivateFiles.exists(storage.clientKey) { try PrivateFiles.write(Data("PRIVATE-FIXTURE-BYTES-NEVER-TRANSFER".utf8), name: "client", in: storage.directory, exclusively: true) }
    let manifest: [String: Any] = ["schemaVersion": 1, "vmID": target.vmID.uuidString, "sessionToken": target.sessionID.uuidString, "hostPort": port]
    try PrivateFiles.write(JSONSerialization.data(withJSONObject: manifest), name: ManagedSSHStorage.manifestName, in: root)
    let publicKey = "ssh-ed25519 " + sessionFixtureHostKey.base64EncodedString()
    let bootstrap: [String: Any] = ["schemaVersion": 1, "vmID": target.vmID.uuidString, "sessionToken": target.sessionID.uuidString, "publicKeys": [publicKey]]
    try PrivateFiles.write(JSONSerialization.data(withJSONObject: bootstrap), name: "manifest.json", in: storage.bootstrap)
    try PrivateFiles.write(Data((storage.alias(target.vmID) + " " + publicKey + "\n").utf8), name: "known_hosts", in: storage.directory)
}
private final class TransportHandoffFixture {
    let root: URL, source: URL
    let provider: SessionFixtureProvider
    let target: GuestBinding
    let admission: ProvisioningTransportAdmission
    let request: ProvisioningRequest
    let registration: ProvisioningHelperWorkerRegistration
    let input: ProvisioningValidatedFrozenContext
    let handoff: ProvisioningTransportHandoff
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/transport-handoff-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); try PrivateFiles.directory(root, create: true); try PrivateFiles.directory(source, create: true)
        provider = try SessionFixtureProvider()
        target = try .init(vmID: UUID(), sessionID: UUID(), owner: "fixture", ownerUID: 1000, hostKeyDigest: sessionFixtureHostKeyDigest)
        let guest = root.appendingPathComponent("guest"); try seedTransportEndpoint(root: guest, target: target, port: 22222)
        admission = try .init(root: guest, port: 22222, target: target, report: provider.admittedReport(), policy: .fixture(provider.root))
        try Data("schema_version: 1\nid: resource-fixture\nsetup: {features: {enable: [cli]}}\n".utf8).write(to: source.appendingPathComponent("vm.yml"))
        let plan = try SetupPlanner.plan(repository: source)
        request = try .init(jobID: UUID(), plan: plan, repository: source, target: target, dependencyDigest: admission.dependencyDigest, inputLeaseID: UUID())
        let frozen = try ProvisioningFrozenDelivery(request: request, approval: .init(reviewIdentity: request.reviewIdentity, persistentGrantAcknowledged: true), archive: plan.snapshot.privateArchive())
        let scope = ProvisioningRecoveryExpectation(challenge: UUID(), jobID: request.jobID, vmID: target.vmID, sessionID: target.sessionID, payloadID: UUID(), workerToken: UUID(),
            engineDigest: try ProvisioningCoordinator.engineIdentity(plan), dependencyDigest: admission.dependencyDigest, bindingDigest: try ProvisioningCoordinator.bindingIdentity(target), reviewDigest: request.reviewIdentity, checkpointDigest: String(repeating: "c", count: 64))
        let initial = ProvisioningHelperWorkerRegistration(scope: scope, planDigest: plan.identity, inputDigest: plan.snapshot.identity, mode: .apply, delivery: frozen.receipt, sessionAuthorityVersion: 1)
        handoff = try .init(admission: admission, registration: initial)
        var registration = initial; registration.transport = handoff.receipt
        registration.scope.helperIdentity = .init(instanceID: UUID(), executableSHA256: String(repeating: "e", count: 64), packageLockSHA256: ProvisioningPackagePin.lockSHA256)
        self.registration = registration
        let parent = root.appendingPathComponent("helper"); try PrivateFiles.directory(parent, create: true)
        input = try ProvisioningValidatedFrozenContext.load(frozen.bytes, registration: registration, parent: parent)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func loaded(_ data: Data? = nil, registration: ProvisioningHelperWorkerRegistration? = nil) throws -> ProvisioningValidatedTransport {
        try .load(data ?? handoff.bytes, registration: registration ?? self.registration, input: input, policy: .fixture(provider.root))
    }
}
@Suite("Transport admission/private handoff — local fixtures only") struct ProvisioningTransportTests {
    @Test func handoffPreservesOriginalPinsAndTransfersNoCredentialContents() throws {
        let f = try TransportHandoffFixture(), transport = try f.loaded(), reference = try transport.verify()
        #expect(reference.connection.binding == f.target && reference.connection.port == 22222)
        #expect(transport.receipt.dependencyDigest == f.request.dependencyDigest)
        let text = String(decoding: f.handoff.bytes, as: UTF8.self)
        #expect(!text.contains("PRIVATE-FIXTURE-BYTES-NEVER-TRANSFER"))
        #expect(!String(reflecting: f.handoff).contains(f.provider.root.path))
        #expect(String(reflecting: reference) == "ProvisioningTransportReference(redacted)")
        let control = String(decoding: try helperJSON(f.registration), as: UTF8.self)
        #expect(!control.contains(f.provider.root.path) && !control.contains(f.admission.selection.endpoint.root) && !control.contains(f.target.owner))
        let credentials = try ProvisioningHelperCredentials(identity: f.registration.scope.helperIdentity!, registration: f.registration)
        let bootstrap = try credentials.privateBootstrap()
        let object = try JSONSerialization.jsonObject(with: bootstrap) as! [String: Any]
        #expect(object["version"] as? Int == 5)
        #expect(try ProvisioningHelperCredentials(privateBootstrap: bootstrap).registration == f.registration)
    }
    @Test(arguments: ["key", "key-mode", "key-link", "tool", "alias", "keg", "known-hosts", "manifest", "bootstrap", "root"])
    func changedResourcesAreRejectedInsteadOfRecaptured(kind: String) throws {
        let f = try TransportHandoffFixture(), endpoint = f.admission.selection.endpoint
        let storage = ManagedSSHStorage(root: URL(fileURLWithPath: endpoint.root))
        if kind == "key" { let old = storage.directory.appendingPathComponent("old-key"); try FileManager.default.moveItem(at: storage.clientKey, to: old); try PrivateFiles.write(Data("replacement".utf8), name: "client", in: storage.directory, exclusively: true) }
        if kind == "key-mode" { chmod(storage.clientKey.path, 0o644) }
        if kind == "key-link" { #expect(link(storage.clientKey.path, storage.directory.appendingPathComponent("linked").path) == 0) }
        if kind == "tool" { try Data("changed".utf8).write(to: f.provider.root.appendingPathComponent("ssh")) }
        if kind == "alias" { let url = f.provider.root.appendingPathComponent("bin/ansible-playbook"); try FileManager.default.removeItem(at: url); try FileManager.default.createSymbolicLink(at: url, withDestinationURL: f.provider.root.appendingPathComponent("ansible-inventory")) }
        if kind == "keg" { try Data().write(to: f.provider.root.appendingPathComponent("changed-installation")) }
        if kind == "known-hosts" { try Data("changed".utf8).write(to: storage.knownHosts) }
        if kind == "manifest" { try Data("{}".utf8).write(to: storage.root.appendingPathComponent(ManagedSSHStorage.manifestName)) }
        if kind == "bootstrap" { try Data("{}".utf8).write(to: storage.bootstrap.appendingPathComponent("manifest.json")) }
        if kind == "root" { let old = f.root.appendingPathComponent("old-guest"); try FileManager.default.moveItem(at: storage.root, to: old); try FileManager.default.createSymbolicLink(at: storage.root, withDestinationURL: old) }
        #expect(throws: Error.self) { try f.admission.verify() }
        #expect(throws: Error.self) { _ = try f.loaded() }
        #expect(f.provider.builds == 0)
    }
    @Test(arguments: ["unknown", "duplicate", "worker", "job", "mode", "dependency", "hash", "truncated", "downgrade"])
    func malformedOrCrossJobHandoffsCannotBecomeBackendResources(kind: String) throws {
        let f = try TransportHandoffFixture(); var bytes = f.handoff.bytes, registration = f.registration
        if kind == "hash" { bytes[bytes.count-1] ^= 1 }
        else if kind == "truncated" { bytes.removeLast() }
        else if kind == "downgrade" {
            let credentials = try ProvisioningHelperCredentials(identity: registration.scope.helperIdentity!, registration: registration)
            var object = try JSONSerialization.jsonObject(with: credentials.privateBootstrap()) as! [String: Any]; object["version"] = 4
            #expect(throws: Error.self) { _ = try ProvisioningHelperCredentials(privateBootstrap: JSONSerialization.data(withJSONObject: object)) }; return
        } else {
            var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            if kind == "unknown" { object["command"] = "never-execute" }
            if kind == "worker" || kind == "job" { var scope = object["scope"] as! [String: Any]; scope[kind == "worker" ? "workerToken" : "jobID"] = UUID().uuidString; object["scope"] = scope }
            if kind == "mode" { object["mode"] = "check" }
            if kind == "dependency" { var selection = object["selection"] as! [String: Any]; selection["format"] = 2; object["selection"] = selection }
            bytes = try JSONSerialization.data(withJSONObject: object)
            if kind == "duplicate" { bytes = Data("{\"format\":1,".utf8) + bytes.dropFirst() }
            registration.transport = .init(format: 1, sha256: KitVerifier.sha256(bytes), byteCount: bytes.count, dependencyDigest: f.admission.dependencyDigest)
        }
        #expect(throws: Error.self) { _ = try f.loaded(bytes, registration: registration) }
    }
    @Test func hostPolicyCannotBeSelectedOrWeakenedByPrivateMetadata() throws {
        let f = try TransportHandoffFixture()
        #expect(throws: Error.self) { _ = try ProvisioningValidatedTransport.load(f.handoff.bytes, registration: f.registration, input: f.input, policy: .host) }
    }
    @Test func aMissingResourceAcknowledgementCannotRegisterTheWorker() async throws {
        let f = try TransportHandoffFixture(), identity = f.registration.scope.helperIdentity!
        let credentials = try ProvisioningHelperCredentials(identity: identity, registration: f.registration)
        let (manager, helper) = try sessionFixtureSockets()
        let client = ProvisioningHelperIPCClient(socket: manager, credentials: credentials)
        var codec = ProvisioningHelperFrameCodec(credentials: credentials, role: .helper)
        let receipt = ProvisioningHelperRegistrationReceipt(identity: identity, registrationDigest: try f.registration.digest, state: "registered", deliveryDigest: f.registration.delivery?.sha256)
        try helper.send(codec.encode(helperJSON(receipt)))
        let ticket = ProvisioningHelperLaunchTicket(id: UUID(), identity: identity, registration: f.registration)
        await #expect(throws: ProvisioningHelperIPCFailure.authentication) { _ = try await client.awaitRegistration(ticket) }
        helper.stop(); client.disconnect()
        let registry = try ProvisioningHelperOwnershipRegistry(identity: identity)
        let (first, second) = try sessionFixtureSockets(); defer { first.stop(); second.stop() }
        #expect(throws: ProvisioningHelperIPCFailure.authentication) { _ = try ProvisioningHelperIPCServer(socket: first, credentials: credentials, registry: registry, frozenInput: f.input) }
    }

}
