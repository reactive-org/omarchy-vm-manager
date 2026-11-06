import Foundation

/// Manager-supplied identity, not guest discovery or authentication by this package.
/// A concrete adapter must enforce these pins at connection/operation time.
public struct GuestBinding: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let vmID: UUID
    public let sessionID: UUID
    public let owner: String
    public let ownerUID: UInt32
    public let hostKeyDigest: String
    public init(vmID: UUID, sessionID: UUID, owner: String, ownerUID: UInt32, hostKeyDigest: String) throws {
        guard owner != "root", ownerUID > 0, matches(owner, "[a-z_][a-z0-9_-]{0,31}"),
              matches(hostKeyDigest, "[a-f0-9]{64}") else { throw SequencingFailure.invalidRequest }
        self.vmID = vmID; self.sessionID = sessionID; self.owner = owner
        self.ownerUID = ownerUID; self.hostKeyDigest = hostKeyDigest
    }
    public var description: String { "GuestBinding(redacted)" }
    public var debugDescription: String { description }
    var reviewValue: ManifestValue {
        .object(["vm": .string(vmID.uuidString), "session": .string(sessionID.uuidString),
                 "owner": .string(owner), "uid": .integer(Int64(ownerUID)), "host_key": .string(hostKeyDigest)])
    }
}

public enum ProvisioningMode: String, Sendable, Codable { case apply, check }
public enum DotfileConflictPolicy: String, Sendable, Codable { case fail, backup }
public enum SequencingFailure: String, Error, Sendable, Codable {
    case invalidRequest, approvalRequired, taskTrustRequired, authorizationConsentRequired
    case dockerConsentRequired, authorizationRequired, alreadyUsed, sourceChanged
    case identityMismatch, dependencyChanged, protocolViolation, adapterFailed, timedOut, cancelled, systemUpdateFailed
}

/// Explicit review scope. Changing mode, task selection, target, dependencies or
/// input lease changes reviewIdentity. This does not authorize a real transport.
public struct ProvisioningRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let jobID: UUID
    public let plan: SetupPlan
    public let repository: URL
    public let target: GuestBinding
    public let dependencyDigest: String
    public let mode: ProvisioningMode
    public let selectedTasks: [String]
    public let includeTasksInCheck: Bool
    public let conflictPolicy: DotfileConflictPolicy
    public let inputLeaseID: UUID?
    public let reviewIdentity: String
    public var description: String { "ProvisioningRequest(redacted)" }
    public var debugDescription: String { description }
    public init(jobID: UUID, plan: SetupPlan, repository: URL, target: GuestBinding, dependencyDigest: String,
                mode: ProvisioningMode = .apply, tasks: [String]? = nil, includeTasksInCheck: Bool = false,
                conflictPolicy: DotfileConflictPolicy = .fail, inputLeaseID: UUID? = nil) throws {
        guard matches(dependencyDigest, "[a-f0-9]{64}"), !includeTasksInCheck || mode == .check,
              let declared = plan.document.object?["tasks"]?.array?.compactMap({ $0.object?["name"]?.string })
        else { throw SequencingFailure.invalidRequest }
        let names = tasks ?? declared
        guard Set(names).count == names.count, Set(names).isSubset(of: Set(declared)) else { throw SequencingFailure.invalidRequest }
        self.jobID = jobID; self.plan = plan; self.repository = repository; self.target = target
        self.dependencyDigest = dependencyDigest; self.mode = mode; self.includeTasksInCheck = includeTasksInCheck
        selectedTasks = declared.filter { names.contains($0) && (mode == .apply || includeTasksInCheck) }
        self.conflictPolicy = conflictPolicy; self.inputLeaseID = inputLeaseID
        reviewIdentity = digest(try canonicalData(ManifestValue.object([
            "sequencing_api": .integer(2), "system_update": .bool(mode == .apply),
            "job": .string(jobID.uuidString), "plan": .string(plan.identity),
            "target": target.reviewValue, "dependencies": .string(dependencyDigest), "mode": .string(mode.rawValue),
            "tasks": .array(selectedTasks.map(ManifestValue.string)), "check_tasks": .bool(includeTasksInCheck),
            "conflict": .string(conflictPolicy.rawValue), "input_lease": inputLeaseID.map { .string($0.uuidString) } ?? .null])))
    }
    var dockerOptIn: Bool {
        mode == .apply && plan.document.object?["requirements"]?.object?["desktop_restart_required"] == .bool(true)
    }
}

/// A caller must obtain these acknowledgements through its review UI. There is
/// deliberately no password, token, keystroke or unattended-secret field.
public struct ProvisioningApproval: Sendable {
    public let reviewIdentity: String
    public let customTasksReviewed: Bool
    public let persistentGrantAcknowledged: Bool
    public let dockerRootAccessAcknowledged: Bool
    public init(reviewIdentity: String, customTasksReviewed: Bool = false,
                persistentGrantAcknowledged: Bool = false, dockerRootAccessAcknowledged: Bool = false) {
        self.reviewIdentity = reviewIdentity; self.customTasksReviewed = customTasksReviewed
        self.persistentGrantAcknowledged = persistentGrantAcknowledged
        self.dockerRootAccessAcknowledged = dockerRootAccessAcknowledged
    }
}

