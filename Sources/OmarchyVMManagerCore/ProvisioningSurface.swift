import Foundation

/// A single service boundary used by UI and CLI. No VM creation or job submission
/// is implied by viewing a job. Product execution remains independently gated.
public protocol ProvisioningObserving: Sendable {
    var executionEnabled: Bool { get }
    func statuses() async -> [ProvisioningWorkflowSnapshot]
    func status(_ id: UUID) async -> ProvisioningWorkflowSnapshot?
    func jobStatus(_ id: UUID) async -> ProvisioningJobSnapshot?
    func cancel(_ id: UUID) async throws
    func attachTerminal(_ id: UUID) async throws -> ProvisioningTerminalAttachment
}
extension ProvisioningService: ProvisioningObserving {}

public enum ProvisioningSetupPhase: String, CaseIterable, Sendable { case review = "Review", connect = "Connect", authorize = "Authorize", configure = "Configure", cleanup = "Cleanup" }
extension ProvisioningWorkflowSnapshot {
    public var title: String {
        switch stage {
        case .waitingForSSH: "Connecting to guest"
        case .readyForReview: "Ready for review"
        case .running: "Configuring features"
        case .checking: "Checking configuration"
        case .restartRequired: "Restart required"
        case .waitingForExit, .restarting: "Restarting guest"
        case .waitingForRebind, .readyForCheck: "Ready for check review"
        case .succeeded: "Setup complete"
        case .checked: "Check complete"
        case .cancelled: "Setup cancelled"
        case .interrupted: "Setup interrupted"
        case .cleanupRequired: "Cleanup required"
        case .failed: "Setup failed"
        }
    }
    // Workflow stages do not establish an authorization grant or cleanup proof.
    // Prompt visibility and input availability come from typed terminal metadata.
    public var canCancel: Bool { [.waitingForSSH, .readyForReview, .running, .checking, .waitingForExit, .restarting, .waitingForRebind, .readyForCheck, .restartRequired].contains(stage) }
}

public enum ProvisioningSetupCLI: Sendable, Equatable {
    case capabilities, list, status(UUID), cancel(UUID), attach(UUID, interactive: Bool), events(UUID)
    case plan(URL), preset(String), presets
    case createPreview(UUID, UUID, ProvisioningSetupSource), preview(UUID), taskSource(UUID, String, Int)
    case prepareApply(UUID), apply(UUID, ProvisioningApplyConsent)
    public static func parse(_ args: [String]) throws -> Self? {
        guard args.first == "setup", args.count >= 2, args[1] != "tools" else { return nil }
        if ["check", "recover"].contains(args[1]) {
            throw commandFailure("setup-execution-disabled", "Setup execution is disabled pending guest acceptance. Use setup plan, status or attach for an existing admitted job.")
        }
        if ["preview", "prepare-apply", "apply", "task-source"].contains(args[1]) {
            guard args.count >= 3, let id = UUID(uuidString: args[2]) else { throw commandFailure("usage", "Use an exact UUID for setup review commands.") }
            if args.count == 3, args[1] == "preview" { return .preview(id) }
            if args.count == 3, args[1] == "prepare-apply" { return .prepareApply(id) }
            if args[1] == "task-source", args.count == 4 || args.count == 6 {
                let offset: Int
                if args.count == 6 { guard args[4] == "--offset", let n = Int(args[5]), (0...32 * 1024 * 1024).contains(n) else { throw commandFailure("usage", "Invalid source offset.") }; offset = n }
                else { offset = 0 }
                guard !args[3].isEmpty, args[3].utf8.count <= 64 else { throw commandFailure("usage", "Invalid task name.") }
                return .taskSource(id, args[3], offset)
            }
            var values: [String: String] = [:], flags = Set<String>(), index = 3
            let options: Set<String> = args[1] == "preview" ? ["--from", "--preset", "--preview-id"] : ["--review", "--trust-tasks"]
            while index < args.count {
                let option = args[index]; index += 1
                if args[1] == "apply", ["--ack-sudo", "--ack-docker-root"].contains(option), flags.insert(option).inserted { continue }
                guard options.contains(option), values[option] == nil, index < args.count, !args[index].hasPrefix("--") else { throw commandFailure("usage", "Unknown, duplicate or incomplete review option.") }
                values[option] = args[index]; index += 1
            }
            if args[1] == "preview", let token = values["--preview-id"], let previewID = UUID(uuidString: token),
               (values["--from"] == nil) != (values["--preset"] == nil) {
                let source = values["--from"].map { ProvisioningSetupSource(directory: $0) } ?? .init(preset: values["--preset"]!)
                do { try source.validate() } catch { throw commandFailure("usage", "Choose a bundled preset or an absolute setup folder.") }
                return .createPreview(id, previewID, source)
            }
            if args[1] == "apply", let review = values["--review"], provisioningDigest(review), values["--trust-tasks"].map(provisioningDigest) ?? true {
                return .apply(id, .init(reviewIdentity: review, taskTrustIdentity: values["--trust-tasks"], persistentGrantAcknowledged: flags.contains("--ack-sudo"), dockerRootAccessAcknowledged: flags.contains("--ack-docker-root")))
            }
            throw commandFailure("usage", "Use preview VM_UUID --from /folder|--preset NAME --preview-id UUID; preview UUID; prepare-apply UUID; apply UUID --review DIGEST --ack-sudo [--trust-tasks DIGEST] [--ack-docker-root]; task-source UUID NAME [--offset N].")
        }
        if args == ["setup", "capabilities"] { return .capabilities }
        if args == ["setup", "list"] { return .list }
        if args == ["setup", "presets"] { return .presets }
        if args.count == 4, args[1] == "plan", args[2] == "--preset", BundledProvisioning.presets.contains(args[3]) { return .preset(args[3]) }
        if args.count == 4, args[1] == "plan", args[2] == "--from", args[3].hasPrefix("/") { return .plan(URL(fileURLWithPath: args[3])) }
        if args.count == 3 || args.count == 4, let id = UUID(uuidString: args[2]) {
            switch args[1] {
            case "status" where args.count == 3: return .status(id)
            case "cancel" where args.count == 3: return .cancel(id)
            case "attach" where args.count == 3: return .attach(id, interactive: false)
            case "attach" where args.count == 4 && args[3] == "--input": return .attach(id, interactive: true)
            case "status" where args.count == 4 && args[3] == "--events": return .events(id)
            default: break
            }
        }
        throw commandFailure("usage", "Use setup capabilities|list|presets|plan --from /folder|status UUID [--events]|cancel UUID|attach UUID [--input].")
    }
}
