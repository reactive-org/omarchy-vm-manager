import OmarchyVMManagerCore
import SwiftUI

/// A setup run followed on the guest's Home, as New VM does for the first run
/// (user direction, 9 November 2026): approving in Change setup closes the sheet
/// and this panel shows the run's steps, one sentence and the live terminal. It
/// replaces the setup card while a run is under way; the card returns when it ends.
struct SetupRunPanel: View {
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @ObservedObject var model: AppModel
    let snapshot: VMSnapshot
    let phase: SetupRunPhase
    let open: (SetupSheet) -> Void
    @State private var confirmCancel = false
    @State private var working = false
    @State private var failure: String?

    private var row: ProvisioningWorkflowSnapshot? { if case .live(let value) = phase { value } else { nil } }
    private var job: ProvisioningJobSnapshot? { row.flatMap { model.setupJobs[$0.id] } }
    private var status: SetupRunStatus {
        SetupRunStatus.make(phase, lastRun: nil, latestPlanExists: true, running: snapshot.sessionID != nil, job: job,
                            auto: model.autoSetup[snapshot.id], checkOnly: model.checkOnlyRuns)
    }
    /// The step that waits for the owner and that nobody is following.
    private var finishAction: String? {
        guard let row, status.tint == .attention, job?.state != .awaitingAuthorization else { return nil }
        if row.availableActions.contains(.restart) { return "Restart & check" }
        if row.availableActions.contains(.check) { return "Run the check" }
        return nil
    }
    /// The live terminal attaches only to an admitted job, as on the first run.
    private var terminalKey: String? {
        guard let row, let job, job.state != .queued else { return nil }
        return row.id.uuidString + ":" + job.jobID.uuidString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            GroupedPanel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("setup").font(Theme.mono(13, weight: .medium)).foregroundStyle(status.color).accessibilityAddTraits(.isHeader)
                        Text(status.label).font(Theme.mono(13)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        actions
                    }
                    SetupStepStrip(states: status.steps)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.title).font(Theme.sans(15, weight: .semibold))
                        if !status.note.isEmpty { Text(status.note).font(Theme.sans(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        if let failure { Label(failure, systemImage: "exclamationmark.circle").font(Theme.sans(13)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true) }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 16)
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.paneRadius).strokeBorder(status.tint == .attention ? Theme.amber.opacity(0.55) : .clear))
            .accessibilityIdentifier("guest.setup-run")
            if let row, let terminalKey {
                FirstRunTerminal(model: model, workflowID: row.id, attachmentKey: terminalKey, live: row.canCancel) { open(.output) }
            }
        }
        .buttonStyle(.quietAction)
        .confirmationDialog("Cancel setup and perform its cleanup?", isPresented: cancelPresentation) {
            Button("Cancel setup", role: .destructive) { cancel() }
        } message: { Text("Cleanup removes temporary admin access. It may still need verification.") }
        .background { acceptanceBinding }
    }

    @ViewBuilder private var actions: some View {
        if working { ProgressView().controlSize(.small) }
        switch phase {
        case .live(let row):
            if terminalKey == nil { Button("View output") { open(.output) } }
            if row.canCancel { Button("Cancel setup…") { confirmCancel = true }.foregroundStyle(Theme.amber) }
            if let finishAction {
                Button(finishAction) { Task { await finish(row) } }.buttonStyle(.primaryAction).disabled(working)
            }
        case .starting:
            Button("Don’t set up") { model.autoSetup[snapshot.id] = nil }.foregroundStyle(Theme.amber)
        default:
            EmptyView()
        }
    }

    @MainActor private func finish(_ row: ProvisioningWorkflowSnapshot) async {
        working = true; failure = nil; defer { working = false }
        failure = await model.finishSetup(row)
    }

    private func cancel() {
        guard let row, row.canCancel else { return }
        if model.autoSetup[snapshot.id]?.plan?.previewID == row.id { model.autoSetup[snapshot.id] = .consumed }
        Task { await model.cancelSetup(row.id) }
    }

    private var cancelPresentation: Binding<Bool> {
        #if DEBUG
        if acceptance != nil { return .constant(false) }
        #endif
        return $confirmCancel
    }

    @ViewBuilder private var acceptanceBinding: some View {
        #if DEBUG
        if let acceptance {
            Color.clear.allowsHitTesting(false).onAppear {
                acceptance.bind("run-panel", action: { command in
                    switch command {
                    case .requestCancel: if row?.canCancel == true { confirmCancel = true }
                    case .confirmCancel: if confirmCancel { confirmCancel = false; cancel() }
                    default: break
                    }
                }, snapshot: {
                    var actions: [String] = []
                    if case .live(let row) = phase {
                        if terminalKey == nil { actions.append("View output") }
                        if row.canCancel { actions.append("Cancel setup…") }
                        if let finishAction { actions.append(finishAction) }
                    } else if case .starting = phase { actions.append("Don’t set up") }
                    return ["title": status.title, "steps": status.steps.map { "\($0)" }.joined(separator: ","),
                            "actions": actions.joined(separator: "|"), "terminal": String(terminalKey != nil)]
                })
            }
        }
        #endif
    }
}
