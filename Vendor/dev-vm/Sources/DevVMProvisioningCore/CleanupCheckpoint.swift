import Foundation

/// An expectation supplied by an authenticated owner, not decoded from disk.
/// This value and its private checkpoint authorize no transport by themselves.
public struct CleanupRecoveryIdentity: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let jobID: UUID, payloadID: UUID
    let target: GuestBinding
    let dependencyDigest: String, engineDigest: String
    let mode: ProvisioningMode
    public var description: String { "CleanupRecoveryIdentity(redacted)" }
    public var debugDescription: String { description }
    public init(jobID: UUID, payloadID: UUID, target: GuestBinding, dependencyDigest: String,
                engineDigest: String, mode: ProvisioningMode) throws {
        guard matches(dependencyDigest, "[a-f0-9]{64}"), matches(engineDigest, "[a-f0-9]{64}") else { throw SequencingFailure.invalidRequest }
        self.jobID = jobID; self.payloadID = payloadID; self.target = target
        self.dependencyDigest = dependencyDigest; self.engineDigest = engineDigest; self.mode = mode
    }
    private var document: ManifestValue {
        .object(["cleanup_checkpoint_api": .integer(1), "job": .string(jobID.uuidString), "payload": .string(payloadID.uuidString),
                 "target": target.reviewValue, "dependencies": .string(dependencyDigest), "engine": .string(engineDigest), "mode": .string(mode.rawValue)])
    }
    /// Private storage only. It includes original guest identity metadata, but
    /// never private keys, credentials, terminal data or source contents.
    public func privateCheckpoint() throws -> Data { try canonicalData(document) }
    public func restore(privateCheckpoint data: Data) throws -> CleanupTicket {
        guard data.count <= 16 * 1024,
              (try? PlainDataParser.parse(data, format: .json)) == document else { throw SequencingFailure.invalidRequest }
        // Never trust persisted "already clean" flags. Cleanup always re-proves
        // quiescence, grant/cache revocation for apply, and payload absence.
        let context = GuestJobContext(jobID: jobID, payloadID: payloadID, target: target, dependencyDigest: dependencyDigest, mode: mode)
        return CleanupTicket(context: context, grantMayBeActive: mode == .apply, payloadMayExist: true, workMayBeActive: true)
    }
}
