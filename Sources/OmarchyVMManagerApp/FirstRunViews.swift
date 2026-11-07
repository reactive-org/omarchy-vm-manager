import OmarchyProvisioningTerminalUI
import OmarchyVMManagerCore
import SwiftUI

/// First-run progress for a guest created with developer setup. Every step comes
/// from observed guest, SSH or workflow state; nothing is inferred from time and
/// no step is marked complete before its state is seen. Approval stays on the
/// Setup page, which owns the exact consent review.
struct FirstRunProgress: Equatable {
    enum Step: Int, CaseIterable {
        case created, starting, firstBoot, connecting, approve, installing, restart, ready
        var title: String {
            switch self {
            case .created: "Created"
            case .starting: "Starting"
            case .firstBoot: "First boot"
            case .connecting: "Connecting"
            case .approve: "Approve"
            case .installing: "Installing"
            case .restart: "Restart"
            case .ready: "Ready"
            }
        }
    }
    enum Tone: Equatable { case idle, working, needsYou, problem }

    var step: Step
    var tone: Tone
    var note: String
    /// Title of a button that opens the Setup page, when that is the next move.
    var setupAction: String?
    /// The workflow whose output Home shows, its attachment key, and whether the job is
    /// still live. Ended runs keep showing output that Home already received.
    var terminal: (workflowID: UUID, key: String, live: Bool)?
    /// Approved in New VM (Create, Launch & Set Up): no Approve step is shown.
    var approvedAtCreation = false

