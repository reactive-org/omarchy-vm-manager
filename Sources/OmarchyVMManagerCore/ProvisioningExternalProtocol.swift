import DevVMProvisioningCore
import Foundation

public enum ProvisioningExternalOperation: String, Codable, Sendable {
    case capabilities, list, status, cancel, attach, read, reset, claim, release, input, resize, detach, heartbeat
    case prepareCreation, creation, previewCreate, preview, taskSource, prepareApply, apply, prepareAction, performAction
}
/// External protocol 1, exclusively on setup-v1.sock. A connection owns at most
/// one attachment. Helper capabilities and credentials never leave the manager.
public struct ProvisioningExternalRequest: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let version: Int
    public let requestID: UUID
    public let sequence: UInt64
    public let operation: ProvisioningExternalOperation
    public var workflowID: UUID?
    public var action: ProvisioningWorkflowAction?
    public var actionReviewID: UUID?
    public var actionConsent: ProvisioningWorkflowActionConsent?
    public var previewID: UUID?
    public var vmID: UUID?
    public var source: ProvisioningSetupSource?
    public var consent: ProvisioningApplyConsent?
    public var taskName: String?
    public var offset: Int?
    public var invocationID: UUID?
    public var bytes: Data?
    public var rows: Int?
    public var columns: Int?
    public init(sequence: UInt64, operation: ProvisioningExternalOperation, workflowID: UUID? = nil) {
        version = 1; requestID = UUID(); self.sequence = sequence; self.operation = operation; self.workflowID = workflowID
    }
    /// Preparation may run bounded tool/SSH probes. Transport framing remains
    /// short by default; only these owned operations receive a longer reply lease.
    var responseTimeout: Duration {
        switch operation {
        case .prepareCreation, .creation, .previewCreate, .preview, .prepareApply, .apply, .prepareAction, .performAction, .cancel: .seconds(120)
        default: .seconds(3)
        }
    }
    public var description: String { "ProvisioningExternalRequest(redacted)" }
    public var debugDescription: String { description }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 9 * 1024, case .object(let fields) = try PlainDataParser.parse(data, format: .json) else { throw ProvisioningTerminalDenial.bounds }
        let v = try JSONDecoder().decode(Self.self, from: data)
        var keys: Set<String> = ["version", "requestID", "sequence", "operation"]
        let reviewOperations: Set<ProvisioningExternalOperation> = [.prepareCreation, .creation, .previewCreate, .preview, .taskSource, .prepareApply, .apply]
        if reviewOperations.contains(v.operation) { keys.insert("previewID") }
        else if ![.capabilities, .list].contains(v.operation) { keys.insert("workflowID") }
        if v.operation == .prepareAction { keys.formUnion(["action", "actionReviewID"]) }
        if v.operation == .performAction { keys.insert("actionConsent") }
        if v.operation == .prepareCreation { keys.insert("source") }
        if v.operation == .previewCreate { keys.formUnion(["vmID", "source"]) }
        if v.operation == .apply { keys.insert("consent") }
        if v.operation == .taskSource { keys.formUnion(["taskName", "offset"]) }
        if [.input, .resize].contains(v.operation) { keys.insert("invocationID") }
        if v.operation == .input { keys.insert("bytes") }
        if [.claim, .resize].contains(v.operation) { keys.formUnion(["rows", "columns"]) }
        guard v.version == 1, v.sequence > 0, v.sequence < UInt64(Int64.max), Set(fields.keys) == keys,
              [.capabilities, .list].contains(v.operation) || (reviewOperations.contains(v.operation) ? v.previewID != nil : v.workflowID != nil),
              ![.input, .resize].contains(v.operation) || v.invocationID != nil else { throw ProvisioningTerminalDenial.bounds }
        if v.operation == .prepareAction { guard v.action != nil, v.actionReviewID != nil else { throw ProvisioningTerminalDenial.bounds } }
        if v.operation == .performAction { guard let consent = v.actionConsent else { throw ProvisioningTerminalDenial.bounds }; try consent.validate() }
        if v.operation == .prepareCreation { guard let source = v.source else { throw ProvisioningTerminalDenial.bounds }; try source.validate() }
        if v.operation == .previewCreate { guard v.vmID != nil, let source = v.source else { throw ProvisioningTerminalDenial.bounds }; try source.validate() }
        if v.operation == .apply { guard let consent = v.consent else { throw ProvisioningTerminalDenial.bounds }; try consent.validate() }
        if v.operation == .taskSource {
            guard let name = v.taskName, !name.isEmpty, name.utf8.count <= 64, let offset = v.offset, offset >= 0, offset <= SourceSnapshot.maximumBytes else { throw ProvisioningTerminalDenial.bounds }
        }
        guard try PlainDataParser.parse(helperJSON(v), format: .json) == PlainDataParser.parse(data, format: .json) else { throw ProvisioningTerminalDenial.bounds }
        if v.operation == .input { guard let bytes = v.bytes, !bytes.isEmpty, bytes.count <= 4096 else { throw ProvisioningTerminalDenial.bounds } }
        if [.claim, .resize].contains(v.operation) {
            guard let rows = v.rows, let columns = v.columns else { throw ProvisioningTerminalDenial.bounds }
            _ = try ProvisioningTerminalSize(rows: rows, columns: columns)
        }
        return v
    }
}
public struct ProvisioningExternalReply: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let version: Int
    public let requestID: UUID
    public let sequence: UInt64
    public let operation: ProvisioningExternalOperation
    public var workflowActionReview: ProvisioningWorkflowActionReview?
    public var previewPlan: ProvisioningPlanPreview?
    public var creationReview: ProvisioningCreationReview?
    public var applyReview: ProvisioningApplyReview?
    public var taskSource: ProvisioningTaskSource?
    public var executionEnabled: Bool?
    public var workflows: [ProvisioningWorkflowSnapshot]?
    public var job: ProvisioningJobSnapshot?
    public var page: ProvisioningTerminalPage?
    public var failure: String?
    public var description: String { "ProvisioningExternalReply(redacted)" }
    public var debugDescription: String { description }
    init(_ r: ProvisioningExternalRequest) { version = 1; requestID = r.requestID; sequence = r.sequence; operation = r.operation }
    static func decode(_ data: Data, request: ProvisioningExternalRequest) throws -> Self {
        guard data.count <= 128 * 1024, case .object(let fields) = try PlainDataParser.parse(data, format: .json) else { throw ProvisioningTerminalDenial.bounds }
        let v = try JSONDecoder().decode(Self.self, from: data)
        var keys: Set<String> = ["version", "requestID", "sequence", "operation"]
        if v.failure != nil { keys.insert("failure") }
        else {
            switch request.operation {
            case .capabilities: keys.insert("executionEnabled")
            case .prepareCreation, .creation: keys.insert("creationReview")
            case .previewCreate, .preview: keys.insert("previewPlan")
            case .prepareApply: keys.insert("applyReview")
            case .prepareAction: keys.insert("workflowActionReview")
            case .taskSource: keys.insert("taskSource")
            case .apply, .performAction: keys.insert("workflows")
            case .list, .status, .cancel: keys.insert("workflows"); if v.job != nil && request.operation != .list { keys.insert("job") }
            case .read, .reset: keys.insert("page")
            default: break
            }
        }
        guard v.version == 1, v.requestID == request.requestID, v.sequence == request.sequence, v.operation == request.operation,
              Set(fields.keys) == keys,
              v.failure == nil || ["unavailable", "busy", "already-run", "unknown-workflow", "denied", "disabled", "review-required", "task-trust-required", "changed", "quota", "consent-conflict", "ownership-unverified", "profile-conflict", "theme-invalid", "theme-unavailable", "theme-catalogue", "theme-stars-unavailable", "theme-no-match", "layout-invalid", "workstation-disabled"].contains(v.failure!),
              v.failure != nil || (request.operation != .capabilities || v.executionEnabled != nil),
              v.failure != nil || (![.list, .status, .cancel, .apply, .performAction].contains(request.operation) || v.workflows != nil),
              v.failure != nil || (![.read, .reset].contains(request.operation) || v.page != nil) else { throw ProvisioningTerminalDenial.bounds }
        let encoded = try PlainDataParser.parse(helperJSON(v), format: .json)
        guard encoded == (try PlainDataParser.parse(data, format: .json)), (v.workflows?.count ?? 0) <= 128 else { throw ProvisioningTerminalDenial.bounds }
        if let review = v.workflowActionReview {
            try review.validate()
            guard review.id == request.actionReviewID, review.workflowID == request.workflowID, review.action == request.action else { throw ProvisioningTerminalDenial.bounds }
        }
        if let review = v.creationReview {
            try review.validate(); guard review.id == request.previewID else { throw ProvisioningTerminalDenial.bounds }
        }
        if let preview = v.previewPlan {
            try preview.validate(); guard preview.id == request.previewID, request.operation != .previewCreate || preview.vmID == request.vmID else { throw ProvisioningTerminalDenial.bounds }
        }
        if let review = v.applyReview { try review.validate(); guard review.previewID == request.previewID else { throw ProvisioningTerminalDenial.bounds } }
        if let source = v.taskSource {
            guard source.previewID == request.previewID, source.name == request.taskName, source.offset == request.offset,
                  provisioningDigest(source.sha256), source.bytes.count <= 4096, source.total >= 0, source.total <= SourceSnapshot.maximumBytes,
                  source.offset >= 0, source.offset <= source.total, source.bytes.count == min(4096, source.total - source.offset) else { throw ProvisioningTerminalDenial.bounds }
        }
        guard v.failure != nil || (![.prepareCreation, .creation].contains(request.operation) || v.creationReview != nil),
              v.failure != nil || (![.previewCreate, .preview].contains(request.operation) || v.previewPlan != nil),
              v.failure != nil || (request.operation != .prepareApply || v.applyReview != nil),
              v.failure != nil || (request.operation != .taskSource || v.taskSource != nil),
              v.failure != nil || (request.operation != .prepareAction || v.workflowActionReview != nil) else { throw ProvisioningTerminalDenial.bounds }
        if [.status, .cancel, .apply, .performAction].contains(request.operation), let rows = v.workflows {
            guard rows.count == 1, rows[0].id == (request.operation == .apply ? request.previewID : request.workflowID) else { throw ProvisioningTerminalDenial.bounds }
            if let job = v.job { guard job.vmID == rows[0].vmID, [rows[0].checkJobID, rows[0].applyJobID].contains(job.jobID) else { throw ProvisioningTerminalDenial.bounds } }
        }
        if let page = v.page {
            // Reuse the strict helper page grammar, without exposing its tokens.
            let packet = ProvisioningTerminalPacket(version: 1, jobID: request.workflowID!, requestID: request.requestID, operation: request.operation == .read ? .read : .reset, attachmentID: request.requestID)
            var reply = ProvisioningTerminalReply(version: 1, jobID: packet.jobID, requestID: packet.requestID, operation: packet.operation, attachmentID: packet.attachmentID)
            reply.page = page; _ = try ProvisioningTerminalReply.decode(helperJSON(reply), request: packet)
        }
        return v
    }
}

