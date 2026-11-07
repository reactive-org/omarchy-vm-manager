#if DEBUG
import AppKit
import CryptoKit
import OmarchyProvisioningTerminalUI
import OmarchyVMManagerCore
import SwiftUI

/// Local object injected into a hidden fixture tree only. No notifications,
/// sockets, accessibility grants, environment toggles or production singleton.
@MainActor final class SetupUIAcceptanceDriver {
    enum Command {
        case source(String), profiles([String]), folder(URL), trim(Bool), factory(String), appearance(ProvisioningAppearanceSelection?), appearanceExpanded(Bool), themeChoice(ProvisioningThemeChoice), themeRepository(String), layoutExample(ProvisioningLayoutExampleID?)
        case ownerDefaults(Bool), name(String), resources(Int, Int, Int), preview, save, lookup(UUID), inspect, prepareApply
        case grant(Bool, Bool, Bool), submit, search(String), requestCancel, confirmCancel, section(String)
    }
    struct Scope { let action: (Command) -> Void; let snapshot: () -> [String: String] }
    var scopes: [String: Scope] = [:]
    var terminalScreen: ProvisioningTerminalScreen?
    func bind(_ name: String, action: @escaping (Command) -> Void, snapshot: @escaping () -> [String: String]) { scopes[name] = .init(action: action, snapshot: snapshot) }
    func send(_ name: String, _ command: Command) throws { guard let scope = scopes[name] else { throw AcceptanceFailure.check }; scope.action(command) }
    func state(_ name: String, _ key: String) -> String { scopes[name]?.snapshot()[key] ?? "<unbound>" }
}
private struct SetupAcceptanceKey: EnvironmentKey { static let defaultValue: SetupUIAcceptanceDriver? = nil }
extension EnvironmentValues {
    var setupAcceptance: SetupUIAcceptanceDriver? { get { self[SetupAcceptanceKey.self] } set { self[SetupAcceptanceKey.self] = newValue } }
}
enum AcceptanceFailure: Error { case check }