    var steps: [Step] { approvedAtCreation ? Step.allCases.filter { $0 != .approve } : Step.allCases }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.step == rhs.step && lhs.tone == rhs.tone && lhs.note == rhs.note && lhs.setupAction == rhs.setupAction && lhs.terminal?.key == rhs.terminal?.key && lhs.terminal?.live == rhs.terminal?.live
            && lhs.approvedAtCreation == rhs.approvedAtCreation
    }

    /// Returns nil for guests without developer setup, and once any setup run has succeeded.
    static func make(_ snapshot: VMSnapshot, workflows: [ProvisioningWorkflowSnapshot], jobs: [UUID: ProvisioningJobSnapshot],
                     autoSetup: AutoSetupState? = nil) -> FirstRunProgress? {
        guard snapshot.profile.developerSetup != nil else { return nil }
        let rows = workflows.filter { $0.vmID == snapshot.id }
        if rows.contains(where: { [.succeeded, .checked].contains($0.stage) }) { return nil }
        var value: FirstRunProgress
        if rows.isEmpty { value = guestProgress(snapshot) }
        // UUID order is not chronology: only a live or cleanup-bound run is "current".
        else if let row = rows.first(where: \.cleanupRequired) ?? rows.first(where: \.canCancel) ?? (rows.count == 1 ? rows.first : nil) {
            value = workflowProgress(row, job: jobs[row.id])
        } else {
            return .init(step: .installing, tone: .problem, note: "Earlier setup runs did not finish. Review their results before trying again.", setupAction: "Open setup…")
        }
        guard let autoSetup else { return value }
        if let reason = autoSetup.blockedReason {
            // The one-time approval no longer applies; the manual review takes over.
            if value.step <= .approve, value.tone != .problem { value = .init(step: .approve, tone: .needsYou, note: reason, setupAction: "Review setup…") }
            else if value.step == .restart, value.tone == .needsYou { value.note = reason }
            return value
        }
        value.approvedAtCreation = true
        if value.step == .connecting, value.tone == .working { value.note = "Waiting for the guest’s SSH service. Setup starts automatically when it’s ready." }
        if case .following = autoSetup, value.step == .restart, value.tone == .needsYou {
            // Covered by the approval given in New VM: submitted automatically, once.
            value.tone = .working; value.setupAction = nil
            value.note = value.note.hasPrefix("Software installed")
                ? "Software installed. Restarting the guest to finish setup; the configuration is checked after it starts."
                : "The guest restarted. Checking the configuration to finish setup."
        }
        if value.step == .approve {
            // Approval was given in New VM: the review is prepared and submitted automatically.
            value = .init(step: .installing, tone: .working, note: "Starting setup. You approved it when you created this VM.", approvedAtCreation: true)
        }
        return value
    }

    private static func guestProgress(_ snapshot: VMSnapshot) -> FirstRunProgress {
        switch snapshot.state {
        case .stopped, .failed:
            if let failure = snapshot.lastFailure { return .init(step: .created, tone: .problem, note: failure.message) }
            return .init(step: .created, tone: .idle, note: "Launch this guest to begin. You review setup again before anything installs.")
        case .validating, .downloading, .starting:
            return .init(step: .starting, tone: .working, note: snapshot.state.label + ". The guest window opens when its display is ready.")
        case .running:
            return connectionProgress(snapshot)
        default:
            var value = connectionProgress(snapshot)
            value.tone = .idle; value.setupAction = nil
            value.note = snapshot.state.label + ". Setup continues when the guest is running."
            return value
        }
    }

    private static func connectionProgress(_ snapshot: VMSnapshot) -> FirstRunProgress {
        if case .failed(let message) = snapshot.ownerSetupReadiness { return .init(step: .firstBoot, tone: .problem, note: message) }
        switch snapshot.sshReadiness {
        case .ready:
            return .init(step: .approve, tone: .needsYou, note: "The guest is ready. Review setup to approve admin access and install the selected software.", setupAction: "Review setup…")
        case .waitingForOwner:
            let note = snapshot.profile.ownerSetup != nil ? "Omarchy is creating your account from Guest Defaults." : "Finish Omarchy’s account setup in the guest window."
            return .init(step: .firstBoot, tone: .working, note: note)
        case .provisioning, .connecting:
            return .init(step: .connecting, tone: .working, note: "Waiting for the guest’s SSH service so setup can be reviewed.")
        case .failed(let message):
            return .init(step: .connecting, tone: .problem, note: message)
        case .disabled:
            return .init(step: .connecting, tone: .problem, note: "Setup needs SSH from this Mac. Turn it on in Configure while the guest is stopped.")
        case .stopped, .paused:
            return .init(step: .starting, tone: .working, note: "Starting the guest.")
        }
    }

    private static func workflowProgress(_ row: ProvisioningWorkflowSnapshot, job: ProvisioningJobSnapshot?) -> FirstRunProgress {
        let attachKey = job.flatMap { $0.state == .queued ? nil : row.id.uuidString + ":" + $0.jobID.uuidString }
        switch row.stage {
        case .waitingForSSH:
            return .init(step: .approve, tone: .working, note: "Preparing the setup review in the guest.", setupAction: "Open setup…")
        case .readyForReview:
            return .init(step: .approve, tone: .needsYou, note: "Approve admin access to start installing.", setupAction: "Review setup…")
        case .running, .checking:
            var value = row.stage == .checking
                ? FirstRunProgress(step: .restart, tone: .working, note: "Checking the configuration after the restart.")
                : FirstRunProgress(step: .installing, tone: .working, note: "Installing software. You can use the guest while this runs.")
            if job?.state == .awaitingAuthorization { value.tone = .needsYou; value.note = "Setup is waiting for authorization in the terminal." }
            if let attachKey { value.terminal = (row.id, attachKey, true) }
            return value
        case .restartRequired:
            // Installing finished; the run is waiting for the user, not stuck. Keep the
            // output Home received and point at the saved copy on the Setup tab.
            var value = FirstRunProgress(step: .restart, tone: .needsYou,
                note: "Software installed. Restart the guest to finish: setup restarts it, then checks the configuration. The full output is kept in View output.",
                setupAction: "Review restart…")
            if let attachKey { value.terminal = (row.id, attachKey, false) }
            return value
        case .waitingForExit, .restarting:
            return .init(step: .restart, tone: .working, note: "Restarting the guest to finish setup.")
        case .waitingForRebind, .readyForCheck:
            return .init(step: .restart, tone: .needsYou, note: "The guest restarted. Review the configuration check to finish setup.", setupAction: "Review check…")
        case .failed, .cancelled, .interrupted, .cleanupRequired:
            let cleanup = row.cleanupRequired ? " Cleanup of temporary admin access needs review." : ""
            var value = FirstRunProgress(step: .installing, tone: .problem, note: failureNote(row, job: job) + cleanup, setupAction: "Open setup…")
            // Keep showing output Home received; it is not replayed once the job ends.
            if let attachKey { value.terminal = (row.id, attachKey, false) }
            return value
        case .succeeded, .checked:
            return .init(step: .ready, tone: .idle, note: row.title + ".")
        }
    }

    /// Built only from recorded categories, never from terminal text.
    static func failureNote(_ row: ProvisioningWorkflowSnapshot, job: ProvisioningJobSnapshot?) -> String {
        switch row.failure {
        case .systemUpdateFailed?: return "Setup failed: the Omarchy update failed before your selections were applied."
        case .helperUnavailable?: return "Setup could not start: this build can’t run the setup helper."
        default: break
        }
        switch job?.engineFailure {
        case .adapterFailed?: return "Setup failed: a task failed inside the guest."
        case .timedOut?: return "Setup timed out before it finished."
        case .dependencyChanged?: return "Setup stopped because the Mac’s setup tools changed while it ran."
        case .identityMismatch?, .sourceChanged?: return "Setup stopped because the guest or its inputs changed while it ran."
        case .cancelled?: return "Setup was cancelled."
        default: break
        }
        switch job?.failure {
        case .helperUnavailable?: return "Setup could not start: this build can’t run the setup helper."
        case .managerRestarted?: return "Setup stopped because the manager quit while it ran."
        case .lifecycleChanged?: return "Setup stopped because the guest stopped or restarted."
        case .dependencyChanged?: return "Setup stopped because the Mac’s setup tools changed."
        case .sourceChanged?: return "Setup stopped because its inputs changed."
        default: break
        }
        if job == nil, row.stage == .failed { return "Setup could not start in the guest. Open setup for details." }
        return row.title + "."
    }
}

