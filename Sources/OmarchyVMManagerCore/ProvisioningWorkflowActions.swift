import DevVMProvisioningCore
import Foundation

public enum ProvisioningWorkflowAction: String, Codable, Sendable, CaseIterable {
    case restart, check, recover
    public var title: String {
        switch self { case .restart: "Restart guest"; case .check: "Check after restart"; case .recover: "Recover cleanup" }
    }
    public var explanation: String {
        switch self {
        case .restart: "Gracefully shut down this guest, wait for its matching exit, and start a fresh session. Checking that session needs a separate review."
        case .check: "Check the frozen setup in the admitted replacement session. Custom tasks are excluded and no authorization input is granted. Check mode is not a sandbox."
        case .recover: "Verify the original helper has stopped and is fenced, then attempt only the original job’s cleanup and authorization revocation. No setup is reapplied and no guest is restarted."
        }
    }
}
public struct ProvisioningWorkflowActionReview: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID, workflowID: UUID, vmID: UUID, sessionID: UUID, jobID: UUID
    public let action: ProvisioningWorkflowAction
    public let workflowSequence: UInt64
    public let planDigest: String, inputDigest: String, dependencyDigest: String, reviewIdentity: String
    public var description: String { "ProvisioningWorkflowActionReview(redacted)" }
    public var debugDescription: String { description }
    func validate() throws {
        guard workflowSequence > 0, workflowSequence < UInt64(Int64.max),
              [planDigest, inputDigest, dependencyDigest, reviewIdentity].allSatisfy(provisioningDigest) else { throw ProvisioningReviewFailure.invalid }
    }
}
public struct ProvisioningWorkflowActionConsent: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let reviewID: UUID
    public let action: ProvisioningWorkflowAction
    public let reviewIdentity: String
    public let acknowledged: Bool
    public init(reviewID: UUID, action: ProvisioningWorkflowAction, reviewIdentity: String, acknowledged: Bool = false) {
        self.reviewID = reviewID; self.action = action; self.reviewIdentity = reviewIdentity; self.acknowledged = acknowledged
    }
    public var description: String { "ProvisioningWorkflowActionConsent(redacted)" }
    public var debugDescription: String { description }
    func validate() throws { guard provisioningDigest(reviewIdentity) else { throw ProvisioningReviewFailure.invalid } }
}
public protocol ProvisioningWorkflowActing: ProvisioningObserving {
    func prepareAction(_ workflowID: UUID, action: ProvisioningWorkflowAction, reviewID: UUID) async throws -> ProvisioningWorkflowActionReview
    func performAction(_ workflowID: UUID, consent: ProvisioningWorkflowActionConsent) async throws -> ProvisioningWorkflowSnapshot
}
extension ProvisioningWorkflowSnapshot {
    public var availableActions: [ProvisioningWorkflowAction] {
        if cleanupRequired { return [.cleanupRequired, .interrupted, .failed, .cancelled].contains(stage) ? [.recover] : [] }
        if stage == .restartRequired { return [.restart] }
        if [.waitingForRebind, .readyForCheck].contains(stage) { return [.check] }
        return []
    }
}
struct ProvisioningActionPreparation: Sendable {
    let workflowID: UUID
    let action: ProvisioningWorkflowAction
    let task: Task<ProvisioningWorkflowActionReview, Error>
}
struct ProvisioningActionContext: Sendable {
    enum Detail: Sendable {
        case restart(ProvisioningRestartReview, ProvisioningTransportAdmission)
        case check(ProvisioningRebindReview, ProvisioningPreparedJob)
        case recover(ProvisioningJobRecord, ProvisioningTransportAdmission)
    }
    let review: ProvisioningWorkflowActionReview
    let detail: Detail
}

/// Factory is inert until coordinator recovery has authenticated/fenced the
/// original worker, admitted the matching checkpoint and reserved its cleanup
/// lease. No plan, task, authorization-input or arbitrary body command is allowed.
actor ProvisioningDeferredCleanupAdapter: ProvisioningGuestAdapter {
    private let make: @Sendable () throws -> any ProvisioningGuestAdapter
    private let target: GuestBinding
    private let jobID: UUID, dependencyDigest: String
    private var adapter: (any ProvisioningGuestAdapter)?
    private var active: UUID?
    init(jobID: UUID, target: GuestBinding, dependencyDigest: String, make: @escaping @Sendable () throws -> any ProvisioningGuestAdapter) {
        self.jobID = jobID; self.target = target; self.dependencyDigest = dependencyDigest; self.make = make
    }
    func perform(_ command: DevVMProvisioningCore.GuestCommand) async throws -> GuestReply {
        let allowed: Set<GuestOperation> = [.verifyIdentity, .quiesceOwnedWork, .revokeGrant, .clearAuthenticationCache, .verifyGrantInactive, .removePayload]
        guard active == nil, command.plan == nil, command.inputLeaseID == nil, allowed.contains(command.operation),
              command.context.jobID == jobID, command.context.target == target, command.context.dependencyDigest == dependencyDigest else { throw SequencingFailure.protocolViolation }
        if adapter == nil { adapter = try make() }
        active = command.id; defer { active = nil }
        return try await adapter!.perform(command)
    }
    func interrupt(commandID: UUID, context: GuestJobContext) async {
        guard active == commandID, context.jobID == jobID, context.target == target, context.dependencyDigest == dependencyDigest else { return }
        await adapter?.interrupt(commandID: commandID, context: context)
    }
}
