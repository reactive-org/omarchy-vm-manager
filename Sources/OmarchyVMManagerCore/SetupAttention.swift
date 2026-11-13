import DevVMProvisioningCore
import Foundation

/// What a guest's setup is waiting on the owner for. Built only from recorded
/// workflow stages, job states and the in-memory New VM approval; never from
/// terminal output. The Home card, first-run tracker, sidebar, Dock and
/// notifications all read this one value so they can't disagree (issue #16).
public enum SetupAttentionReason: String, Sendable, Equatable, CaseIterable {
    /// Omarchy's passwordless-sudo prompt is up in the setup terminal.
    case sudoPrompt
    /// A saved setup is waiting for review before it starts. Doesn't block a run.
    case review
    /// Software is installed; the restart that finishes setup needs review.
    case restartReview
    /// The guest restarted; the configuration check needs review.
    case checkReview
    /// A run stopped before temporary admin access was confirmed removed.
    case cleanup

    /// True when a run in progress can't continue until the owner acts. Only
    /// these states notify, mark the Dock or bounce it.
    public var blocksRun: Bool { self != .review }
    /// Where a click goes: the live output at the prompt, or the review.
    public var opensOutput: Bool { self == .sudoPrompt }
    /// Fixed wording for a notification body. Never terminal output or guest data.
    public var summary: String {
        switch self {
        case .sudoPrompt: "Omarchy is asking to enable passwordless sudo"
        case .review: "Setup is waiting for your review"
        case .restartReview: "Software is installed. Review the restart that finishes setup"
        case .checkReview: "The guest restarted. Review the configuration check that finishes setup"
        case .cleanup: "Setup stopped before temporary admin access was confirmed removed. Review cleanup"
        }
    }
}

/// The New VM one-time approval, reduced to what attention depends on.
public struct SetupAutoApproval: Equatable, Sendable {
    /// Approved in New VM and not blocked: the first review is submitted automatically.
    public var approved: Bool
    /// Following an applied run: the restart and check are submitted automatically.
    public var finishing: Bool
    /// The approval no longer applies; the manual review takes over.
    public var blocked: Bool
    public init(approved: Bool = false, finishing: Bool = false, blocked: Bool = false) {
        self.approved = approved; self.finishing = finishing; self.blocked = blocked
    }
    public static let none = SetupAutoApproval()
}

public struct SetupAttention: Equatable, Sendable {
    public let vmID: UUID
    /// The run that is waiting, or nil when no run has been prepared yet.
    public let workflowID: UUID?
    public let reason: SetupAttentionReason

    public init(vmID: UUID, workflowID: UUID?, reason: SetupAttentionReason) {
        self.vmID = vmID; self.workflowID = workflowID; self.reason = reason
    }

    /// The one run Home describes. UUID order is not chronology: only a
    /// cleanup-bound or still-open run is current, or the only run there is.
    public static func currentRun(_ vmID: UUID, workflows: [ProvisioningWorkflowSnapshot]) -> ProvisioningWorkflowSnapshot? {
        let rows = workflows.filter { $0.vmID == vmID }
        return rows.first(where: \.cleanupRequired) ?? rows.first(where: \.canCancel) ?? (rows.count == 1 ? rows.first : nil)
    }

    public static func make(_ snapshot: VMSnapshot, workflows: [ProvisioningWorkflowSnapshot], jobs: [UUID: ProvisioningJobSnapshot],
                            auto: SetupAutoApproval = .none) -> SetupAttention? {
        let rows = workflows.filter { $0.vmID == snapshot.id }
        guard !rows.isEmpty else {
            // First run: the guest is ready and its saved setup hasn't been reviewed.
            guard snapshot.profile.developerSetup != nil, !guestProblem(snapshot) else { return nil }
            if auto.blocked { return .init(vmID: snapshot.id, workflowID: nil, reason: .review) }
            guard !auto.approved, snapshot.state == .running, case .ready = snapshot.sshReadiness else { return nil }
            return .init(vmID: snapshot.id, workflowID: nil, reason: .review)
        }
        guard let row = currentRun(snapshot.id, workflows: workflows) else { return nil }
        func reason(_ value: SetupAttentionReason) -> SetupAttention { .init(vmID: snapshot.id, workflowID: row.id, reason: value) }
        if row.cleanupRequired, !row.canCancel { return reason(.cleanup) }
        switch row.stage {
        case .running, .checking:
            return jobs[row.id]?.state == .awaitingAuthorization ? reason(.sudoPrompt) : nil
        case .readyForReview:
            return auto.approved ? nil : reason(.review)
        case .waitingForSSH:
            // The New VM approval stopped applying before the review was ready.
            return auto.blocked ? reason(.review) : nil
        case .restartRequired:
            return auto.finishing ? nil : reason(.restartReview)
        case .readyForCheck, .waitingForRebind:
            return auto.finishing ? nil : reason(.checkReview)
        case .waitingForExit, .restarting, .succeeded, .checked, .failed, .cancelled, .interrupted, .cleanupRequired:
            return nil
        }
    }

    /// A stopped guest's failure, or a running guest whose account setup or SSH
    /// failed: the first-run tracker shows a problem to fix, not a review.
    private static func guestProblem(_ snapshot: VMSnapshot) -> Bool {
        switch snapshot.state {
        case .stopped, .failed: return snapshot.lastFailure != nil
        case .running:
            if case .failed = snapshot.ownerSetupReadiness { return true }
            switch snapshot.sshReadiness {
            case .failed, .disabled: return true
            default: return false
            }
        default: return false
        }
    }
}

