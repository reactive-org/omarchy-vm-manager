import DevVMProvisioningCore
import Foundation

/// Saving this review is metadata only. It grants no execution, task trust or sudo authority.
public struct ProvisioningCreationReview: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let planDigest: String, inputDigest: String, engineDigest: String, reviewIdentity: String
    public let proposal: Data
    public let tasks: [ProvisioningTaskReview]
    public let restartRequired: Bool
    public var description: String { "ProvisioningCreationReview(redacted)" }
    public var debugDescription: String { description }
    func validate() throws {
        try ProvisioningPlanPreview(id: id, vmID: id, sessionID: nil, planDigest: planDigest, inputDigest: inputDigest,
            engineDigest: engineDigest, proposal: proposal, tasks: tasks, restartRequired: restartRequired).validate()
        guard reviewIdentity == (try Self.identity(id, planDigest, inputDigest, engineDigest)) else { throw ProvisioningReviewFailure.invalid }
    }
    static func identity(_ id: UUID, _ plan: String, _ input: String, _ engine: String) throws -> String {
        KitVerifier.sha256(try helperJSON(["creation-selection-v1", id.uuidString, plan, input, engine]))
    }
}
public struct ProvisioningCreationConsent: Codable, Equatable, Sendable {
    public let reviewID: UUID
    public let reviewIdentity: String
    public let acknowledged: Bool
    public init(reviewID: UUID, reviewIdentity: String, acknowledged: Bool = false) {
        self.reviewID = reviewID; self.reviewIdentity = reviewIdentity; self.acknowledged = acknowledged
    }
    func validate() throws {
        guard provisioningDigest(reviewIdentity), acknowledged else { throw ProvisioningReviewFailure.consentRequired }
    }
}
/// Durable lookup receipt. It contains no source path, credentials or executable consent.
public struct ProvisioningSelectionReceipt: Codable, Equatable, Sendable {
    public let reviewID: UUID, vmID: UUID
    public let reviewIdentity: String, planDigest: String, inputDigest: String, engineDigest: String, configurationDigest: String
    func validate(vmID: UUID) throws {
        guard self.vmID == vmID, [reviewIdentity, planDigest, inputDigest, engineDigest, configurationDigest].allSatisfy(provisioningDigest),
              reviewIdentity == (try ProvisioningCreationReview.identity(reviewID, planDigest, inputDigest, engineDigest)) else { throw ProvisioningReviewFailure.invalid }
    }
}
public protocol ProvisioningCreationPlanning: ProvisioningReviewing {
    func prepareCreation(id: UUID, source: ProvisioningSetupSource) async throws -> ProvisioningCreationReview
    func creation(_ id: UUID) async throws -> ProvisioningCreationReview
}
struct ProvisioningCreationDraft: Sendable {
    let frozen: ProvisioningFrozenSelection
    let review: ProvisioningCreationReview
    var reservation: ProvisioningSelectionReceipt?
}
extension ProvisioningService: ProvisioningCreationPlanning {
    public func prepareCreation(id: UUID = UUID(), source: ProvisioningSetupSource) throws -> ProvisioningCreationReview {
        try reviewAvailable(); try source.validate()
        if let draft = creations[id] {
            guard draft.frozen.selection == source else { throw ProvisioningJobFailure.jobConflict }
            return try creation(id)
        }
        guard reviewCount < 16, !draftCaptures.contains(id), drafts[id] == nil, status(id) == nil else { throw ProvisioningReviewFailure.quota }
        let frozen = try freezeSelection(source)
        let review = ProvisioningCreationReview(id: id, planDigest: frozen.plan.identity, inputDigest: frozen.plan.snapshot.identity,
            engineDigest: environment.engineDigest, reviewIdentity: try ProvisioningCreationReview.identity(id, frozen.plan.identity, frozen.plan.snapshot.identity, environment.engineDigest),
            proposal: frozen.proposal, tasks: frozen.tasks, restartRequired: frozen.restartRequired)
        try review.validate(); creations[id] = .init(frozen: frozen, review: review)
        return review
    }
    public func creation(_ id: UUID) throws -> ProvisioningCreationReview {
        try reviewAvailable(); guard let draft = creations[id] else { throw ProvisioningReviewFailure.unavailable }
        try verifyCreation(draft); return draft.review
    }
    private func verifyCreation(_ draft: ProvisioningCreationDraft) throws {
        try environment.admitPackage(); try draft.frozen.storage.verifyRoot()
        do { try draft.frozen.plan.verify(in: draft.frozen.storage.directory) } catch { throw ProvisioningReviewFailure.changed }
    }
    func reserveCreation(_ consent: ProvisioningCreationConsent, vmID: UUID, configurationDigest: String) throws -> ProvisioningSelectionReceipt {
        try reviewAvailable(); try consent.validate()
        guard var draft = creations[consent.reviewID], draft.review.reviewIdentity == consent.reviewIdentity else { throw ProvisioningReviewFailure.consentRequired }
        try verifyCreation(draft)
        let receipt = ProvisioningSelectionReceipt(reviewID: consent.reviewID, vmID: vmID, reviewIdentity: consent.reviewIdentity,
            planDigest: draft.review.planDigest, inputDigest: draft.review.inputDigest, engineDigest: draft.review.engineDigest, configurationDigest: configurationDigest)
        try receipt.validate(vmID: vmID)
        if let existing = draft.reservation { guard existing == receipt else { throw ProvisioningReviewFailure.conflictingConsent } }
        draft.reservation = receipt; creations[consent.reviewID] = draft
        return receipt
    }
    func bindCreation(_ id: UUID) async throws {
        guard let draft = creations[id], let receipt = draft.reservation else { throw ProvisioningReviewFailure.unavailable }
        let targets = await manager.snapshots().filter { $0.profile.developerSetup?.reviewID == id }
        try reviewAvailable(); try verifyCreation(draft)
        guard targets.count == 1, targets[0].id == receipt.vmID, targets[0].profile.developerSetup == receipt else { throw ProvisioningReviewFailure.changed }
        let preview = try draft.frozen.preview(id: id, vmID: receipt.vmID, sessionID: nil, engine: environment.engineDigest)
        drafts[id] = .init(selection: draft.frozen.selection, preview: preview, storage: draft.frozen.storage, plan: draft.frozen.plan)
    }
    var reviewCount: Int { Set(drafts.keys).union(creations.keys).union(draftCaptures).count }
}
