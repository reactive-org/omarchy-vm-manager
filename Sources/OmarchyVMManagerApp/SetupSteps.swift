import OmarchyVMManagerCore
import SwiftUI

/// One run's four steps, drawn the same way on the guest's setup card, the first-run
/// tracker's sheets and Change setup, so they always tell the same story.
enum SetupStep: Int, CaseIterable {
    case approve, install, restart, check
    var title: String { ["Approve", "Install", "Restart", "Check"][rawValue] }
}

enum SetupStepState: Equatable {
    case todo, current, needsYou, done, missed
}

enum SetupSteps {
    /// Only recorded workflow and job state, plus the in-memory approval, decide a step.
    static func states(_ row: ProvisioningWorkflowSnapshot?, job: ProvisioningJobSnapshot?, auto: AutoSetupState?) -> [SetupStepState] {
        guard let row else {
            if case .armed? = auto { return [.done, .todo, .todo, .todo] }
            if auto == .applying { return [.done, .current, .todo, .todo] }
            return [.todo, .todo, .todo, .todo]
        }
        let approved = SetupAutoApproval(auto).approved && auto?.plan?.previewID == row.id
        let following: Bool = { if case .following(_, let id, _)? = auto { return id == row.id }; return false }()
        switch row.stage {
        case .waitingForSSH, .readyForReview:
            return approved ? [.done, .current, .todo, .todo] : [row.stage == .readyForReview ? .needsYou : .current, .todo, .todo, .todo]
        case .running:
            return [.done, job?.state == .awaitingAuthorization ? .needsYou : .current, .todo, .todo]
        case .restartRequired:
            return [.done, .done, following ? .current : .needsYou, .todo]
        case .waitingForExit, .restarting:
            return [.done, .done, .current, .todo]
        case .waitingForRebind, .readyForCheck:
            return [.done, .done, .done, following ? .current : .needsYou]
        case .checking:
            return [.done, .done, .done, .current]
        case .succeeded, .checked:
            return [.done, .done, .done, .done]
        case .cleanupRequired:
            return [.done, .needsYou, .todo, .todo]
        case .failed, .cancelled, .interrupted:
            if row.applyJobID == nil { return [.missed, .todo, .todo, .todo] }
            if row.newSessionID != nil { return [.done, .done, .done, .missed] }
            if row.restartID != nil { return [.done, .done, .missed, .todo] }
            return [.done, .missed, .todo, .todo]
        }
    }
}

extension SetupSteps {
    /// The strip for a live run's Install (0), Restart (1) or Check (2) index; approval is done.
    static func live(_ progress: Int) -> [SetupStepState] {
        [.done] + (0..<3).map { $0 < progress ? .done : $0 == progress ? .current : .todo }
    }
}

struct SetupStepStrip: View {
    let states: [SetupStepState]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(SetupStep.allCases, id: \.self) { step in
                let state = step.rawValue < states.count ? states[step.rawValue] : .todo
                VStack(alignment: .leading, spacing: 5) {
                    Group {
                        if state == .missed {
                            RoundedRectangle(cornerRadius: 1).strokeBorder(Theme.amber, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        } else {
                            RoundedRectangle(cornerRadius: 1).fill(fill(state))
                        }
                    }.frame(height: 3)
                    Text(step.title + (state == .missed ? " · didn’t run" : "")).font(Theme.sans(11)).foregroundStyle(label(state))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SetupStep.allCases.map { step in
            let state = step.rawValue < states.count ? states[step.rawValue] : .todo
            let word = switch state { case .done: "done"; case .current: "in progress"; case .needsYou: "needs you"; case .missed: "didn’t run"; case .todo: "not started" }
            return step.title + " " + word
        }.joined(separator: ", "))
    }
    private func fill(_ state: SetupStepState) -> Color {
        switch state { case .done: Theme.green; case .current: Theme.lavender; case .needsYou, .missed: Theme.amber; case .todo: Theme.quietFrame }
    }
    private func label(_ state: SetupStepState) -> Color {
        switch state { case .done: Theme.text.opacity(0.85); case .current: Theme.lavender; case .needsYou, .missed: Theme.amber; case .todo: .secondary }
    }
}

/// Where a guest's setup run stands, shared by Change setup and the Home run panel.
enum SetupRunPhase: Equatable {
    case loading, edit, starting
    case pending(ProvisioningWorkflowSnapshot?)
    case live(ProvisioningWorkflowSnapshot)
    case cleanup(ProvisioningWorkflowSnapshot)
}

extension SetupRunPhase {
    /// A run under way: started, or approved and about to start. Nil when nothing is
    /// running; a cleanup hold is reported separately.
    static func active(_ rows: [ProvisioningWorkflowSnapshot], auto: AutoSetupState?, checkOnly: Set<UUID> = []) -> SetupRunPhase? {
        if let held = rows.first(where: { $0.cleanupRequired && !$0.canCancel }) { return .cleanup(held) }
        let approvedID = auto?.isActive == true ? auto?.plan?.previewID : nil
        let preparing: [ProvisioningWorkflowStage] = [.waitingForSSH, .readyForReview]
        if let live = rows.first(where: { $0.stage.inProgress && (!preparing.contains($0.stage) || $0.id == approvedID || checkOnly.contains($0.id)) }) { return .live(live) }
        if auto?.isActive == true { return .starting }
        return nil
    }
}

/// One sentence and the step strip for a run, the same on the sheet and on Home.
struct SetupRunStatus: Equatable {
    enum Tint: Equatable { case quiet, good, working, attention }
    var label: String
    var title: String
    var note: String
    var tint: Tint
    var steps: [SetupStepState]
    var color: Color {
        switch tint { case .good: Theme.green; case .working: Theme.lavender; case .attention: Theme.amber; case .quiet: Theme.label }
    }

