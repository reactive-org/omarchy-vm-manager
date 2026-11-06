import OmarchyProvisioningTerminalUI
import OmarchyVMManagerCore
import SwiftUI

/// First-run progress for a guest created with developer setup. Every step comes
/// from observed guest, SSH or workflow state; nothing is inferred from time and
/// no step is marked complete before its state is seen. Approval stays on the
/// Setup page, which owns the exact consent review.
struct FirstRunProgress: Equatable {
    enum Step: Int, CaseIterable {
        case created, starting, firstBoot, connecting, approve, installing, ready
        var title: String {
            switch self {
            case .created: "Created"
            case .starting: "Starting"
            case .firstBoot: "First boot"
            case .connecting: "Connecting"
            case .approve: "Approve"
            case .installing: "Installing"
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
    /// The workflow whose live output Home shows, with its terminal attachment key.
    var terminal: (workflowID: UUID, key: String)?
    /// Approved in New VM (Create, Launch & Set Up): no Approve step is shown.
    var approvedAtCreation = false

    var steps: [Step] { approvedAtCreation ? Step.allCases.filter { $0 != .approve } : Step.allCases }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.step == rhs.step && lhs.tone == rhs.tone && lhs.note == rhs.note && lhs.setupAction == rhs.setupAction && lhs.terminal?.key == rhs.terminal?.key
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
            return .init(step: .installing, tone: .problem, note: "Earlier setup runs did not finish. Review their results before trying again.", setupAction: "Open Setup")
        }
        guard let autoSetup else { return value }
        if let reason = autoSetup.blockedReason {
            // The one-time approval no longer applies; the manual review takes over.
            if value.step <= .approve, value.tone != .problem { value = .init(step: .approve, tone: .needsYou, note: reason, setupAction: "Review Setup…") }
            return value
        }
        value.approvedAtCreation = true
        if value.step == .connecting, value.tone == .working { value.note = "Waiting for the guest’s SSH service. Setup starts automatically when it’s ready." }
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
            return .init(step: .approve, tone: .needsYou, note: "The guest is ready. Review setup to approve admin access and install the selected software.", setupAction: "Review Setup…")
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
            return .init(step: .approve, tone: .working, note: "Preparing the setup review in the guest.", setupAction: "Open Setup")
        case .readyForReview:
            return .init(step: .approve, tone: .needsYou, note: "Approve admin access to start installing.", setupAction: "Review Setup…")
        case .running, .checking:
            var value = FirstRunProgress(step: .installing, tone: .working, note: "Installing software. You can use the guest while this runs.")
            if job?.state == .awaitingAuthorization { value.tone = .needsYou; value.note = "Setup is waiting for authorization in the terminal." }
            if let attachKey { value.terminal = (row.id, attachKey) }
            return value
        case .restartRequired:
            return .init(step: .installing, tone: .needsYou, note: "Setup needs a reviewed restart to finish.", setupAction: "Review Restart…")
        case .waitingForExit, .restarting:
            return .init(step: .installing, tone: .working, note: "Restarting the guest to finish setup.")
        case .waitingForRebind, .readyForCheck:
            return .init(step: .installing, tone: .needsYou, note: "Review the configuration check to finish setup.", setupAction: "Review Check…")
        case .failed, .cancelled, .interrupted, .cleanupRequired:
            let cleanup = row.cleanupRequired ? " Cleanup of temporary admin access needs review." : ""
            return .init(step: .installing, tone: .problem, note: row.title + "." + cleanup, setupAction: "Open Setup")
        case .succeeded, .checked:
            return .init(step: .ready, tone: .idle, note: row.title + ".")
        }
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
                    if progress.tone == .working, progress.step < .approve { FrameMark(size: 28, tracer: Theme.green) }
                    Text(progress.note).font(Theme.sans(13)).foregroundStyle(progress.tone == .problem ? Theme.amber : .secondary)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    if let action = progress.setupAction {
                        if progress.tone == .needsYou { Button(action, action: openSetup).buttonStyle(.primaryAction) }
                        else { Button(action, action: openSetup).buttonStyle(.quietAction) }
                    }
                }.accessibilityElement(children: .contain)
                if progress.approvedAtCreation {
                    Label("Approved when you created this VM, including temporary admin access.", systemImage: "checkmark")
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
    let openSetup: () -> Void
    @StateObject private var screen = ProvisioningTerminalScreen()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Rectangle().fill(screen.connected ? Theme.green : Theme.label).frame(width: 7, height: 7)
                Text("Live terminal").font(Theme.sans(13, weight: .medium))
                Spacer(minLength: 8)
                Toggle("Follow output", isOn: $screen.follow).toggleStyle(SpecSwitchToggleStyle()).font(Theme.sans(13))
                if screen.ownsInput { Button("Release Input") { Task { await screen.releaseInput() } } }
                if !screen.connected, let service = model.setupService {
                    Button("Reconnect") { Task { await screen.attach(service: service, workflowID: workflowID) } }
                }
                Button("Open in Setup", action: openSetup)
            }
            .buttonStyle(.quietAction).padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
            .background(Theme.pane).overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            ProvisioningNativeTerminal(screen: screen).frame(height: 340).clipped()
            HStack {
                Text(screen.connected ? "You can leave this page. Setup will continue." : screen.message)
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
        .task(id: attachmentKey) {
            // Attach only to an admitted job; never reclaim input automatically.
            if let service = model.setupService { await screen.attach(service: service, workflowID: workflowID) }
        }
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
            Button("View Log", action: viewLog).buttonStyle(.quietAction)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.quietAction).accessibilityLabel("Dismiss")
        }
        .padding(.leading, 18).padding(.trailing, 12).padding(.vertical, 10)
        .background(Theme.green.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.paneRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.paneRadius).strokeBorder(Theme.green.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}