struct FirstRunTracker: View {
    let progress: FirstRunProgress
    let openSetup: () -> Void

    var body: some View {
        GroupedPanel {
            VStack(alignment: .leading, spacing: 12) {
                SpecHeading("first run")
                HStack(alignment: .top, spacing: 4) {
                    ForEach(progress.steps, id: \.self) { step in
                        VStack(alignment: .leading, spacing: 8) {
                            StepBar(color: color(step), pulsing: step == progress.step && progress.tone == .working)
                            Text(step.title)
                                .font(Theme.sans(13, weight: step == progress.step ? .medium : .regular))
                                .foregroundStyle(labelColor(step)).lineLimit(1).minimumScaleFactor(0.8)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("First run, step \((progress.steps.firstIndex(of: progress.step) ?? 0) + 1) of \(progress.steps.count): \(progress.step.title)")
                HStack(alignment: .center, spacing: 12) {
                    if progress.tone == .working, progress.step < .approve { FrameMark(size: 28, tracer: Theme.green, loading: true) }
                    Text(progress.note).font(Theme.sans(13)).foregroundStyle(progress.tone == .problem ? Theme.amber : .secondary)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    if let action = progress.setupAction {
                        if progress.tone == .needsYou { Button(action, action: openSetup).buttonStyle(.primaryAction) }
                        else { Button(action, action: openSetup).buttonStyle(.quietAction) }
                    }
                }.accessibilityElement(children: .contain)
                if progress.approvedAtCreation {
                    Label("Approved when you created this VM, including temporary admin access and the restart that finishes setup.", systemImage: "checkmark")
                        .font(Theme.note).foregroundStyle(.secondary).labelStyle(ApprovedLabelStyle())
                }
            }.padding(.horizontal, 20).padding(.vertical, 16)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.paneRadius).strokeBorder(progress.tone == .needsYou ? Theme.amber.opacity(0.55) : .clear))
    }

    private func color(_ step: FirstRunProgress.Step) -> Color {
        if step < progress.step { return Theme.green }
        guard step == progress.step else { return Theme.quietFrame }
        switch progress.tone {
        case .working: return Theme.lavender
        case .needsYou, .problem: return Theme.amber
        case .idle: return Theme.idleFrame
        }
    }
    private func labelColor(_ step: FirstRunProgress.Step) -> Color {
        if step < progress.step { return Theme.text }
        guard step == progress.step else { return .secondary }
        switch progress.tone {
        case .working: return Theme.lavender
        case .needsYou, .problem: return Theme.amber
        case .idle: return Theme.text
        }
    }
}

extension FirstRunProgress.Step: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

private struct ApprovedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.foregroundStyle(Theme.green).font(.system(size: 10, weight: .bold)); configuration.title }
    }
}