    /// The one sentence for each state, from recorded state only.
    static func make(_ phase: SetupRunPhase, lastRun: ProvisioningWorkflowSnapshot?, latestPlanExists: Bool, running: Bool,
                     job: ProvisioningJobSnapshot?, auto: AutoSetupState?, checkOnly: Set<UUID> = []) -> SetupRunStatus {
        if case .live(let row) = phase, row.stage.inProgress, checkOnly.contains(row.id) {
            return .init(label: "this run", title: "Checking", note: "A read-only check of the last run’s choices, with no admin access. It installs nothing; you can keep using the guest.",
                         tint: .working, steps: [.done, .done, .done, .current])
        }
        switch phase {
        case .loading:
            return .init(label: "setup", title: "Loading…", note: "", tint: .quiet, steps: SetupSteps.states(nil, job: nil, auto: nil))
        case .starting:
            let title = auto == .applying ? "Preparing setup" : running ? "Waiting for the guest" : "Starting the guest"
            return .init(label: "this run", title: title, note: "Setup runs once the guest is reachable over SSH, then restarts it and checks the configuration. You can close this sheet.",
                         tint: .working, steps: SetupSteps.states(nil, job: nil, auto: auto))
        case .pending(let row):
            return .init(label: "waiting for you", title: "This run is ready to approve",
                         note: "It hasn’t changed anything in the guest yet. Approve it to run it, including its restart and check, or discard it to change the choices first.",
                         tint: .attention, steps: row.map { SetupSteps.states($0, job: nil, auto: nil) } ?? [.needsYou, .todo, .todo, .todo])
        case .cleanup(let row):
            let note = running
                ? "Setup couldn’t confirm it removed passwordless sudo. Recover checks this guest and removes it; nothing is re-installed and the guest isn’t restarted."
                : "Setup couldn’t confirm it removed passwordless sudo, and the guest has stopped, so it can’t be checked. Release the hold to carry on, then remove any leftover admin access inside the guest."
            return .init(label: "cleanup", title: "Temporary admin access may still be on", note: note, tint: .attention, steps: SetupSteps.states(row, job: job, auto: auto))
        case .live(let row):
            let steps = SetupSteps.states(row, job: job, auto: auto)
            let following = steps.contains(.current)
            switch row.stage {
            case .waitingForSSH, .readyForReview:
                return .init(label: "this run", title: "Preparing setup", note: "Connecting to the guest and preparing the approved plan.", tint: .working, steps: steps)
            case .running where job?.state == .awaitingAuthorization:
                return .init(label: "waiting for you", title: "Omarchy is asking for sudo", note: ProvisioningSudoGrant.promptNote + " Answer it in the live terminal.", tint: .attention, steps: steps)
            case .running:
                return .init(label: "this run", title: "Installing", note: "Updating Omarchy, then applying your choices. You can use the guest while this runs; it restarts once near the end. You can leave this page; setup keeps going.", tint: .working, steps: steps)
            case .restartRequired where !following:
                return .init(label: "waiting for you", title: "Software installed. Restart to finish", note: "Setup restarts the guest, waits for it to come back, then runs a read-only check that the configuration applied. Nothing else is installed.", tint: .attention, steps: steps)
            case .restartRequired, .waitingForExit, .restarting:
                return .init(label: "this run", title: "Restarting", note: "Restarting the guest to finish setup. The configuration check follows.", tint: .working, steps: steps)
            case .waitingForRebind, .readyForCheck:
                if following { return .init(label: "this run", title: "Checking", note: "Waiting for the restarted guest, then checking the configuration.", tint: .working, steps: steps) }
                return .init(label: "waiting for you", title: "The guest restarted. Check to finish", note: "A read-only check that the configuration applied. It installs nothing.", tint: .attention, steps: steps)
            default:
                return .init(label: "this run", title: "Checking", note: "A read-only check that the configuration applied after the restart.", tint: .working, steps: steps)
            }
        case .edit:
            guard let row = lastRun else {
                if latestPlanExists { return .init(label: "setup", title: "Not run yet", note: "This guest has a saved setup plan that hasn’t run. Review the choices below, then run it.", tint: .quiet, steps: SetupSteps.states(nil, job: nil, auto: nil)) }
                return .init(label: "setup", title: "Not set up yet", note: "Choose software and a desktop layout. Setup updates Omarchy first, then applies them, restarts the guest once and checks the configuration.", tint: .quiet, steps: SetupSteps.states(nil, job: nil, auto: nil))
            }
            let steps = SetupSteps.states(row, job: nil, auto: nil)
            let released = row.cleanupRelease != nil ? " Its cleanup hold was released without verification; the guest may still allow passwordless sudo." : ""
            switch row.stage {
            case .checked: return .init(label: "last run", title: "Finished and checked", note: "Updated Omarchy, applied these choices, restarted and checked." + released, tint: .good, steps: steps)
            case .succeeded: return .init(label: "last run", title: "Finished", note: "Updated Omarchy and applied these choices." + released, tint: .good, steps: steps)
            case .interrupted where row.newSessionID != nil || row.restartID != nil:
                return .init(label: "last run", title: "Applied, but the final check didn’t run", note: "Setup installed your software and restarted the guest, then stopped before the configuration check. The guest is usable as it is; run setup again to finish with a check." + released, tint: .attention, steps: steps)
            case .interrupted where row.applyJobID == nil, .cancelled where row.applyJobID == nil:
                return .init(label: "last plan", title: "Prepared, but never approved", note: "Nothing ran. Review the choices below and run setup when you’re ready." + released, tint: .quiet, steps: steps)
            case .interrupted:
                return .init(label: "last run", title: "Interrupted", note: "Setup stopped before it finished because the manager quit. Run setup again to finish it." + released, tint: .attention, steps: steps)
            case .cancelled: return .init(label: "last run", title: "Cancelled", note: "Setup was cancelled. Run it again when you’re ready." + released, tint: .attention, steps: steps)
            default: return .init(label: "last run", title: SetupRunPresentation.outcome(row), note: "Check View output for what happened, then run setup again." + released, tint: .attention, steps: steps)
            }
        }
    }
}

/// Facts Change setup reads from a frozen proposal before anything is prepared.
enum SetupProposalFacts {
    /// dev-vm's own flag for a plan that gives the owner Docker without sudo.
    static func needsDocker(_ proposal: Data) -> Bool {
        guard let document = try? JSONSerialization.jsonObject(with: proposal) as? [String: Any],
              let requirements = document["requirements"] as? [String: Any] else { return false }
        return requirements["desktop_restart_required"] as? Bool == true
    }
    static func software(_ proposal: Data) -> String {
        let names = ProvisioningReviewedProfilesView.names(proposal)
        return names.isEmpty ? "The configuration’s own software" : names.joined(separator: ", ")
    }
    static func desktop(_ proposal: Data) -> String {
        let look = ProvisioningAppearanceSummary(proposal: proposal)
        let layout = look.layoutExample?.title ?? (look.layoutIncluded ? "Custom layout" : "Omarchy default layout")
        let theme = look.theme.map { $0.hasPrefix("https://github.com/") ? String($0.dropFirst(19)) + " theme" : $0 == "random" ? "Random theme" : $0 == "most-starred" ? "Most-starred theme" : $0 }
        return [layout, theme].compactMap { $0 }.joined(separator: " · ")
    }
    /// The last plan's choices as an editable draft. A custom layout file or custom
    /// tasks came from a local folder, which has to be chosen again to change them.
    static func draft(_ preview: ProvisioningPlanPreview) -> NewVMSetupDraft {
        var draft = NewVMSetupDraft()
        let look = ProvisioningAppearanceSummary(proposal: preview.proposal)
        let local = !preview.tasks.isEmpty || (look.layoutIncluded && look.layoutExample == nil)
        draft.source = local ? "local" : "bundled"
        let ids = (try? JSONSerialization.jsonObject(with: preview.proposal) as? [String: Any]).flatMap { ($0["features"] as? [String: Any])?["profiles"] as? [String] } ?? []
        draft.profiles = Set(ids.map { $0.hasPrefix("builtin.") ? String($0.dropFirst(8)) : $0 })
        draft.trimOptionalApps = ProvisioningTrim.isRequested(in: preview.proposal)
        draft.permanentSudoGrant = !ProvisioningSudoGrant.isTimed(in: preview.proposal)
        var appearance = ProvisioningAppearanceDraft()
        switch look.theme {
        case "random"?: appearance.themeChoice = .random
        case "most-starred"?: appearance.themeChoice = .popular
        case let value?: appearance.themeChoice = .repository; appearance.theme = value
        case nil: break
        }
        if let example = look.layoutExample { appearance.layoutMode = "example"; appearance.layoutExample = example.id }
        else if look.layoutRemoved { appearance.layoutMode = "remove" }
        draft.appearance = appearance
        return draft
    }
}