public enum GuestOperation: String, Sendable, Codable, CaseIterable {
    case verifyIdentity, stagePayload, resetGrant, clearAuthenticationCache, requestPersistentGrant, verifyGrantActive
    case updateSystem, installManifestPackages, configureFeatures, configureDockerOwnerAccess, configureRepository
    case quiesceOwnedWork, revokeGrant, verifyGrantInactive, removePayload, verifyOwnerDockerAccess
    var interactive: Bool { [.requestPersistentGrant, .updateSystem, .configureDockerOwnerAccess, .installManifestPackages].contains(self) }
    var bodyTimeoutSeconds: Int {
        if [.requestPersistentGrant, .configureDockerOwnerAccess].contains(self) { return 120 }
        if self == .verifyIdentity { return 10 }
        if [.resetGrant, .clearAuthenticationCache, .verifyGrantActive].contains(self) { return 30 }
        return 3600
    }
    var expectedProof: GuestProof {
        switch self {
        case .verifyIdentity: .identityVerified
        case .verifyGrantActive: .grantActiveWithoutCachedAuthentication
        case .verifyGrantInactive: .grantInactiveAndCacheCleared
        case .quiesceOwnedWork: .ownedWorkStopped
        case .removePayload: .payloadAbsent
        default: .completed
        }
    }
}
public enum GuestProof: String, Sendable, Codable {
    case completed, identityVerified, grantActiveWithoutCachedAuthentication
    case grantInactiveAndCacheCleared, ownedWorkStopped, payloadAbsent
}

/// Opaque job-owned payload identity; never a caller-supplied shell/storage path.
public struct GuestJobContext: Sendable, Equatable {
    public let jobID: UUID
    public let payloadID: UUID
    public let target: GuestBinding
    public let dependencyDigest: String
    public let mode: ProvisioningMode
}
public struct GuestCommand: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let protocolVersion = 1
    public let id: UUID
    public let context: GuestJobContext
    public let operation: GuestOperation
    public let mode: ProvisioningMode
    public let inputLeaseID: UUID?
    public let timeoutSeconds: Int
    public let plan: SetupPlan?
    public let tasks: [String]
    public let conflictPolicy: DotfileConflictPolicy
    public var description: String { "GuestCommand(\(operation.rawValue), redacted)" }
    public var debugDescription: String { description }
}
public struct GuestReply: Sendable {
    public let protocolVersion: Int
    public let commandID: UUID
    public let jobID: UUID
    public let target: GuestBinding
    public let dependencyDigest: String
    public let proof: GuestProof
    public init(protocolVersion: Int = 1, commandID: UUID, jobID: UUID, target: GuestBinding,
                dependencyDigest: String, proof: GuestProof) {
        self.protocolVersion = protocolVersion; self.commandID = commandID; self.jobID = jobID
        self.target = target; self.dependencyDigest = dependencyDigest; self.proof = proof
    }
}

/// The concrete SSH/Ansible adapter requires an explicitly injected process
/// runner. Local pipe/PTY support does not enable CLI or VM lifecycle actions.
/// An adapter must honor deadlines, bind every operation to the expected pins,
/// and confirm local exit or retain/report uncertain cleanup. Local completion is
/// not proof that remote descendants stopped: cleanup requires a separate proof.
public protocol ProvisioningGuestAdapter: Sendable {
    func perform(_ command: GuestCommand) async throws -> GuestReply
    func interrupt(commandID: UUID, context: GuestJobContext) async
}

public enum ProvisioningPhase: String, Sendable, Codable {
    case idle, validating, awaitingAuthorization, staging, authorizing, updating, applying, checking
    case quiescing, revoking, removingPayload, verifyingOwnerAccess, finished
}
public enum ProvisioningOutcome: String, Sendable, Codable {
    case applied, appliedRestartRequired, checked, failed, cancelled, timedOut, authorizationRequired, cleanupRequired
    case cleanupConfirmed, rejected
}
public enum SequencingEventKind: String, Sendable, Codable { case phaseChanged, started, completed, failed }
public struct SequencingEvent: Sendable, Codable {
    public let jobID: UUID
    public let vmID: UUID
    public let sessionID: UUID
    public let commandID: UUID?
    public let kind: SequencingEventKind
    public let phase: ProvisioningPhase
    public let operation: GuestOperation?
    public let failure: SequencingFailure?
}
/// In-memory recovery handle only. Persisting private metadata belongs to the
/// later manager journal. Never serialize a binding, credentials or frozen bytes
/// through the user-facing report/event stream.
public struct CleanupTicket: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let context: GuestJobContext
    let grantMayBeActive: Bool
    let payloadMayExist: Bool
    let workMayBeActive: Bool
    public var description: String { "CleanupTicket(redacted)" }
    public var debugDescription: String { description }
}
public struct SequencingResult: Sendable, Encodable {
    public let schemaVersion = 1
    public let outcome: ProvisioningOutcome
    public let primaryFailure: SequencingFailure?
    public let cleanupFailures: [SequencingFailure]
    public let events: [SequencingEvent]
    public let recovery: CleanupTicket?
    enum CodingKeys: String, CodingKey { case schemaVersion, outcome, primaryFailure, cleanupFailures, events }
}
