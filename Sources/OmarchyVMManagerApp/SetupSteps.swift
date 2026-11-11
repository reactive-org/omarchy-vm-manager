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
