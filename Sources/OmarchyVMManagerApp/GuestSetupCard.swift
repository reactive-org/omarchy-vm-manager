import OmarchyVMManagerCore
import SwiftUI

/// Which setup sheet the guest's Home tab is showing.
enum SetupSheet: String, Identifiable {
    case change, output
    var id: String { rawValue }
}

/// The setup card's state, read only from recorded workflow stage, job state and
/// the in-memory approval from New VM, the same rule as the first-run tracker.
struct SetupCardState: Equatable {
    enum Kind: Equatable { case none, configured, running, needsYou, cleanup, failed, succeeded, finished }
    var kind: Kind
    var run = ""
    var note = ""
    /// Index into Install, Restart, Check while a run is live.
    var progress: Int?

    static func make(_ snapshot: VMSnapshot, workflows: [ProvisioningWorkflowSnapshot], jobs: [UUID: ProvisioningJobSnapshot],
                     autoSetup: AutoSetupState?, checkOnly: Set<UUID> = []) -> SetupCardState {
        let rows = workflows.filter { $0.vmID == snapshot.id }
        guard !rows.isEmpty else {
            if snapshot.profile.developerSetup == nil { return .init(kind: .none) }
            return .init(kind: .configured, run: "Not run yet", note: "Setup runs after the guest starts and SSH is ready.")
        }
        guard let row = SetupAttention.currentRun(snapshot.id, workflows: workflows) else {
            return .init(kind: .finished, run: "Finished", note: "View output shows the most recent run.")
        }
        // Whether the owner is needed comes only from the shared Core attention state.
        let attention = SetupAttention.make(snapshot, workflows: workflows, jobs: jobs, auto: SetupAutoApproval(autoSetup))?.reason
        switch attention {
        case .cleanup?:
            if snapshot.sessionID == nil {
                // Issue #24: recovery needs the original session, so only a release is possible.
                return .init(kind: .cleanup, run: "Interrupted · cleanup needs review",
                             note: "The run stopped before temporary admin access was confirmed removed, and the guest has stopped, so it can’t be verified. Review cleanup to release the hold; you then remove any leftover admin access inside the guest.")
            }
            return .init(kind: .cleanup, run: "Interrupted · cleanup needs review",
                         note: "The run stopped before temporary admin access was confirmed removed. Recovery removes it; nothing is re-installed and the guest isn’t restarted.")
        case .sudoPrompt?:
            return .init(kind: .needsYou, run: "Waiting for authorization",
                         note: ProvisioningSudoGrant.promptNote + " Open View output to respond.", progress: 0)
        case .restartReview?:
            return .init(kind: .needsYou, run: "Restart needs your review", note: "Software is installed. Review the restart that finishes setup.")
        case .checkReview?:
            return .init(kind: .needsYou, run: "Check needs your review", note: "The guest restarted. Review the configuration check that finishes setup.")
        case .review?:
            return .init(kind: .needsYou, run: "Waiting for your review",
                         note: autoSetup?.blockedReason ?? "Review what this setup changes and approve it to start.")
        case nil:
            break
        }
        if checkOnly.contains(row.id), row.stage == .running {
            return .init(kind: .running, run: "Checking", note: "Checking the configuration the last run applied. It installs nothing.", progress: 2)
        }
        let approvedWhen = autoSetup?.plan?.origin == .change ? "You approved the whole run in Change setup." : "You approved it when you created this VM."
        switch row.stage {
        case .waitingForSSH:
            return .init(kind: .running, run: "Preparing", note: "Preparing the setup review in the guest.", progress: 0)
        case .readyForReview:
            return .init(kind: .running, run: "Starting", note: "Starting setup. " + approvedWhen, progress: 0)
        case .running:
            return .init(kind: .running, run: "Installing", note: "You can use the guest while this runs. It restarts once near the end.", progress: 0)
        case .restartRequired, .readyForCheck, .waitingForRebind:
            // No attention here means the New VM approval is finishing setup automatically.
            return .init(kind: .running, run: row.stage == .restartRequired ? "Restarting" : "Checking",
                         note: "Finishing automatically. " + approvedWhen, progress: row.stage == .restartRequired ? 1 : 2)
        case .waitingForExit, .restarting:
            return .init(kind: .running, run: "Restarting", note: "Restarting the guest to finish setup.", progress: 1)
        case .checking:
            return .init(kind: .running, run: "Checking", note: "Checking the configuration after the restart.", progress: 2)
        case .succeeded, .checked:
            return .init(kind: .succeeded, run: "Succeeded",
                         note: row.stage == .checked ? "Updated Omarchy, applied your selections, restarted and checked." : "Updated Omarchy and applied your selections.")
        case .failed, .cancelled, .interrupted, .cleanupRequired:
            return .init(kind: .failed, run: row.stage == .cancelled ? "Cancelled" : row.stage == .interrupted ? "Interrupted" : "Failed", note: FirstRunProgress.failureNote(row, job: jobs[row.id]))
        }
    }
}

/// Setup on the guest's Home tab, replacing the Setup tab: what is configured, how
/// the last run went, and the one action that matters now. Change setup and View
/// output open as sheets.
struct GuestSetupCard: View {
    let state: SetupCardState
    let software: String?
    let desktop: String?
    let open: (SetupSheet) -> Void

    private var tint: Color {
        switch state.kind {
        case .needsYou, .cleanup, .failed: Theme.amber
        case .running: Theme.lavender
        default: Theme.green
        }
    }
    private var emphasised: Bool { [.needsYou, .cleanup, .running].contains(state.kind) }

