@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

/// Synthetic snapshots only: no VM, runtime, helper or notification is touched.
private struct AttentionFixture {
    let profile: VMProfile
    init(setup: Bool = true) throws {
        var profile = VMProfile(id: UUID(), name: "Attention fixture", clipboardEnabled: false)
        if setup {
            let digest = String(repeating: "e", count: 64)
            profile.developerSetup = try JSONDecoder().decode(ProvisioningSelectionReceipt.self, from: JSONSerialization.data(withJSONObject: [
                "reviewID": UUID().uuidString, "vmID": profile.id.uuidString, "reviewIdentity": digest, "planDigest": digest,
                "inputDigest": digest, "engineDigest": digest, "configurationDigest": digest]))
        }
        self.profile = profile
    }
    func snapshot(_ state: VMState = .running, ssh: SSHReadiness = .ready(user: "fixture_owner", command: "unused"),
                  owner: OwnerSetupReadiness = .manual, failure: VMFailure? = nil) -> VMSnapshot {
        VMSnapshot(profile: profile, state: state, sessionID: state == .running ? UUID() : nil, lastFailure: failure, sshReadiness: ssh, ownerSetupReadiness: owner)
    }
    func row(_ stage: ProvisioningWorkflowStage, id: UUID = UUID(), cleanup: Bool = false, failure: ProvisioningWorkflowFailure? = nil) throws -> ProvisioningWorkflowSnapshot {
        var object: [String: Any] = ["id": id.uuidString, "vmID": profile.id.uuidString, "originalSessionID": UUID().uuidString,
                                     "sequence": 1, "stage": stage.rawValue, "cleanupRequired": cleanup, "applyJobID": id.uuidString]
        if let failure { object["failure"] = failure.rawValue }
        return try JSONDecoder().decode(ProvisioningWorkflowSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func job(_ id: UUID, _ state: ProvisioningJobState, engine: SequencingFailure? = nil, step: GuestOperation? = nil) -> ProvisioningJobSnapshot {
        ProvisioningJobSnapshot(jobID: id, vmID: profile.id, sessionID: UUID(), sequence: 2, state: state, outcome: nil, failure: nil,
                                engineFailure: engine, cleanupFailures: [], cleanupRequired: false, workerOutstanding: state != .timedOut,
                                timedOutOperation: step)
    }
    func attention(_ stage: ProvisioningWorkflowStage, job: ProvisioningJobState? = nil, cleanup: Bool = false,
                   auto: SetupAutoApproval = .none) throws -> SetupAttentionReason? {
        let id = UUID(), row = try row(stage, id: id, cleanup: cleanup)
        let jobs = job.map { [id: self.job(id, $0)] } ?? [:]
        return SetupAttention.make(snapshot(), workflows: [row], jobs: jobs, auto: auto)?.reason
    }
}

private let approved = SetupAutoApproval(approved: true)
private let finishing = SetupAutoApproval(approved: true, finishing: true)
private let blocked = SetupAutoApproval(blocked: true)

@Suite("Setup attention — synthetic state only, no VM or notification") struct SetupAttentionTests {
    @Test func theSudoPromptBlocksAndOpensTheOutputWhateverTheApproval() throws {
        let f = try AttentionFixture()
        for auto in [SetupAutoApproval.none, approved, finishing, blocked] {
            #expect(try f.attention(.running, job: .awaitingAuthorization, auto: auto) == .sudoPrompt)
            #expect(try f.attention(.checking, job: .awaitingAuthorization, auto: auto) == .sudoPrompt)
            #expect(try f.attention(.running, job: .running, auto: auto) == nil)
            #expect(try f.attention(.running, job: .cancelling, auto: auto) == nil)
        }
        #expect(SetupAttentionReason.sudoPrompt.blocksRun && SetupAttentionReason.sudoPrompt.opensOutput)
    }

    @Test func reviewsFollowTheNewVMApproval() throws {
        let f = try AttentionFixture()
        #expect(try f.attention(.readyForReview) == .review)
        #expect(try f.attention(.readyForReview, auto: approved) == nil)
        #expect(try f.attention(.readyForReview, auto: blocked) == .review)
        #expect(try f.attention(.waitingForSSH) == nil && f.attention(.waitingForSSH, auto: blocked) == .review)
        #expect(try f.attention(.restartRequired) == .restartReview)
        #expect(try f.attention(.restartRequired, auto: finishing) == nil)
        #expect(try f.attention(.restartRequired, auto: blocked) == .restartReview)
        for stage in [ProvisioningWorkflowStage.readyForCheck, .waitingForRebind] {
            #expect(try f.attention(stage) == .checkReview)
            #expect(try f.attention(stage, auto: finishing) == nil)
        }
        #expect(!SetupAttentionReason.review.blocksRun)
        for reason in [SetupAttentionReason.review, .restartReview, .checkReview, .cleanup] { #expect(!reason.opensOutput) }
    }

    @Test func cleanupNeedsReviewOnlyOnceTheRunHasStopped() throws {
        let f = try AttentionFixture()
        #expect(try f.attention(.cleanupRequired, cleanup: true) == .cleanup)
        #expect(try f.attention(.failed, cleanup: true) == .cleanup)
        #expect(try f.attention(.running, job: .running, cleanup: true) == nil)
        #expect(try f.attention(.running, job: .awaitingAuthorization, cleanup: true) == .sudoPrompt)
    }

    @Test func everyStageAndJobStateGivesAConsistentAnswer() throws {
        let f = try AttentionFixture()
        let quiet: Set<ProvisioningWorkflowStage> = [.waitingForExit, .restarting, .succeeded, .checked, .failed, .cancelled, .interrupted]
        let states: [ProvisioningJobState?] = [nil, .queued, .running, .awaitingAuthorization, .cleaningUp, .cancelling, .timedOut, .restartRequired]
        let stages: [ProvisioningWorkflowStage] = [.waitingForSSH, .readyForReview, .running, .restartRequired, .waitingForExit, .restarting,
                                                    .waitingForRebind, .readyForCheck, .checking, .succeeded, .checked, .failed, .cancelled, .interrupted, .cleanupRequired]
        for stage in stages {
            for state in states {
                for auto in [SetupAutoApproval.none, approved, finishing, blocked] {
                    let reason = try f.attention(stage, job: state, auto: auto)
                    if quiet.contains(stage) || stage == .cleanupRequired { #expect(reason == nil, "\(stage) \(String(describing: state))") }
                    if reason == .sudoPrompt { #expect(state == .awaitingAuthorization && [.running, .checking].contains(stage)) }
                    if state == .awaitingAuthorization, [.running, .checking].contains(stage) { #expect(reason == .sudoPrompt) }
                }
            }
        }
    }

    @Test func theCurrentRunIgnoresFinishedHistory() throws {
        let f = try AttentionFixture()
        let done = try f.row(.checked), failed = try f.row(.failed), restart = try f.row(.restartRequired), cleanup = try f.row(.cleanupRequired, cleanup: true)
        #expect(SetupAttention.currentRun(f.profile.id, workflows: [done, failed]) == nil)
        #expect(SetupAttention.currentRun(f.profile.id, workflows: [done, restart, failed])?.id == restart.id)
        #expect(SetupAttention.currentRun(f.profile.id, workflows: [restart, cleanup])?.id == cleanup.id)
        #expect(SetupAttention.make(f.snapshot(), workflows: [done, failed], jobs: [:]) == nil)
        #expect(SetupAttention.make(f.snapshot(), workflows: [done, restart], jobs: [:]) == .init(vmID: f.profile.id, workflowID: restart.id, reason: .restartReview))
        let other = try AttentionFixture(setup: false)
        #expect(SetupAttention.make(other.snapshot(), workflows: [restart], jobs: [:]) == nil)
    }

    @Test func aReadyFirstRunWaitsForReviewUnlessApprovedOrBroken() throws {
        let f = try AttentionFixture()
        #expect(SetupAttention.make(f.snapshot(), workflows: [], jobs: [:]) == .init(vmID: f.profile.id, workflowID: nil, reason: .review))
        #expect(SetupAttention.make(f.snapshot(), workflows: [], jobs: [:], auto: approved) == nil)
        #expect(SetupAttention.make(f.snapshot(ssh: .connecting), workflows: [], jobs: [:]) == nil)
        #expect(SetupAttention.make(f.snapshot(ssh: .connecting), workflows: [], jobs: [:], auto: blocked)?.reason == .review)
        #expect(SetupAttention.make(f.snapshot(.stopped, ssh: .stopped), workflows: [], jobs: [:], auto: blocked)?.reason == .review)
        #expect(SetupAttention.make(f.snapshot(owner: .failed("fixture")), workflows: [], jobs: [:]) == nil)
        #expect(SetupAttention.make(f.snapshot(ssh: .failed("fixture")), workflows: [], jobs: [:], auto: blocked) == nil)
        #expect(SetupAttention.make(f.snapshot(.stopped, ssh: .stopped, failure: .init(code: "fixture", message: "fixture")), workflows: [], jobs: [:], auto: blocked) == nil)
        let plain = try AttentionFixture(setup: false)
        #expect(SetupAttention.make(plain.snapshot(), workflows: [], jobs: [:]) == nil)
    }

    @Test func notificationTextIsFixedAndNamesNoGuestData() {
        for reason in SetupAttentionReason.allCases {
            #expect(!reason.summary.isEmpty && !reason.summary.contains("fixture") && reason.summary.count < 120)
        }
        #expect(SetupAttentionReason.sudoPrompt.summary == "Omarchy is asking to enable passwordless sudo")
    }
}

@Suite("Setup attention tracker — one notification per blocked state") struct SetupAttentionTrackerTests {
    let a = UUID(), b = UUID(), run = UUID()
    func blocked(_ vmID: UUID, _ reason: SetupAttentionReason = .sudoPrompt, run: UUID? = nil) -> [UUID: SetupAttention] {
        [vmID: .init(vmID: vmID, workflowID: run ?? self.run, reason: reason)]
    }

    @Test func statesPresentAtLaunchOnlyShowTheMarker() {
        var tracker = SetupAttentionTracker()
        #expect(tracker.update(blocked(a, .cleanup), appActive: false, visibleGuest: nil) == [.marker(true)])
        #expect(tracker.update(blocked(a, .cleanup), appActive: false, visibleGuest: nil).isEmpty)
        #expect(tracker.update([:], appActive: false, visibleGuest: nil) == [.marker(false)])
    }

    @Test func enteringABlockedStateNotifiesOnceAndClearsWhenHandled() {
        var tracker = SetupAttentionTracker()
        #expect(tracker.update([:], appActive: true, visibleGuest: nil).isEmpty)
        let value = blocked(a)
        #expect(tracker.update(value, appActive: false, visibleGuest: nil) == [.bounce, .notify(value[a]!), .marker(true)])
        for _ in 0..<5 { #expect(tracker.update(value, appActive: false, visibleGuest: nil).isEmpty) }
        #expect(tracker.update(value, appActive: true, visibleGuest: a).isEmpty)
        #expect(tracker.update([:], appActive: true, visibleGuest: a) == [.clear(a), .marker(false)])
        #expect(tracker.update([:], appActive: true, visibleGuest: a).isEmpty)
    }

    @Test func aNewBlockedStateIsANewNotification() {
        var tracker = SetupAttentionTracker()
        _ = tracker.update([:], appActive: false, visibleGuest: nil)
        _ = tracker.update(blocked(a), appActive: false, visibleGuest: nil)
        let restart = blocked(a, .restartReview)
        #expect(tracker.update(restart, appActive: false, visibleGuest: nil) == [.clear(a), .bounce, .notify(restart[a]!)])
        let retry = blocked(a, .restartReview, run: UUID())
        #expect(tracker.update(retry, appActive: false, visibleGuest: nil) == [.clear(a), .bounce, .notify(retry[a]!)])
    }

    @Test func onScreenGuestsAreNotNotifiedButOthersAre() {
        var tracker = SetupAttentionTracker()
        _ = tracker.update([:], appActive: true, visibleGuest: a)
        #expect(tracker.update(blocked(a), appActive: true, visibleGuest: a) == [.marker(true)])
        #expect(tracker.update([:], appActive: true, visibleGuest: a) == [.marker(false)])
        let other = blocked(b)
        #expect(tracker.update(other, appActive: true, visibleGuest: a) == [.notify(other[b]!), .marker(true)])
        // Inactive with that guest selected still notifies, and bounces once.
        var both = other; both.merge(blocked(a)) { $1 }
        #expect(tracker.update(both, appActive: false, visibleGuest: a) == [.bounce, .notify(both[a]!)])
    }

    @Test func aSavedSetupWaitingForReviewNeverNotifies() {
        var tracker = SetupAttentionTracker()
        _ = tracker.update([:], appActive: false, visibleGuest: nil)
        #expect(tracker.update(blocked(a, .review), appActive: false, visibleGuest: nil).isEmpty)
        #expect(tracker.update(blocked(a, .sudoPrompt), appActive: false, visibleGuest: nil).count == 3)
        #expect(tracker.update(blocked(a, .review), appActive: false, visibleGuest: nil) == [.clear(a), .marker(false)])
    }
}

@Suite("Setup timeout notes — recorded categories only") struct SetupTimeoutNoteTests {
    @Test func everyStepIsNamedWithItsLimit() throws {
        let f = try AttentionFixture(), id = UUID(), row = try f.row(.failed, id: id)
        func note(_ step: GuestOperation?) -> String? { SetupTimeoutNote.note(row, job: f.job(id, .timedOut, engine: .timedOut, step: step)) }
        #expect(note(.requestPersistentGrant) == "Setup timed out: Omarchy’s passwordless sudo prompt wasn’t answered within an hour.")
        #expect(note(.updateSystem) == "Setup timed out: the Omarchy update didn’t finish within an hour.")
        #expect(note(.clearAuthenticationCache) == "Setup timed out: checking temporary admin access didn’t finish within 30 seconds.")
        #expect(note(.verifyIdentity) == "Setup timed out: checking the guest’s identity didn’t finish within 10 seconds.")
        #expect(note(nil) == "Setup timed out before it finished.")
        for operation in GuestOperation.allCases {
            let text = try #require(note(operation))
            #expect(text.hasPrefix("Setup timed out: ") && text.hasSuffix("."))
            #expect(!text.contains("Fixture") && !text.contains(id.uuidString))
            if ![.quiesceOwnedWork, .revokeGrant, .verifyGrantInactive, .removePayload, .verifyOwnerDockerAccess].contains(operation) {
                #expect(text.contains("within " + SetupTimeoutNote.duration(SetupTimeoutNote.limitSeconds(operation))))
            }
        }
        #expect(SetupTimeoutNote.note(row, job: f.job(id, .failed, engine: .adapterFailed)) == nil)
        #expect(SetupTimeoutNote.note(row, job: nil) == nil)
    }

    @Test func workflowDeadlinesAreNamedToo() throws {
        let f = try AttentionFixture()
        #expect(SetupTimeoutNote.note(try f.row(.failed, failure: .sshTimeout), job: nil) == "Setup timed out: the guest’s SSH service wasn’t ready within 3 minutes.")
        #expect(SetupTimeoutNote.note(try f.row(.failed, failure: .restartTimeout), job: nil) == "Setup timed out: the guest didn’t come back from its restart within 3 minutes.")
    }

    @Test func limitsMatchThePinnedDevVMDeadlines() throws {
        // PRIVATE COUPLING: dev-vm's body deadlines are internal; the vendored source is the contract.
        for operation in GuestOperation.allCases { #expect(SetupTimeoutNote.limitSeconds(operation) == operation.bodyTimeoutSeconds) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let service = try String(contentsOf: repository.appendingPathComponent("Sources/OmarchyVMManagerCore/ProvisioningService.swift"), encoding: .utf8)
        #expect(service.components(separatedBy: "timeout: Duration = .seconds(\(SetupTimeoutNote.workflowLimitSeconds))").count == 4)
    }
}