actor ProvisioningExternalSession {
    let service: any ProvisioningObserving
    private var attachment: ProvisioningTerminalAttachment?
    private var workflowID: UUID?
    private var sequence: UInt64 = 0
    private var closed = false
    init(service: any ProvisioningObserving) { self.service = service }
    func handle(_ r: ProvisioningExternalRequest) async throws -> ProvisioningExternalReply {
        guard !closed, r.sequence == sequence + 1 else { throw ProvisioningTerminalDenial.attachment }
        _ = try ProvisioningExternalRequest.decode(helperJSON(r))
        sequence = r.sequence
        var reply = ProvisioningExternalReply(r)
        do {
            switch r.operation {
            case .capabilities: reply.executionEnabled = service.executionEnabled
            case .prepareAction, .performAction:
                guard let service = service as? any ProvisioningWorkflowActing else { reply.failure = "unavailable"; return reply }
                if r.operation == .prepareAction { reply.workflowActionReview = try await service.prepareAction(r.workflowID!, action: r.action!, reviewID: r.actionReviewID!) }
                else { reply.workflows = [try await service.performAction(r.workflowID!, consent: r.actionConsent!)] }
            case .prepareCreation, .creation:
                guard let service = service as? any ProvisioningCreationPlanning else { reply.failure = "unavailable"; return reply }
                reply.creationReview = r.operation == .prepareCreation ? try await service.prepareCreation(id: r.previewID!, source: r.source!) : try await service.creation(r.previewID!)
            case .previewCreate, .preview, .taskSource, .prepareApply, .apply:
                guard let service = service as? any ProvisioningReviewing else { reply.failure = "unavailable"; return reply }
                switch r.operation {
                case .previewCreate: reply.previewPlan = try await service.preview(id: r.previewID!, vmID: r.vmID!, source: r.source!)
                case .preview: reply.previewPlan = try await service.preview(r.previewID!)
                case .taskSource: reply.taskSource = try await service.taskSource(r.previewID!, name: r.taskName!, offset: r.offset!)
                case .prepareApply: reply.applyReview = try await service.prepareApply(r.previewID!)
                case .apply: reply.workflows = [try await service.apply(r.previewID!, consent: r.consent!)]
                default: break
                }
            case .list: reply.workflows = await service.statuses()
            case .status, .cancel:
                guard let row = await service.status(r.workflowID!) else { reply.failure = "unknown-workflow"; return reply }
                if r.operation == .cancel { try await service.cancel(row.id) }
                reply.workflows = [await service.status(row.id) ?? row]
                reply.job = await service.jobStatus(row.id)
            case .attach:
                guard attachment == nil else { throw ProvisioningTerminalDenial.attachment }
                let value = try await service.attachTerminal(r.workflowID!)
                guard !closed else { await value.detach(); throw ProvisioningTerminalDenial.attachment }
                attachment = value; workflowID = r.workflowID
            default:
                guard let attachment, workflowID == r.workflowID else { throw ProvisioningTerminalDenial.attachment }
                switch r.operation {
                case .read: reply.page = try await attachment.poll()
                case .reset: reply.page = try await attachment.acknowledgeReset()
                case .claim: try await attachment.claimInput(rows: r.rows!, columns: r.columns!)
                case .release: try await attachment.releaseInput()
                case .input: try await attachment.send(r.bytes!, invocationID: r.invocationID!)
                case .resize: try await attachment.resize(rows: r.rows!, columns: r.columns!, invocationID: r.invocationID!)
                case .heartbeat: try await attachment.heartbeat()
                case .detach: await attachment.detach(); self.attachment = nil; workflowID = nil
                default: throw ProvisioningTerminalDenial.attachment
                }
            }
            guard !closed else { throw ProvisioningTerminalDenial.attachment }
        } catch ProvisioningTerminalDenial.busy { reply.failure = "busy" }
        catch ProvisioningServiceFailure.disabled { reply.failure = "disabled" }
        catch ProvisioningServiceFailure.reviewRequired { reply.failure = "review-required" }
        catch ProvisioningServiceFailure.busy { reply.failure = "busy" }
        catch ProvisioningServiceFailure.alreadyRun { reply.failure = "already-run" }
        catch ProvisioningJobFailure.ownershipUnverified { reply.failure = "ownership-unverified" }
        catch let failure as ProvisioningReviewFailure {
            switch failure {
            case .consentRequired: reply.failure = "review-required"
            case .taskTrustRequired: reply.failure = "task-trust-required"
            case .changed: reply.failure = "changed"
            case .quota: reply.failure = "quota"
            case .conflictingConsent: reply.failure = "consent-conflict"
            case .conflictingProfiles: reply.failure = "profile-conflict"
            default: reply.failure = "denied"
            }
        }
        catch let failure as ThemeSelectionFailure {
            switch failure {
            case .invalidSelector: reply.failure = "theme-invalid"
            case .inaccessible: reply.failure = "theme-unavailable"
            case .catalogue, .responseTooLarge: reply.failure = "theme-catalogue"
            case .starsUnavailable: reply.failure = "theme-stars-unavailable"
            case .noEligibleThemes: reply.failure = "theme-no-match"
            }
        }
        catch let failure as ProvisioningAppearanceFailure { reply.failure = failure == .invalidLayout ? "layout-invalid" : "workstation-disabled" }
        catch { reply.failure = "denied" }
        return reply
    }
    func close() async { closed = true; let value = attachment; attachment = nil; await value?.detach() }
}