private struct StepBar: View {
    let color: Color
    let pulsing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if pulsing && !reduceMotion {
            // Opacity only, driven by time: no implicit animation can move the layout.
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                Rectangle().fill(color).frame(height: 4).opacity(0.7 + 0.3 * cos(phase * 2 * .pi))
            }.frame(height: 4)
        } else {
            Rectangle().fill(color).frame(height: 4)
        }
    }
}

/// Live output on Home while setup installs. It is a second viewer of the same
/// job: closing it detaches only this viewer and never cancels setup.
struct FirstRunTerminal: View {
    @ObservedObject var model: AppModel
    let workflowID: UUID
    let attachmentKey: String
    let live: Bool
    let openSetup: () -> Void
    /// Output lives only in this view. After the job ends it stays until dismissed;
    /// a restart or rebuilt page starts empty, so an ended run is not shown again.
    @StateObject private var screen = ProvisioningTerminalScreen()
    @State private var watched = false
    @State private var dismissed = false

    var body: some View {
        if live || (watched && !dismissed) { terminal }
    }

    private var terminal: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Rectangle().fill(screen.connected ? Theme.green : Theme.label).frame(width: 7, height: 7)
                Text(live ? "Live terminal" : "Setup output").font(Theme.sans(13, weight: .medium))
                Spacer(minLength: 8)
                Toggle("Follow output", isOn: $screen.follow).toggleStyle(SpecSwitchToggleStyle()).font(Theme.sans(13))
                if screen.ownsInput { Button("Release input") { Task { await screen.releaseInput() } } }
                if live, !screen.connected, let service = model.setupService {
                    Button("Reconnect") { Task { await screen.attach(service: service, workflowID: workflowID) } }
                }
                Button("View output", action: openSetup)
                if !live {
                    Button { dismissed = true } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                        .accessibilityLabel("Dismiss setup output").help("Dismiss setup output")
                }
            }
            .buttonStyle(.quietAction).padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
            .background(Theme.pane).overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            ProvisioningNativeTerminal(screen: screen).frame(height: 340).clipped()
            HStack {
                Text(!live ? "Live output has ended. Scroll up to see where setup stopped." : screen.connected ? "You can leave this page. Setup will continue." : screen.message)
                    .font(Theme.sans(13)).foregroundStyle(.secondary)
                Spacer()
                if screen.acceptsInput { Label("Interactive input available", systemImage: "keyboard").font(Theme.note).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.pane).overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .background(Color.black, in: RoundedRectangle(cornerRadius: Theme.paneRadius))
        .clipShape(RoundedRectangle(cornerRadius: Theme.paneRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.paneRadius).strokeBorder(Theme.border))
        .task(id: attachmentKey + (live ? ":live" : ":ended")) {
            // Attach only to a live admitted job; never reclaim input automatically.
            // An ended job is never reattached, so retained output is not reset.
            if live, !screen.connected, let service = model.setupService { await screen.attach(service: service, workflowID: workflowID) }
        }
        .onChange(of: screen.connected) { _, connected in if connected { watched = true } }
        .onDisappear { Task { await screen.detach() } }
    }
}

/// Shown once on Home after setup was observed finishing during this run.
struct FirstRunComplete: View {
    let viewLog: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.green).accessibilityHidden(true)
            Text("Setup complete. The selected software is installed.").font(Theme.sans(14)).frame(maxWidth: .infinity, alignment: .leading)
            Button("View log", action: viewLog).buttonStyle(.quietAction)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.quietAction).accessibilityLabel("Dismiss")
        }
        .padding(.leading, 18).padding(.trailing, 12).padding(.vertical, 10)
        .background(Theme.green.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.paneRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.paneRadius).strokeBorder(Theme.green.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}
