import Darwin
@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private final class FrozenDeliveryFixture {
    let root: URL, source: URL, parent: URL
    let request: ProvisioningRequest, approval: ProvisioningApproval
    let delivery: ProvisioningFrozenDelivery
    let registration: ProvisioningHelperWorkerRegistration
    init(mode: ProvisioningMode = .apply, consent: Bool = true) throws {
        root = URL(fileURLWithPath: "/private/tmp/frozen-delivery-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); parent = root.appendingPathComponent("helper")
        try PrivateFiles.directory(root, create: true); try PrivateFiles.directory(source, create: true); try PrivateFiles.directory(parent, create: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("config"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("assets/empty"), withIntermediateDirectories: true)
        try Data([0, 255, 13, 10, 0, 128]).write(to: source.appendingPathComponent("assets/binary"))
        chmod(source.appendingPathComponent("assets/binary").path, 0o640)
        chmod(source.appendingPathComponent("assets/empty").path, 0o750)
        try Data("unselected-private-file".utf8).write(to: source.appendingPathComponent("unselected"))
        try Data("schema_version: 1\nnamespace: team\nfeatures: {tools: {description: Fixture tools}}\n".utf8).write(to: source.appendingPathComponent("config/catalogue.yml"))
        try Data("- name: inert task\n  ansible.builtin.debug: {msg: fixture}\n".utf8).write(to: source.appendingPathComponent("config/task.yml"))
        let manifest = """
        schema_version: 1
        id: frozen-fixture
        setup: {catalogues: [config/catalogue.yml], features: {enable: [cli, team.tools]}}
        tasks: [{name: fixture, file: config/task.yml}]
        assets: [assets]
        vars: {private: NEVER-REPORT-DELIVERY-CONTENT}
        """
        try Data(manifest.utf8).write(to: source.appendingPathComponent("config/dev-vm.yml"))
        let plan = try SetupPlanner.plan(repository: source, manifest: "config/dev-vm.yml")
        let target = try GuestBinding(vmID: UUID(), sessionID: UUID(), owner: "fixture", ownerUID: 1000, hostKeyDigest: String(repeating: "a", count: 64))
        request = try .init(jobID: UUID(), plan: plan, repository: source, target: target, dependencyDigest: String(repeating: "b", count: 64), mode: mode, inputLeaseID: mode == .apply ? UUID() : nil)
        approval = .init(reviewIdentity: request.reviewIdentity, customTasksReviewed: consent, persistentGrantAcknowledged: consent)
        delivery = try .init(request: request, approval: approval, archive: plan.snapshot.privateArchive())
        let scope = ProvisioningRecoveryExpectation(challenge: UUID(), jobID: request.jobID, vmID: target.vmID, sessionID: target.sessionID,
            payloadID: UUID(), workerToken: UUID(), engineDigest: try ProvisioningCoordinator.engineIdentity(plan), dependencyDigest: request.dependencyDigest,
            bindingDigest: try ProvisioningCoordinator.bindingIdentity(target), reviewDigest: request.reviewIdentity, checkpointDigest: String(repeating: "c", count: 64))
        registration = .init(scope: scope, planDigest: plan.identity, inputDigest: plan.snapshot.identity, mode: mode, delivery: delivery.receipt)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}
private func replacingMetadata(_ delivery: ProvisioningFrozenDelivery, change: (inout [String: Any]) -> Void) throws -> (Data, ProvisioningFrozenDeliveryReceipt) {
    let data = delivery.bytes, size = data[8..<12].reduce(0) { ($0 << 8) | Int($1) }
    var object = try JSONSerialization.jsonObject(with: Data(data[12..<12+size])) as! [String: Any]
    change(&object)
    return try repack(delivery, metadata: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}
private func repack(_ delivery: ProvisioningFrozenDelivery, metadata: Data) throws -> (Data, ProvisioningFrozenDeliveryReceipt) {
    let data = delivery.bytes, size = data[8..<12].reduce(0) { ($0 << 8) | Int($1) }, length = UInt32(metadata.count)
    let archive = Data(data[(12+size)...])
    let bytes = Data("DVMCNTX1".utf8) + Data([UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)]) + metadata + archive
    return (bytes, .init(format: 1, sha256: KitVerifier.sha256(bytes), byteCount: bytes.count, metadataSHA256: KitVerifier.sha256(metadata), archiveSHA256: KitVerifier.sha256(archive)))
}
private func inputSockets() throws -> (ProvisioningHelperSocket, ProvisioningHelperSocket) {
    var fds = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw ProvisioningHelperIPCFailure.unavailable }
    return try (ProvisioningHelperSocket(taking: fds[0], timeout: .milliseconds(200)), ProvisioningHelperSocket(taking: fds[1], timeout: .milliseconds(200)))
}
@Suite("Frozen helper inputs — private local fixtures only") struct ProvisioningFrozenDeliveryTests {
    @Test(arguments: [ProvisioningMode.apply, .check])
    func independentReplanPreservesSelectedBytesModesEmptyDirectoriesAndReview(mode: ProvisioningMode) throws {
        let f = try FrozenDeliveryFixture(mode: mode)
        try FileManager.default.removeItem(at: f.source)
        let input = try ProvisioningValidatedFrozenContext.load(f.delivery.bytes, registration: f.registration, parent: f.parent)
        #expect(input.request.reviewIdentity == f.request.reviewIdentity && input.request.plan.identity == f.request.plan.identity)
        #expect(input.request.selectedTasks == (mode == .apply ? ["fixture"] : []))
        #expect(input.request.plan.snapshot.data(for: "config/catalogue.yml") != nil)
        #expect(input.request.plan.manifestPath == "config/dev-vm.yml" && input.request.repository != f.source)
        #expect(try Data(contentsOf: input.storage.directory.appendingPathComponent("assets/binary")) == Data([0, 255, 13, 10, 0, 128]))
        #expect(!FileManager.default.fileExists(atPath: input.storage.directory.appendingPathComponent("unselected").path))
        var info = stat(); #expect(lstat(input.storage.directory.appendingPathComponent("assets/empty").path, &info) == 0 && info.st_mode & 0o777 == 0o750)
        #expect(lstat(input.storage.directory.appendingPathComponent("assets/binary").path, &info) == 0 && info.st_mode & 0o777 == 0o640)
        #expect(lstat(input.storage.directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        try input.request.plan.verify(in: input.storage.directory)
        let report = String(decoding: try helperJSON(f.registration), as: UTF8.self)
        #expect(!report.contains("NEVER-REPORT") && !report.contains(f.source.path) && !report.contains("fixture"))
        #expect(String(reflecting: input) == "ProvisioningValidatedFrozenContext(redacted)")
    }
    @Test(arguments: ["job", "vm", "session", "owner", "hostkey", "dependency", "mode", "tasks", "includeTasks", "conflict", "inputLease", "manifest", "consent-review", "unknown", "nested", "traversal", "format"])
    func changedMetadataWithRecomputedEnvelopeCannotChangeReviewedContext(kind: String) throws {
        let f = try FrozenDeliveryFixture()
        let (bytes, receipt) = try replacingMetadata(f.delivery) { object in
            switch kind {
            case "job": object["jobID"] = UUID().uuidString
            case "vm", "session", "owner", "hostkey":
                var target = object["target"] as! [String: Any]
                if kind == "vm" { target["vmID"] = UUID().uuidString }
                if kind == "session" { target["sessionID"] = UUID().uuidString }
                if kind == "owner" { target["ownerUID"] = 0 }
                if kind == "hostkey" { target["hostKeyDigest"] = String(repeating: "d", count: 64) }
                object["target"] = target
            case "dependency": object["dependencyDigest"] = String(repeating: "d", count: 64)
            case "mode": object["mode"] = "check"
            case "tasks": object["selectedTasks"] = ["arbitrary"]
            case "includeTasks": object["includeTasksInCheck"] = true
            case "conflict": object["conflictPolicy"] = "backup"
            case "inputLease": object["inputLeaseID"] = UUID().uuidString
            case "manifest": object["manifestPath"] = "absent.yml"
            case "consent-review": var approval = object["approval"] as! [String: Any]; approval["reviewIdentity"] = String(repeating: "d", count: 64); object["approval"] = approval
            case "unknown": object["command"] = "never-execute"
            case "nested": var target = object["target"] as! [String: Any]; target["privateKey"] = "never-accept"; object["target"] = target
            case "traversal": object["manifestPath"] = "../outside.yml"
            default: object["format"] = 2
            }
        }
        var registration = f.registration; registration.delivery = receipt
        #expect(throws: Error.self) { _ = try ProvisioningValidatedFrozenContext.load(bytes, registration: registration, parent: f.parent) }
    }
    @Test(arguments: ["plan", "input", "engine", "digest", "truncated", "archive-hash", "metadata-hash", "duplicate"])
    func alteredRegistrationOrFramingIsRejected(kind: String) throws {
        let f = try FrozenDeliveryFixture(); var registration = f.registration, bytes = f.delivery.bytes
        let pin = String(repeating: "d", count: 64)
        if kind == "plan" { registration = .init(scope: registration.scope, planDigest: pin, inputDigest: registration.inputDigest, mode: registration.mode, delivery: registration.delivery) }
        if kind == "input" { registration = .init(scope: registration.scope, planDigest: registration.planDigest, inputDigest: pin, mode: registration.mode, delivery: registration.delivery) }
        if kind == "engine" { registration.scope = try helperChanged(registration.scope, key: "engineDigest", text: pin) }
        if kind == "digest" { bytes[bytes.count - 1] ^= 1 }
        if kind == "truncated" { bytes.removeLast() }
        if kind == "archive-hash" || kind == "metadata-hash" {
            let old = f.delivery.receipt
            registration.delivery = .init(format: 1, sha256: old.sha256, byteCount: old.byteCount, metadataSHA256: kind == "metadata-hash" ? pin : old.metadataSHA256, archiveSHA256: kind == "archive-hash" ? pin : old.archiveSHA256)
        }
        if kind == "duplicate" {
            let size = bytes[8..<12].reduce(0) { ($0 << 8) | Int($1) }
            let metadata = Data("{\"format\":1,".utf8) + bytes[13..<12+size]
            (bytes, registration.delivery) = try repack(f.delivery, metadata: metadata)
        }
        #expect(throws: Error.self) { _ = try ProvisioningValidatedFrozenContext.load(bytes, registration: registration, parent: f.parent) }
    }
    @Test(arguments: ["mode", "symlink", "hardlink", "replacement", "truncated"])
    func pinnedPrivateSourceRejectsChangedDescriptorsAndPaths(kind: String) throws {
        let f = try FrozenDeliveryFixture(), url = f.root.appendingPathComponent("job.delivery")
        try PrivateFiles.write(f.delivery.bytes, name: url.lastPathComponent, in: f.root, exclusively: true)
        let source = try ProvisioningFrozenDeliverySource(url: url, receipt: f.delivery.receipt)
        #expect(try source.read() == f.delivery.bytes)
        if kind == "mode" { chmod(url.path, 0o644) }
        if kind == "hardlink" { #expect(link(url.path, f.root.appendingPathComponent("linked").path) == 0) }
        if kind == "replacement" || kind == "symlink" {
            let old = f.root.appendingPathComponent("old")
            try FileManager.default.moveItem(at: url, to: old)
            if kind == "symlink" { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: old) }
            else { try PrivateFiles.write(f.delivery.bytes, name: url.lastPathComponent, in: f.root, exclusively: true) }
        }
        if kind == "truncated" { try Data().write(to: url) }
        #expect(throws: Error.self) { _ = try source.read() }
    }
    @Test func replacedMaterializationRootIsRejectedAndOutsideSentinelIsPreserved() throws {
        let f = try FrozenDeliveryFixture()
        let input = try ProvisioningValidatedFrozenContext.load(f.delivery.bytes, registration: f.registration, parent: f.parent)
        let sentinel = f.root.appendingPathComponent("sentinel"); try Data("preserve".utf8).write(to: sentinel)
        let old = f.parent.appendingPathComponent("retained")
        try FileManager.default.moveItem(at: input.storage.directory, to: old)
        try FileManager.default.createSymbolicLink(at: input.storage.directory, withDestinationURL: f.root)
        #expect(throws: Error.self) { try input.storage.verifyRoot() }
        #expect(try Data(contentsOf: sentinel) == Data("preserve".utf8))
        #expect(throws: Error.self) { _ = try ProvisioningValidatedFrozenContext.load(f.delivery.bytes, registration: f.registration, parent: input.storage.directory) }
    }
    @Test(arguments: ["large", "extra", "truncated", "wrong-hash", "overrun", "missing-eof"])
    func boundedSeparateDataChannelRequiresExactBytesAndEOF(kind: String) async throws {
        let (sender, receiver) = try inputSockets()
        defer { sender.stop(); receiver.stop() }
        let bytes = Data(repeating: 42, count: 96 * 1024)
        let receipt = ProvisioningFrozenDeliveryReceipt(format: 1, sha256: KitVerifier.sha256(bytes), byteCount: bytes.count,
            metadataSHA256: String(repeating: "a", count: 64), archiveSHA256: String(repeating: "b", count: 64))
        let sending = Task { try await helperBlocking {
            if kind == "large" || kind == "wrong-hash" { try ProvisioningFrozenChannel.send(bytes, over: sender) }
            else {
                let count = kind == "truncated" ? bytes.count - 1 : bytes.count
                for offset in stride(from: 0, to: count, by: 16 * 1024) {
                    let end = min(count, offset + 16 * 1024)
                    var packet = Data(bytes[offset..<end])
                    if kind == "overrun", end == count { packet.append(0) }
                    try sender.send(packet)
                }
                if kind == "extra" { try sender.send(Data([0])) }
                if kind != "missing-eof" { sender.finishSending() }
            }
        } }
        if kind == "large" { #expect(try await helperBlocking { try ProvisioningFrozenChannel.receive(receipt, over: receiver) } == bytes) }
        else {
            let expected = kind == "wrong-hash" ? ProvisioningFrozenDeliveryReceipt(format: 1, sha256: String(repeating: "f", count: 64), byteCount: bytes.count, metadataSHA256: receipt.metadataSHA256, archiveSHA256: receipt.archiveSHA256) : receipt
            await #expect(throws: Error.self) { _ = try await helperBlocking { try ProvisioningFrozenChannel.receive(expected, over: receiver) } }
        }
        _ = try? await sending.value
    }
    @Test(arguments: ["file-prefix", "implicit-directory-limit"])
    func archiveCannotCreateFileDirectoryAliasesOrUnboundedAncestors(kind: String) throws {
        let f = try FrozenDeliveryFixture()
        let files: [String: FrozenFile]
        if kind == "file-prefix" { files = ["item": .init(data: Data(), mode: 0o600), "item/child": .init(data: Data(), mode: 0o600)] }
        else { files = Dictionary(uniqueKeysWithValues: (0..<2100).map { ("root-\($0)/nested/file", FrozenFile(data: Data(), mode: 0o600)) }) }
        let snapshot = SourceSnapshot(files: files, directories: [:], roots: files.keys.sorted(), rootDevice: 0, rootInode: 0)
        let archive = try FrozenInputsArchive(privateArchive: snapshot.privateArchive(), expectedIdentity: snapshot.identity)
        #expect(throws: Error.self) { _ = try ProvisioningPrivateInputTree(archive: archive, parent: f.parent) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.parent.path).isEmpty)
    }
    @Test func deliveryBootstrapAndReceiptAreStrictAndDoNotAcknowledgeUnvalidatedInputs() async throws {
        let f = try FrozenDeliveryFixture()
        let identity = ProvisioningHelperIdentity(instanceID: UUID(), executableSHA256: String(repeating: "e", count: 64), packageLockSHA256: ProvisioningPackagePin.lockSHA256)
        var registration = f.registration; registration.scope.helperIdentity = identity
        let credentials = try ProvisioningHelperCredentials(identity: identity, registration: registration)
        let data = try credentials.privateBootstrap()
        let restored = try ProvisioningHelperCredentials(privateBootstrap: data)
        #expect(restored.registration == registration)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["version"] as? Int == 3)
        object["version"] = 2
        #expect(throws: Error.self) { _ = try ProvisioningHelperCredentials(privateBootstrap: JSONSerialization.data(withJSONObject: object)) }
        let (clientSocket, serverSocket) = try inputSockets()
        let registry = try ProvisioningHelperOwnershipRegistry(identity: identity)
        #expect(throws: ProvisioningHelperIPCFailure.authentication) {
            _ = try ProvisioningHelperIPCServer(socket: serverSocket, credentials: credentials, registry: registry)
        }
        // Even a correctly MACed receipt cannot omit delivery validation.
        let client = ProvisioningHelperIPCClient(socket: clientSocket, credentials: credentials)
        var codec = ProvisioningHelperFrameCodec(credentials: credentials, role: .helper)
        let forged = ProvisioningHelperRegistrationReceipt(identity: identity, registrationDigest: try registration.digest, state: "registered")
        try serverSocket.send(codec.encode(helperJSON(forged)))
        let ticket = ProvisioningHelperLaunchTicket(id: UUID(), identity: identity, registration: registration)
        await #expect(throws: ProvisioningHelperIPCFailure.authentication) { _ = try await client.awaitRegistration(ticket) }
        serverSocket.stop(); client.disconnect()
    }
    @Test func deliveredApprovalCannotBeExpandedByTheInjectedBackend() async throws {
        let f = try FrozenDeliveryFixture(consent: false)
        let input = try ProvisioningValidatedFrozenContext.load(f.delivery.bytes, registration: f.registration, parent: f.parent)
        let guest = EngineFixtureGuest()
        let backend = EngineFixtureFactory(request: input.request, approval: .init(reviewIdentity: input.request.reviewIdentity,
            customTasksReviewed: true, persistentGrantAcknowledged: true, dockerRootAccessAcknowledged: true), guest: guest, authority: EngineFixtureAuthority())
        let factory = ProvisioningDeliveredEngineFactory(input: input, backend: backend)
        let context = try await factory.prepare(f.registration)
        #expect(!context.approval.customTasksReviewed && !context.approval.persistentGrantAcknowledged && !context.approval.dockerRootAccessAcknowledged)
        let result = await ProvisioningSequencer().run(context.request, approval: context.approval, adapter: context.adapter)
        #expect(result.outcome == .rejected)
        #expect(await guest.commands.isEmpty)
    }

}
