import AppKit
import OmarchyProvisioningTerminalUI
import OmarchyVMManagerCore
import SwiftUI

/// The View output sheet: the run's live terminal or saved log, cancel and job
/// details. Choosing and approving setup lives in Change setup (`ChangeSetupView`).
/// `.full` adds the reviewed workflow actions and exists for the offscreen
/// acceptance harness, which cannot capture sheets.
struct DeveloperSetupView: View {
    enum Mode { case output, full }
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @ObservedObject var model: AppModel
    let snapshot: VMSnapshot
    var mode: Mode = .full
    init(model: AppModel, snapshot: VMSnapshot, mode: Mode = .full) {
        self.model = model; self.snapshot = snapshot; self.mode = mode
    }
    @StateObject private var screen = ProvisioningTerminalScreen()
    @State private var selectedWorkflow: UUID?
    @State private var actionBusy = false
    /// The workflow whose cleanup-hold release is awaiting confirmation. Kept apart
    /// from the alert's presentation so dismissing it can't clear the target first.
    @State private var confirmRelease: ProvisioningWorkflowSnapshot?
    @State private var releaseShown = false
    @State private var failure: String?
    @State private var search = ""
    @State private var matches: Int?
    @State private var confirmCancel = false
    /// The terminal shows the saved last-run log rather than a live job.
    @State private var showingSavedLog = false
    private var workflows: [ProvisioningWorkflowSnapshot] { model.setupWorkflows.filter { $0.vmID == snapshot.id } }
    private var workflow: ProvisioningWorkflowSnapshot? {
        workflows.first { $0.id == selectedWorkflow } ?? workflows.first { $0.canCancel || $0.cleanupRequired } ?? workflows.first
    }
    // The page and its modifiers are separate expressions so the type checker
    // (notably Xcode 26 in CI) handles each within its time limit.
    var body: some View { attach(page) }
    private var page: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let failure { Text(failure).foregroundStyle(.orange) }
            if workflows.count > 1 {
                Picker("Workflow", selection: Binding(get: { workflow?.id }, set: { selectedWorkflow = $0 })) {
                    ForEach(workflows, id: \.id) { row in Text(row.title + " · " + row.id.uuidString.prefix(8)).tag(Optional(row.id)) }
                }
            }
            if let workflow {
                if mode == .full { Text(workflow.title).font(Theme.sans(20, weight: .semibold)) }
                if let explanation = workflow.failureExplanation { Text(explanation).font(Theme.sans(13)).foregroundStyle(.orange) }
                if mode == .full { HStack(spacing: 14) {
                    ForEach(ProvisioningSetupPhase.allCases, id: \.self) { phase in
                        Label(phase.rawValue, systemImage: currentPhase(workflow) == phase ? "circle.inset.filled" : "circle").foregroundStyle(currentPhase(workflow) == phase ? Color.accentColor : Color.secondary)
                    }
                }.accessibilityLabel("Setup stages. Current workflow: " + workflow.title) }
                if workflow.cleanupRequired {
                    if workflow.stage == .running || workflow.stage == .checking {
                        Text("Setup tracks temporary admin access and will verify its removal during cleanup.").font(.caption).foregroundStyle(.secondary)
                    } else if snapshot.sessionID == nil {
                        Label("Cleanup has not been confirmed and this guest has stopped, so it can’t be verified. Review the cleanup hold to release it.", systemImage: "exclamationmark.shield").foregroundStyle(.orange)
                    } else { Label("Cleanup has not been confirmed. Recovery must verify the original guest and authorization state.", systemImage: "exclamationmark.shield").foregroundStyle(.orange) }
                }
                if mode == .full { workflowActions(workflow) }
                do {
                    terminal(height: mode == .output ? 520 : 420)
                    HStack {
                        Text(continuationMessage).font(Theme.sans(13)).foregroundStyle(.secondary)
                        Spacer()
                        if workflow.canCancel || mode == .full { Button("Cancel setup…") { confirmCancel = true }.disabled(!workflow.canCancel) }
                    }
                }
                DisclosureGroup("Job details") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Workflow: " + workflow.id.uuidString).textSelection(.enabled)
                        Text("State: " + workflow.stage.rawValue)
                        if let code = workflow.failure { Text("Result: " + code.rawValue) }
                        Text("Closing the terminal detaches this viewer. It does not cancel setup.")
                        Text("Restart, check and cleanup recovery require a reviewed action; no automatic retry is performed.")
                    }.font(.caption).padding(.top, 8)
                }
            } else {
                terminal(height: 260)
                Text("No setup job for this guest. Live output will appear here when an admitted job is available.").foregroundStyle(.secondary).font(Theme.sans(13))
            }
        }
    }
    private func attach(_ content: some View) -> some View {
        content
        .onChange(of: workflow?.id) { _, _ in confirmRelease = nil; releaseShown = false }
        // A separate modifier keeps this long body within the type checker's time limit.
        .modifier(ReleaseConfirmation(isPresented: releasePresentation) {
            if let held = confirmRelease { confirmRelease = nil; Task { await runWorkflowAction(held, action: .release) } }
        })
        .confirmationDialog("Cancel setup and perform its cleanup?", isPresented: cancelPresentation) {
            Button("Cancel setup", role: .destructive) { cancelConfirmed() }
        } message: { Text("Cleanup may still need verification. Closing this page only detaches the terminal.") }
        .task(id: terminalAttachmentID) {
            // Publish/prepare precedes helper activation. Wait for an admitted
            // job before initial attachment; never auto-reclaim input on loss.
            // An ended job is not reattached; its saved log is shown instead.
            if terminalAttachmentID != nil, liveRun, let workflow, let service = model.setupService {
                showingSavedLog = false
                await screen.attach(service: service, workflowID: workflow.id)
            }
        }
        .task(id: savedLogKey) {
            guard !liveRun, let service = model.setupService else { return }
            if let data = await service.setupLog(vmID: snapshot.id) {
                await screen.detach(); screen.resetScreen(); screen.render(data); screen.jumpToLatest(); showingSavedLog = true
            } else { showingSavedLog = false }
        }
        .task(id: snapshot.id.uuidString + String(model.setupService != nil)) {
            // View output follows the latest run too, not the first finished row by ID.
            if selectedWorkflow == nil, let service = model.setupService as? any ProvisioningRetrying,
               let run = await service.latestSetup(vmID: snapshot.id)?.workflow, selectedWorkflow == nil { selectedWorkflow = run.id }
        }
        .background {
            #if DEBUG
            if let acceptance { Color.clear.allowsHitTesting(false).onAppear {
                acceptance.terminalScreen = screen
                acceptance.bind("setup", action: { command in
                    switch command {
                    case .search(let value): search = value; matches = screen.search(value)
                    case .requestCancel: if workflow?.canCancel == true { confirmCancel = true }
                    case .confirmCancel: if confirmCancel { confirmCancel = false; cancelConfirmed() }
                    default: break
                    }
                }, snapshot: { acceptanceState })
            } }
            #endif
        }
        .onDisappear { Task { await screen.detach() } }
    }
    #if DEBUG
    private var acceptanceState: [String: String] {
        ["failure": String(failure != nil), "matches": matches.map(String.init) ?? "", "cancelPending": String(confirmCancel), "continuation": continuationMessage,
         "savedLog": String(showingSavedLog), "workflow": workflow?.id.uuidString ?? ""]
    }
    #endif
    private func cancelConfirmed() { if let workflow, workflow.canCancel { Task { await model.cancelSetup(workflow.id) } } }
    private var releasePresentation: Binding<Bool> {
        #if DEBUG
        if acceptance != nil { return .constant(false) }
        #endif
        return $releaseShown
    }
    private var cancelPresentation: Binding<Bool> {
        #if DEBUG
        if acceptance != nil { return .constant(false) }
        #endif
        return $confirmCancel
    }
    private var actingService: (any ProvisioningWorkflowActing)? { model.setupService as? any ProvisioningWorkflowActing }
    /// Recovery needs the original live session; releasing the hold needs a stopped
    /// guest (issue #24). Only the one that can work is offered.
    static func visibleActions(_ workflow: ProvisioningWorkflowSnapshot, guestRunning: Bool) -> [ProvisioningWorkflowAction] {
        workflow.availableActions.filter { action in
            switch action {
            case .recover: guestRunning
            case .release: !guestRunning
            case .restart, .check: true
            }
        }
    }
    /// Release is the one action that verifies nothing, so it alone is confirmed,
    /// and the confirmation says so plainly.
    static let releaseConfirmation = "Cleanup wasn’t verified. This guest may still allow passwordless sudo or other temporary admin access, and you’ll need to remove it inside the guest."
    @ViewBuilder private func workflowActions(_ workflow: ProvisioningWorkflowSnapshot) -> some View {
        let actions = Self.visibleActions(workflow, guestRunning: snapshot.sessionID != nil)
        if !actions.isEmpty {
            GroupedPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Next step").font(Theme.sans(14, weight: .semibold))
                    ForEach(actions, id: \.self) { action in
                        HStack {
                            Text(action.explanation).font(Theme.sans(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button(action.title + (action == .release ? "…" : "")) {
                                if action == .release { confirmRelease = workflow; releaseShown = true } else { Task { await runWorkflowAction(workflow, action: action) } }
                            }
                            .buttonStyle(.primaryAction)
                            .disabled(actingService?.executionEnabled != true || actionBusy)
                        }
                    }
                    if actionBusy { ProgressView().controlSize(.small) }
                    if actingService?.executionEnabled != true { Text("Workflow execution is unavailable in this build or service.").font(.caption).foregroundStyle(.secondary) }
                }.padding(20)
            }
        }
    }
    /// One click: prepare a review bound to this guest's current state, then submit
    /// exactly that review. The click is the owner's consent (user direction,
    /// 7 November 2026). A failure submits nothing further; the next click starts a
    /// fresh review, never a retry of the old one.
    @MainActor private func runWorkflowAction(_ workflow: ProvisioningWorkflowSnapshot, action: ProvisioningWorkflowAction) async {
        guard let service = actingService, !actionBusy else { return }
        actionBusy = true; failure = nil
        defer { actionBusy = false }
        let review: ProvisioningWorkflowActionReview
        do { review = try await service.prepareAction(workflow.id, action: action, reviewID: UUID()) }
        catch { failure = action.title + " isn’t possible right now. Check the guest’s current state; nothing was changed."; return }
        guard self.workflow?.id == workflow.id, review.workflowID == workflow.id, review.action == action else { return }
        do {
            _ = try await service.performAction(workflow.id, consent: .init(reviewID: review.id, action: action, reviewIdentity: review.reviewIdentity, acknowledged: true))
        } catch { failure = action.title + " didn’t complete. Check the setup state before trying again; it wasn’t retried automatically." }
    }
    private func currentPhase(_ workflow: ProvisioningWorkflowSnapshot) -> ProvisioningSetupPhase? {
        if workflow.stage == .waitingForSSH { return .connect }
        if [.readyForReview, .readyForCheck].contains(workflow.stage) { return .review }
        if let state = model.setupJobs[workflow.id]?.state {
            if state == .awaitingAuthorization { return .authorize }
            if [.cleaningUp, .cancelling, .cleanupRequired].contains(state) { return .cleanup }
            if state == .running { return .configure }
        }
        return nil // No guessed stage or fabricated completed checkmarks.
    }
    private func terminal(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(screen.connected ? Theme.green : Theme.label).frame(width: 7, height: 7)
                Text(showingSavedLog ? "saved output" : "live output").font(Theme.mono(12)).foregroundStyle(.secondary)
                TextField("Search output", text: $search).textFieldStyle(.roundedBorder).font(Theme.sans(12)).frame(maxWidth: 220)
                    .onSubmit { matches = screen.search(search) }
                if let matches { Text("\(matches) matching lines").font(Theme.note).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                if showingSavedLog, let url = model.setupLogURL(snapshot) {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                if liveRun, !screen.connected, let workflow, let service = model.setupService {
                    Button("Reconnect") { Task { await screen.attach(service: service, workflowID: workflow.id) } }
                }
                if screen.ownsInput { Button("Release input") { Task { await screen.releaseInput() } } }
                Button { screen.fontSize -= 1 } label: { Image(systemName: "textformat.size.smaller") }.disabled(screen.fontSize <= 9).help("Smaller text")
                Button { screen.fontSize += 1 } label: { Image(systemName: "textformat.size.larger") }.disabled(screen.fontSize >= 24).help("Larger text")
                Button { screen.jumpToLatest() } label: { Image(systemName: "arrow.down.to.line") }.help("Jump to latest")
                Toggle("Follow output", isOn: $screen.follow).font(Theme.sans(12))
            }
            .controlSize(.small).padding(.horizontal, 12).frame(minHeight: 40)
            .background(Theme.pane).overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            ProvisioningNativeTerminal(screen: screen).frame(height: height).clipped()
            HStack {
                Text(showingSavedLog ? "Saved output from the most recent setup run, kept next to this VM. It may include anything setup printed; typed input is never saved."
                     : workflow?.canCancel == false && !screen.connected ? "Live output has ended. Job status remains available." : screen.message)
                    .font(Theme.note).foregroundStyle(.secondary)
                Spacer()
                if screen.acceptsInput { Label("Type into the terminal when setup asks", systemImage: "keyboard").font(Theme.note) }
            }.padding(.horizontal, 12).padding(.vertical, 8).background(Theme.pane)
        }
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: Theme.paneRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.paneRadius).strokeBorder(Theme.border))
    }
    private var continuationMessage: String {
        guard let workflow else { return "No setup job is running." }
        if workflow.cleanupRequired && !workflow.canCancel { return "Cleanup still needs verification. Review job details before continuing." }
        return workflow.canCancel ? "You can leave this page. Setup will continue." : "Setup has finished. Its result remains saved."
    }
    private var liveRun: Bool { workflow?.canCancel == true }
    private var savedLogKey: String { snapshot.id.uuidString + ":" + (workflow?.id.uuidString ?? "none") + ":" + (workflow?.stage.rawValue ?? "") + ":" + String(liveRun) }
    private var terminalAttachmentID: String? {
        guard let workflow, let job = model.setupJobs[workflow.id], job.state != .queued else { return nil }
        return workflow.id.uuidString + ":" + job.jobID.uuidString
    }
}

/// Confirms the one workflow action that verifies nothing (issue #24).
struct ReleaseConfirmation: ViewModifier {
    let isPresented: Binding<Bool>
    let release: () -> Void
    func body(content: Content) -> some View {
        content.alert("Release cleanup hold?", isPresented: isPresented) {
            Button("Release cleanup hold", role: .destructive, action: release)
            Button("Cancel", role: .cancel) {}
        } message: { Text(DeveloperSetupView.releaseConfirmation) }
    }
}