/// In-memory fake, deliberately implementing no process, file, transport or VM
/// backend. Typed replies are fixture data, never an admission capability.
@MainActor final class SetupAcceptanceService: ProvisioningCreationPlanning, ProvisioningWorkflowActing {
    nonisolated let executionEnabled: Bool
    var captures = 0, preparations = 0, submissions = 0, taskReads = 0, terminalAttempts = 0, cancellations = 0
    var holdNext = false, failNext = false
    /// When set, apply review needs only temporary admin access (no Docker or task trust).
    var adminOnlyReview = false
    var lastConsent: ProvisioningApplyConsent?
    var reviewSession: UUID?
    private var waiter: CheckedContinuation<Void, Never>?
    var waiting: Bool { waiter != nil }
    var previews: [UUID: ProvisioningPlanPreview] = [:]
    var creations: [UUID: ProvisioningCreationReview] = [:]
    var sources: [UUID: ProvisioningSetupSource] = [:]
    var saved: [UUID: (GuestConfigurationPatch, VMProfile)] = [:]
    var savedCalls = 0, noneSaves = 0
    var savedConfigurations: [GuestConfigurationPatch] = []
    let task = Data(("# Synthetic UI acceptance task only\n" + String(repeating: "# fixture café ✓\n", count: 520) + "- ansible.builtin.debug: {msg: synthetic}\n").utf8)
    let vmID: UUID
    init(vmID: UUID, enabled: Bool = false) { self.vmID = vmID; executionEnabled = enabled }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func value<T: Decodable>(_ object: [String: Any], as type: T.Type = T.self) throws -> T { try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object)) }
    private func document(_ id: UUID, source: ProvisioningSetupSource, target: UUID?) throws -> [String: Any] {
        let input = Self.hash(try JSONEncoder().encode(source)), engine = String(repeating: "a", count: 64)
        let plan = Self.hash(Data((input + "synthetic-plan").utf8))
        let appearance = source.appearance
        let theme = appearance?.theme.map { ["random", "most-starred"].contains($0) ? "https://github.com/example/omarchy-fixture-theme" : $0 } ?? ""
        let workstation: [String: Any] = ["theme": theme, "layout": appearance?.layoutFile == nil && appearance?.layoutExample == nil ? "" : ".omarchy-manager-layout.lua", "remove_layout": appearance?.removeLayout == true]
        var proposal: [String: Any] = ["schema_version": 1, "id": "synthetic-ui-only", "plan_digest": plan, "input_digest": input, "execution_available": false, "vm": ["name": "Source proposal only", "cpus": 8, "memory_gib": 16, "disk_gib": 256, "lean_developer": source.trimOptionalApps == true], "features": ["profiles": source.profiles ?? source.preset.map { [$0] } ?? [], "features": source.features?.enable.map(\.rawValue) ?? ["cli"], "options": ["workstation": workstation]], "requirements": ["update_policy": "Update Omarchy and system packages before applying setup", "system_update_required": true, "system_restart_required": true, "removals": [], "desktop_restart_required": true], "tasks": [["name": "synthetic", "file": "fixture-task.yml"]]]
        if let id = appearance?.layoutExample, let example = try BundledProvisioning.layoutExamples().first(where: { $0.id == id }) {
            proposal["inputs"] = [["path": ".omarchy-manager-layout.lua", "sha256": example.sourceSHA256, "mode": 384]]
        }
        var fields: [String: Any] = ["id": id.uuidString, "planDigest": plan, "inputDigest": input, "engineDigest": engine, "proposal": try JSONSerialization.data(withJSONObject: proposal, options: [.sortedKeys]).base64EncodedString(), "tasks": [["name": "synthetic", "file": "fixture-task.yml", "sha256": Self.hash(task)]], "restartRequired": true]
        if let target { fields["vmID"] = target.uuidString }
        else { fields["reviewIdentity"] = Self.hash(Data((id.uuidString + input).utf8)) }
        return fields
    }
    private func capture() async throws {
        captures += 1
        if holdNext { holdNext = false; await withCheckedContinuation { waiter = $0 } }
        if failNext { failNext = false; throw ProvisioningReviewFailure.invalid }
    }
    func release() { waiter?.resume(); waiter = nil }
    func prepareCreation(id: UUID, source: ProvisioningSetupSource) async throws -> ProvisioningCreationReview {
        if let old = creations[id] { guard sources[id] == source else { throw ProvisioningReviewFailure.changed }; return old }
        let review: ProvisioningCreationReview = try value(document(id, source: source, target: nil))
        try await capture(); sources[id] = source; creations[id] = review; return review
    }
    func creation(_ id: UUID) async throws -> ProvisioningCreationReview { guard let review = creations[id] else { throw ProvisioningReviewFailure.unavailable }; return review }
    func preview(id: UUID, vmID: UUID, source: ProvisioningSetupSource) async throws -> ProvisioningPlanPreview {
        let preview: ProvisioningPlanPreview = try value(document(id, source: source, target: vmID))
        try await capture(); sources[id] = source; previews[id] = preview; return preview
    }
    func preview(_ id: UUID) async throws -> ProvisioningPlanPreview { guard let preview = previews[id] else { throw ProvisioningReviewFailure.unavailable }; return preview }
    func taskSource(_ id: UUID, name: String, offset: Int) async throws -> ProvisioningTaskSource {
        guard previews[id] != nil, name == "synthetic", (0...task.count).contains(offset) else { throw ProvisioningReviewFailure.invalid }
        taskReads += 1
        return try value(["previewID": id.uuidString, "name": name, "sha256": Self.hash(task), "offset": offset, "total": task.count, "bytes": task.subdata(in: offset..<min(offset + 4096, task.count)).base64EncodedString()])
    }
    func prepareApply(_ id: UUID) async throws -> ProvisioningApplyReview {
        guard executionEnabled else { throw ProvisioningReviewFailure.unavailable }
        guard let preview = previews[id] else { throw ProvisioningReviewFailure.invalid }; preparations += 1
        var fields: [String: Any] = ["previewID": id.uuidString, "vmID": preview.vmID.uuidString, "sessionID": (reviewSession ?? UUID()).uuidString, "planDigest": preview.planDigest, "inputDigest": preview.inputDigest, "dependencyDigest": String(repeating: "b", count: 64), "reviewIdentity": String(repeating: "c", count: 64), "systemUpdateRequired": true, "persistentGrantRequired": true, "dockerRootAccessRequired": !adminOnlyReview]
        if !adminOnlyReview { fields["taskTrustIdentity"] = String(repeating: "d", count: 64) }
        return try value(fields)
    }
    func apply(_ id: UUID, consent: ProvisioningApplyConsent) async throws -> ProvisioningWorkflowSnapshot {
        lastConsent = consent
        let wider = !adminOnlyReview
        guard executionEnabled, previews[id] != nil, consent.reviewIdentity == String(repeating: "c", count: 64), consent.persistentGrantAcknowledged,
              consent.dockerRootAccessAcknowledged == wider, consent.taskTrustIdentity == (wider ? String(repeating: "d", count: 64) : nil) else { throw ProvisioningReviewFailure.consentRequired }
        submissions += 1; return try row(id, stage: "running")
    }
    func save(_ config: GuestConfigurationPatch, consent: ProvisioningCreationConsent?) async throws -> VMProfile {
        savedCalls += 1; savedConfigurations.append(config)
        if consent == nil {
            noneSaves += 1
            var profile = VMProfile(id: UUID(), name: config.name!, memoryMiB: config.memoryMiB!, cpus: config.cpus!, diskGiB: config.diskGiB, clipboardEnabled: config.clipboard!, immersiveMode: config.immersive)
            profile.factory = .official; return profile
        }
        guard let consent, consent.acknowledged, let review = creations[consent.reviewID], consent.reviewIdentity == review.reviewIdentity else { throw ProvisioningReviewFailure.consentRequired }
        if let prior = saved[review.id] { guard prior.0 == config else { throw ProvisioningReviewFailure.conflictingConsent }; return prior.1 }
        var profile = VMProfile(id: UUID(), name: config.name!, memoryMiB: config.memoryMiB!, cpus: config.cpus!, diskGiB: config.diskGiB, clipboardEnabled: config.clipboard!, immersiveMode: config.immersive)
        profile.factory = .official
        profile.developerSetup = try value(["reviewID": review.id.uuidString, "vmID": profile.id.uuidString, "reviewIdentity": review.reviewIdentity, "planDigest": review.planDigest, "inputDigest": review.inputDigest, "engineDigest": review.engineDigest, "configurationDigest": Self.hash(try JSONEncoder().encode(config))])
        saved[review.id] = (config, profile)
        var fields = try document(review.id, source: sources[review.id]!, target: profile.id)
        fields["proposal"] = review.proposal.base64EncodedString(); previews[review.id] = try value(fields)
        return profile
    }
    func row(_ id: UUID, stage: String, cleanupRequired: Bool = false) throws -> ProvisioningWorkflowSnapshot {
        try value(["id": id.uuidString, "vmID": vmID.uuidString, "originalSessionID": UUID().uuidString, "sequence": 1, "stage": stage, "cleanupRequired": cleanupRequired, "applyJobID": id.uuidString])
    }
    /// Finishing actions submitted with an acknowledged consent, in order.
    var actionSubmissions: [ProvisioningWorkflowAction] = []
    func prepareAction(_ workflowID: UUID, action: ProvisioningWorkflowAction, reviewID: UUID) async throws -> ProvisioningWorkflowActionReview {
        guard executionEnabled, action != .recover, let preview = previews[workflowID] else { throw ProvisioningReviewFailure.unavailable }
        return try value(["id": reviewID.uuidString, "workflowID": workflowID.uuidString, "vmID": vmID.uuidString, "sessionID": UUID().uuidString,
                          "jobID": UUID().uuidString, "action": action.rawValue, "workflowSequence": 2, "planDigest": preview.planDigest,
                          "inputDigest": preview.inputDigest, "dependencyDigest": String(repeating: "b", count: 64), "reviewIdentity": String(repeating: "e", count: 64)])
    }
    func performAction(_ workflowID: UUID, consent: ProvisioningWorkflowActionConsent) async throws -> ProvisioningWorkflowSnapshot {
        guard executionEnabled, consent.acknowledged, consent.reviewIdentity == String(repeating: "e", count: 64) else { throw ProvisioningReviewFailure.consentRequired }
        actionSubmissions.append(consent.action)
        return try row(workflowID, stage: consent.action == .restart ? "restarting" : "checking")
    }
    func statuses() async -> [ProvisioningWorkflowSnapshot] { [] }
    func status(_ id: UUID) async -> ProvisioningWorkflowSnapshot? { nil }
    func jobStatus(_ id: UUID) async -> ProvisioningJobSnapshot? { nil }
    /// Synthetic saved output; the harness never reads the support directory.
    var savedLog: Data?
    func setupLog(vmID: UUID) async -> Data? { vmID == self.vmID ? savedLog : nil }
    func cancel(_ id: UUID) async throws { cancellations += 1 }
    func attachTerminal(_ id: UUID) async throws -> ProvisioningTerminalAttachment { terminalAttempts += 1; throw ProvisioningReviewFailure.unavailable }
}
#endif