    var body: some View {
        GroupedPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("setup").font(Theme.mono(13, weight: .medium)).foregroundStyle(tint).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    actions
                }.padding(.bottom, 8)
                if state.kind == .none {
                    Text("Install developer tools, a desktop layout and a theme. Setup updates Omarchy first, then restarts and checks the guest; you review it once before it runs.")
                        .font(Theme.sans(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                } else {
                    if let software { row("software", software) }
                    if let desktop { row("desktop", desktop) }
                    row(state.kind == .running ? "running" : "last run", state.run, tint: state.kind == .succeeded ? Theme.green : emphasised || state.kind == .failed ? tint : nil, note: state.note, progress: state.progress)
                }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
        }
        .overlay {
            if emphasised { RoundedRectangle(cornerRadius: Theme.paneRadius).strokeBorder(tint.opacity(0.8)) }
        }
        .accessibilityIdentifier("guest.setup-card")
    }

    @ViewBuilder private var actions: some View {
        switch state.kind {
        case .none:
            Button("Set up…") { open(.change) }.buttonStyle(.primaryAction)
        case .running:
            Button("View output") { open(.output) }
        case .needsYou:
            if state.run == "Waiting for authorization" { Button("View output") { open(.output) }.buttonStyle(.primaryAction) }
            else { Button("Review…") { open(.change) }.buttonStyle(.primaryAction) }
        case .cleanup:
            Button("View output") { open(.output) }
            Button("Review cleanup…") { open(.change) }.buttonStyle(.primaryAction)
        case .configured, .failed, .succeeded, .finished:
            if state.kind != .configured { Button("View output") { open(.output) } }
            Button("Change setup…") { open(.change) }
        }
    }

    private func row(_ key: String, _ value: String, tint: Color? = nil, note: String? = nil, progress: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).font(Theme.mono(14)).foregroundStyle(Theme.lavender).frame(width: 88, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(Theme.mono(14)).foregroundStyle(tint ?? Theme.text)
                if let progress { SetupStepStrip(states: SetupSteps.live(progress)).frame(maxWidth: 420) }
                if let note { Text(note).font(Theme.sans(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// Chrome for the View output sheet around the shared setup view.
struct SetupSheetFrame<Content: View>: View {
    let title: String
    let subtitle: String
    /// The run's status, shown on View output beside the title.
    var status: SetupCardState? = nil
    let close: () -> Void
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(title).font(Theme.sans(20, weight: .semibold))
                        if let status, !status.run.isEmpty {
                            HStack(spacing: 6) {
                                Rectangle().fill(statusTint(status)).frame(width: 7, height: 7)
                                Text(status.run).font(Theme.sans(13)).foregroundStyle(statusTint(status))
                            }
                        }
                    }
                    Text(subtitle).font(Theme.note).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                if let status, status.kind == .running || status.kind == .succeeded {
                    SetupStepStrip(states: SetupSteps.live(status.kind == .succeeded ? 3 : status.progress ?? 0)).frame(width: 340)
                }
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            ScrollView { content.padding(20) }
        }
        .frame(minWidth: 820, idealWidth: 920, minHeight: 640, idealHeight: 780)
        .background(Theme.pane)
        .font(Theme.body).buttonStyle(.quietAction).toggleStyle(SpecSwitchToggleStyle())
    }
    private func statusTint(_ status: SetupCardState) -> Color {
        switch status.kind {
        case .succeeded: Theme.green
        case .running: Theme.lavender
        case .needsYou, .cleanup, .failed: Theme.amber
        default: .secondary
        }
    }
}

/// Loads the configured software and desktop from the VM's frozen setup receipt
/// so the card can show them without opening a sheet.
struct GuestSetupCardHost: View {
    @ObservedObject var model: AppModel
    let snapshot: VMSnapshot
    let open: (SetupSheet) -> Void
    @State private var software: String?
    @State private var desktop: String?
    var body: some View {
        GuestSetupCard(state: SetupCardState.make(snapshot, workflows: model.setupWorkflows, jobs: model.setupJobs, autoSetup: model.autoSetup[snapshot.id], checkOnly: model.checkOnlyRuns),
                       software: software, desktop: desktop, open: open)
            .task(id: snapshot.profile.developerSetup?.reviewID) {
                software = nil; desktop = nil
                guard let receipt = snapshot.profile.developerSetup, let service = model.setupService as? any ProvisioningReviewing,
                      let preview = try? await service.preview(receipt.reviewID) else { return }
                let names = ProvisioningReviewedProfilesView.names(preview.proposal)
                software = names.isEmpty ? nil : names.joined(separator: " + ")
                let look = ProvisioningAppearanceSummary(proposal: preview.proposal)
                let layout = look.layoutExample?.title ?? (look.layoutIncluded ? "Custom layout" : look.layoutRemoved ? "Omarchy default layout" : "Omarchy default layout")
                let theme = look.theme.map { $0.hasPrefix("https://github.com/") ? String($0.dropFirst(19)) + " theme" : $0 == "random" ? "Random theme" : $0 == "most-starred" ? "Most-starred theme" : $0 } ?? "Omarchy default theme"
                desktop = layout + (look.layoutAdds.isEmpty ? "" : " (adds " + look.layoutAdds.joined(separator: ", ") + ")") + " · " + theme
            }
    }
}