/// Decides, from successive attention observations, when to notify, clear,
/// bounce the Dock and show its marker. Pure so the rules are unit-tested:
/// one notification per entry into a blocking state, never repeated, cleared
/// once that state ends; nothing for reviews of a saved setup; nothing for
/// states already present at the first observation after launch.
public struct SetupAttentionTracker: Sendable {
    public enum Effect: Equatable, Sendable {
        /// Post one notification for this guest.
        case notify(SetupAttention)
        /// Remove this guest's notification, if one was posted.
        case clear(UUID)
        /// Bounce the Dock icon once.
        case bounce
        /// Show or hide the Dock marker that something is blocked.
        case marker(Bool)
    }
    private var started = false
    private var episodes: [UUID: SetupAttention] = [:]
    private var notified: Set<UUID> = []
    private var marker = false

    public init() {}

    /// `appActive` is whether the manager is frontmost; `visibleGuest` is the
    /// guest whose page is on screen, if any.
    public mutating func update(_ attention: [UUID: SetupAttention], appActive: Bool, visibleGuest: UUID?) -> [Effect] {
        let blocking = attention.filter { $0.value.reason.blocksRun }
        var effects: [Effect] = []
        for (vmID, previous) in episodes.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where blocking[vmID] != previous {
            episodes.removeValue(forKey: vmID)
            if notified.remove(vmID) != nil { effects.append(.clear(vmID)) }
        }
        var bounced = false
        for (vmID, value) in blocking.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where episodes[vmID] == nil {
            episodes[vmID] = value
            guard started else { continue }
            if !appActive, !bounced { bounced = true; effects.append(.bounce) }
            if !(appActive && visibleGuest == vmID) { notified.insert(vmID); effects.append(.notify(value)) }
        }
        if marker != !blocking.isEmpty { marker = !blocking.isEmpty; effects.append(.marker(marker)) }
        started = true
        return effects
    }
}

/// Names the step that ran out of time, from the categories recorded on the
/// workflow and job. Never reads terminal output.
public enum SetupTimeoutNote {
    /// Body deadlines in the pinned dev-vm sequencer (`GuestOperation.bodyTimeoutSeconds`,
    /// which isn't public). PRIVATE COUPLING: a source contract test pins them.
    public static func limitSeconds(_ operation: GuestOperation) -> Int {
        if operation == .verifyIdentity { return 10 }
        if [.resetGrant, .clearAuthenticationCache, .verifyGrantActive].contains(operation) { return 30 }
        return 3600
    }
    /// The manager's own SSH-wait and restart deadlines (ProvisioningService defaults).
    public static let workflowLimitSeconds = 180

    public static func note(_ row: ProvisioningWorkflowSnapshot, job: ProvisioningJobSnapshot?) -> String? {
        switch row.failure {
        case .sshTimeout?: return "Setup timed out: the guest’s SSH service wasn’t ready within " + duration(workflowLimitSeconds) + "."
        case .restartTimeout?: return "Setup timed out: the guest didn’t come back from its restart within " + duration(workflowLimitSeconds) + "."
        default: break
        }
        guard job?.engineFailure == .timedOut else { return nil }
        guard let operation = job?.timedOutOperation else { return "Setup timed out before it finished." }
        return "Setup timed out: " + step(operation) + "."
    }

    static func step(_ operation: GuestOperation) -> String {
        let within = " within " + duration(limitSeconds(operation))
        switch operation {
        // A renewal only waits when Omarchy revoked the timed grant and asks again.
        case .requestPersistentGrant, .requestTemporaryGrant, .renewTemporaryGrant: return "Omarchy’s passwordless sudo prompt wasn’t answered" + within
        case .updateSystem: return "the Omarchy update didn’t finish" + within
        case .installManifestPackages: return "installing packages didn’t finish" + within
        case .configureFeatures: return "installing your selected features didn’t finish" + within
        case .configureDockerOwnerAccess: return "setting up Docker access without sudo didn’t finish" + within
        case .configureRepository: return "applying your desktop and workstation settings didn’t finish" + within
        case .stagePayload: return "copying setup files into the guest didn’t finish" + within
        case .resetGrant, .clearAuthenticationCache, .verifyGrantActive: return "checking temporary admin access didn’t finish" + within
        case .verifyIdentity: return "checking the guest’s identity didn’t finish" + within
        case .quiesceOwnedWork, .revokeGrant, .verifyGrantInactive, .removePayload, .verifyOwnerDockerAccess:
            return "a setup step didn’t finish in time"
        }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds == 3600 { return "an hour" }
        if seconds % 3600 == 0 { return "\(seconds / 3600) hours" }
        if seconds % 60 == 0 { return seconds == 60 ? "a minute" : "\(seconds / 60) minutes" }
        return "\(seconds) seconds"
    }
}

extension GuestOperation {
    /// The step that shows Omarchy's passwordless sudo prompt. A timed grant's
    /// renewal normally finishes at once without one, so it isn't counted: only
    /// an omarchy-settings upgrade can make it ask again (TO PROVE on a guest).
    var asksForSudoGrant: Bool { self == .requestPersistentGrant || self == .requestTemporaryGrant }
}
