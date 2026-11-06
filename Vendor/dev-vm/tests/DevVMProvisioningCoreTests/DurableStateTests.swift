import Darwin
import Foundation
import Testing
@testable import DevVMProvisioningCore

private final class DurableFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let plan: SetupPlan
    let target: GuestBinding
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try Data([0, 1, 255, 10]).write(to: root.appendingPathComponent("binary")); chmod(root.appendingPathComponent("binary").path, 0o640)
        try Data("schema_version: 1\nid: fixture\nassets: [empty, binary]\nvars: {secret: synthetic-private-input}\n".utf8).write(to: root.appendingPathComponent("vm.yml"))
        plan = try SetupPlanner.plan(repository: root)
        target = try GuestBinding(vmID: UUID(), sessionID: UUID(), owner: "owner", ownerUID: 1000, hostKeyDigest: String(repeating: "b", count: 64))
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}
private actor CheckpointGuest: ProvisioningGuestAdapter {
    let refuseInactive: Bool
    private(set) var commands: [GuestCommand] = []
    init(refuseInactive: Bool = false) { self.refuseInactive = refuseInactive }
    func perform(_ command: GuestCommand) throws -> GuestReply {
        commands.append(command)
        if refuseInactive, command.operation == .verifyGrantInactive { throw SequencingFailure.adapterFailed }
        let proof: GuestProof
        switch command.operation {
        case .verifyIdentity: proof = .identityVerified
        case .verifyGrantActive: proof = .grantActiveWithoutCachedAuthentication
        case .verifyGrantInactive: proof = .grantInactiveAndCacheCleared
        case .quiesceOwnedWork: proof = .ownedWorkStopped
        case .removePayload: proof = .payloadAbsent
        default: proof = .completed
        }
        return GuestReply(commandID: command.id, jobID: command.context.jobID, target: command.context.target,
                          dependencyDigest: command.context.dependencyDigest, proof: proof)
    }
    func interrupt(commandID: UUID, context: GuestJobContext) {}
}

@Test func privateFrozenArchiveRetainsBytesModesAndEmptyDirectories() throws {
    let fixture = try DurableFixture()
    let data = try fixture.plan.snapshot.privateArchive()
    let restored = try FrozenInputsArchive(privateArchive: data, expectedIdentity: fixture.plan.snapshot.identity)
    #expect(restored.identity == fixture.plan.snapshot.identity)
    #expect(restored.data(for: "binary") == Data([0, 1, 255, 10]))
    #expect(restored.originalMode(for: "binary") == 0o640)
    #expect(restored.directoryPaths.contains("empty"))
    #expect(!String(reflecting: restored).contains("synthetic-private-input"))
    #expect(!String(decoding: data, as: UTF8.self).contains(fixture.root.path))
    try FileManager.default.removeItem(at: fixture.root)
    #expect(try FrozenInputsArchive(privateArchive: data, expectedIdentity: restored.identity).data(for: "vm.yml") != nil)
}

@Test(arguments: ["magic", "length", "bytes", "trailing", "identity", "version", "path", "duplicate"])
func privateFrozenArchiveRejectsDamage(kind: String) throws {
    let fixture = try DurableFixture(), original = try fixture.plan.snapshot.privateArchive()
    var data = original
    var identity = fixture.plan.snapshot.identity
    switch kind {
    case "magic": data[0] = 0
    case "length": data[8] = 255
    case "bytes": data[data.count-1] ^= 1
    case "trailing": data.append(0)
    case "identity": identity = String(repeating: "e", count: 64)
    default:
        let length = data[8..<12].reduce(0) { ($0 << 8) | Int($1) }
        var doc = try JSONSerialization.jsonObject(with: data[12..<12+length]) as! [String: Any]
        if kind == "version" { doc["format"] = 2 }
        if kind == "path" {
            var entries = doc["files"] as! [[String: Any]]; entries[0]["path"] = "../escape"; doc["files"] = entries
        }
        var metadata = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
        if kind == "duplicate" { metadata = Data("{\"format\":1,\"format\":1}".utf8) }
        let n = UInt32(metadata.count)
        data = Data("DVMSNAP1".utf8) + Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) + metadata + data[(12+length)...]
    }
    #expect(throws: ManifestError.self) { _ = try FrozenInputsArchive(privateArchive: data, expectedIdentity: identity) }
}

@Test(arguments: [ProvisioningMode.apply, .check])
func persistentCheckpointRecoveryIsConservativeAndCleanupOnly(mode: ProvisioningMode) async throws {
    let fixture = try DurableFixture(), job = UUID(), payload = UUID()
    let identity = try CleanupRecoveryIdentity(jobID: job, payloadID: payload, target: fixture.target,
        dependencyDigest: String(repeating: "d", count: 64), engineDigest: String(repeating: "e", count: 64), mode: mode)
    let bytes = try identity.privateCheckpoint()
    #expect(String(reflecting: identity) == "CleanupRecoveryIdentity(redacted)")
    let ticket = try identity.restore(privateCheckpoint: bytes), guest = CheckpointGuest()
    let result = await ProvisioningSequencer().recover(ticket, adapter: guest)
    #expect(result.outcome == .cleanupConfirmed)
    #expect(await guest.commands.allSatisfy { $0.plan == nil && $0.inputLeaseID == nil && $0.context.payloadID == payload })
    #expect(await guest.commands.allSatisfy { ![.stagePayload, .requestPersistentGrant, .configureFeatures, .configureRepository].contains($0.operation) })
    let revoked = await guest.commands.contains { $0.operation == .revokeGrant }
    #expect(revoked == (mode == .apply))
    let wrong = try CleanupRecoveryIdentity(jobID: UUID(), payloadID: payload, target: fixture.target,
        dependencyDigest: String(repeating: "d", count: 64), engineDigest: String(repeating: "e", count: 64), mode: mode)
    #expect(throws: SequencingFailure.self) { _ = try wrong.restore(privateCheckpoint: bytes) }
}

@Test func preallocatedPayloadAndUncertainGrantRetainRecoveryHelper() async throws {
    let fixture = try DurableFixture(), payload = UUID()
    let request = try ProvisioningRequest(jobID: UUID(), plan: fixture.plan, repository: fixture.root, target: fixture.target,
        dependencyDigest: String(repeating: "d", count: 64), inputLeaseID: UUID())
    let guest = CheckpointGuest(refuseInactive: true)
    let result = await ProvisioningSequencer().run(request,
        approval: .init(reviewIdentity: request.reviewIdentity, persistentGrantAcknowledged: true), payloadID: payload, adapter: guest)
    #expect(result.outcome == .cleanupRequired)
    #expect(await guest.commands.allSatisfy { $0.context.payloadID == payload })
    #expect(await guest.commands.allSatisfy { $0.operation != .removePayload })
}
