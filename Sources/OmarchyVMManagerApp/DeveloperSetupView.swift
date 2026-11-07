import AppKit
import OmarchyProvisioningTerminalUI
import OmarchyVMManagerCore
import SwiftUI
import UniformTypeIdentifiers

/// Offline selection and review never creates a VM or authorizes tasks. The
/// running-job pane consumes the same service used by the separate CLI socket.
/// Presented from the guest's Home setup card: `.change` is the Change setup sheet
/// (selection, review, consent and reviewed workflow actions) and `.output` the
/// View output sheet (live terminal or saved log, cancel, job details). `.full`
/// shows both and exists for the offscreen acceptance harness, which cannot
/// capture sheets.
struct DeveloperSetupView: View {
    enum Mode { case change, output, full }
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @ObservedObject var model: AppModel
    let snapshot: VMSnapshot
    var mode: Mode = .full
    private var showsChange: Bool { mode != .output }
    private var showsOutput: Bool { mode != .change }
    @StateObject private var screen = ProvisioningTerminalScreen()
    @State private var source = "none"
    @State private var trimOptionalApps = false
    @State private var appearance = ProvisioningAppearanceDraft()
    @State private var profiles: Set<String> = ["developer"]
    @State private var selectedWorkflow: UUID?
    @State private var folder: URL?
    @State private var choosingFolder = false
    @State private var preview: String?
    @State private var frozen: ProvisioningPlanPreview?
    @State private var captureID: UUID?
    @State private var applyReview: ProvisioningApplyReview?
    @State private var preparingApply = false
    @State private var submitting = false
    @State private var submissionAttempted = false
    @State private var grantConsent = false
    @State private var dockerConsent = false
    @State private var taskConsent = false
    @State private var inspectedTasks = Set<String>()
    @State private var taskText: String?
    @State private var showingTask = false
    @State private var inspectingTask = false
    @State private var previewLookup = ""
    @State private var workflowActionReview: ProvisioningWorkflowActionReview?
    @State private var actionRequestID: UUID?
    @State private var actionRequested: ProvisioningWorkflowAction?
    @State private var actionBusy = false
    @State private var actionAcknowledged = false
    @State private var actionAttempted = false
    @State private var planning = false
    @State private var planRevision = UUID()
    @State private var failure: String?
    @State private var search = ""
    @State private var matches: Int?
    @State private var confirmCancel = false
    @State private var tools = false
    /// The terminal shows the saved last-run log rather than a live job.
    @State private var showingSavedLog = false
    private var workflows: [ProvisioningWorkflowSnapshot] { model.setupWorkflows.filter { $0.vmID == snapshot.id } }
    private var workflow: ProvisioningWorkflowSnapshot? {
        workflows.first { $0.id == selectedWorkflow } ?? workflows.first { $0.canCancel || $0.cleanupRequired } ?? workflows.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if showsChange {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Software and desktop").font(Theme.sans(17, weight: .semibold))
                    Text("Configure this VM from a reviewed dev-vm configuration.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Provisioning tools…") { tools = true }
            }
            GroupedPanel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("Source", selection: $source) {
                            Text("None").tag("none")
                            Text("Bundled configuration").tag("bundled")
                            Text("Local setup folder").tag("local")
                        }.help(ProvisioningSetupHelp.source).frame(maxWidth: 340).disabled(planning || preparingApply || submitting || applyReview != nil)
                        if source == "local" { Button("Choose folder…") { choosingFolder = true }.disabled(planning || preparingApply || submitting || applyReview != nil) }
                        Spacer()
                        Button(frozen == nil ? "Review setup" : "Update preview") { Task { await plan() } }.accessibilityIdentifier("setup.preview").disabled(source == "none" || planning || preparingApply || submitting || applyReview != nil || (source == "local" && folder == nil) || (source == "bundled" && profiles.isEmpty) || appearance.failure != nil)
                        if planning { ProgressView().controlSize(.small) }
                    }
                    if source != "none" { ProvisioningProfileSelectionView(selection: $profiles, localSource: source == "local").disabled(planning || preparingApply || submitting || applyReview != nil) }
                    if source != "none", ProvisioningTrim.isAvailable(for: snapshot.profile.factory) {
                        ProvisioningTrimSelectionView(selection: $trimOptionalApps).disabled(planning || preparingApply || submitting || applyReview != nil)
                    }
                    if source != "none" { ProvisioningAppearanceSelectionView(draft: $appearance, localSource: source == "local").disabled(planning || preparingApply || submitting || applyReview != nil) }
                    if let folder, source == "local" { Text(folder.lastPathComponent + "/vm.yml").font(.caption).foregroundStyle(.secondary) }
                    Text("Setup updates Omarchy and system packages before applying your selections. Review software, removals, dotfiles and the restart requirement below. Custom tasks require separate trust.").font(Theme.sans(13)).foregroundStyle(.secondary)
                    Text(executionEnabled ? "Applying setup requires a target review and the permissions shown below. A preview does not change this VM." : "Setup execution is disabled in this build. A preview does not change this VM or its resource settings.").font(Theme.sans(13)).foregroundStyle(.secondary)
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Preview ID from CLI", text: $previewLookup).textFieldStyle(.roundedBorder)
                                Button("Open preview") { Task { await loadPreview() } }.accessibilityIdentifier("setup.lookup").disabled(UUID(uuidString: previewLookup) == nil || planning || preparingApply || submitting || applyReview != nil)
                            }
                            if let frozen {
                                Text("Preview ID: " + frozen.id.uuidString).font(.caption).textSelection(.enabled)
                                Text("Input fingerprint: " + frozen.inputDigest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                ForEach(frozen.tasks, id: \.name) { task in
                                    Text(task.name + " fingerprint: " + task.sha256).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                            if let review = applyReview {
                                Text("Apply review: " + review.reviewIdentity).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                if let trust = review.taskTrustIdentity { Text("Task trust: " + trust).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                            }
                            if let preview {
                                Text("Exact frozen proposal").font(.caption.bold())
                                ScrollView([.horizontal, .vertical]) {
                                    Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(12)
                                }.frame(height: 220)
                            }
                        }.padding(.top, 8)
                    }
                    if frozen != nil, source == "none" {
                        Text("A saved frozen selection is loaded below. Choose a source only to create a new preview.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let frozen {
                        ProvisioningReviewedProfilesView(proposal: frozen.proposal)
                        ProvisioningReviewedTrimView(proposal: frozen.proposal)
                        ProvisioningReviewedAppearanceView(proposal: frozen.proposal)
                        reviewActions(frozen)
                    }
                }.padding(20)
            }
            }
            if let failure { Text(failure).foregroundStyle(.orange) }
            if workflows.count > 1 {
                Picker("Workflow", selection: Binding(get: { workflow?.id }, set: { selectedWorkflow = $0 })) {
                    ForEach(workflows, id: \.id) { row in Text(row.title + " · " + row.id.uuidString.prefix(8)).tag(Optional(row.id)) }
                }
            }
            if mode == .change, let workflow {
                // Change setup shows only the reviewed actions waiting on the user; progress and output live in View output.
                workflowActions(workflow)
            } else if let workflow {
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
                    } else { Label("Cleanup has not been confirmed. Recovery must verify the original guest and authorization state.", systemImage: "exclamationmark.shield").foregroundStyle(.orange) }
                }
                if mode == .full { workflowActions(workflow) }
                if showsOutput {
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
            } else if showsOutput {
                terminal(height: 260)
                Text("No setup job for this guest. Live output will appear here when an admitted job is available.").foregroundStyle(.secondary).font(Theme.sans(13))
            }
        }
        .onChange(of: workflow?.id) { _, _ in
            workflowActionReview = nil; actionRequestID = nil; actionRequested = nil; actionAcknowledged = false; actionAttempted = false
        }
        .onChange(of: source) { _, _ in profiles = source == "bundled" ? ["developer"] : []; invalidatePreview() }
        .onChange(of: snapshot.profile.factory) { _, _ in trimOptionalApps = false; invalidatePreview() }
        .onChange(of: appearance) { _, _ in invalidatePreview() }
        .onChange(of: trimOptionalApps) { _, _ in invalidatePreview() }
        .onChange(of: profiles) { _, _ in invalidatePreview() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { invalidatePreview(); folder = url }
        }
        .sheet(isPresented: taskPresentation) {
            VStack(alignment: .leading) {
                Text("Frozen task source").font(Theme.sans(20, weight: .semibold))
                ScrollView([.horizontal, .vertical]) { Text(taskText ?? "Source unavailable").font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(12) }
                Button("Done") { showingTask = false }
            }.padding(20).frame(width: 760, height: 560)
        }
        .sheet(isPresented: $tools) { ScrollView { ProvisioningToolsView().padding(24) }.frame(width: 680, height: 640) }
        .confirmationDialog("Cancel setup and perform its cleanup?", isPresented: cancelPresentation) {
            Button("Cancel setup", role: .destructive) { cancelConfirmed() }
        } message: { Text("Cleanup may still need verification. Closing this page only detaches the terminal.") }
        .task(id: terminalAttachmentID) {
            // Publish/prepare precedes helper activation. Wait for an admitted
            // job before initial attachment; never auto-reclaim input on loss.
            // An ended job is not reattached; its saved log is shown instead.
            if showsOutput, terminalAttachmentID != nil, liveRun, let workflow, let service = model.setupService {
                showingSavedLog = false
                await screen.attach(service: service, workflowID: workflow.id)
            }
        }
        .task(id: savedLogKey) {
            guard showsOutput, !liveRun, let service = model.setupService else { return }
            if let data = await service.setupLog(vmID: snapshot.id) {
                await screen.detach(); screen.resetScreen(); screen.render(data); screen.jumpToLatest(); showingSavedLog = true
            } else { showingSavedLog = false }
        }
        .task(id: snapshot.id.uuidString + String(model.setupService != nil)) {
            guard showsChange, let receipt = snapshot.profile.developerSetup, frozen == nil, source == "none" else { return }
            previewLookup = receipt.reviewID.uuidString; await loadPreview()
        }
        .background {
            #if DEBUG
            if let acceptance { Color.clear.allowsHitTesting(false).onAppear {
                acceptance.terminalScreen = screen
                acceptance.bind("setup", action: { command in
                    switch command {
                    case .source(let value): source = value
                    case .profiles(let value): profiles = Set(value)
                    case .appearance(let value): appearance = ProvisioningAppearanceDraft(value)
                    case .trim(let value): if ProvisioningTrim.isAvailable(for: snapshot.profile.factory) { trimOptionalApps = value }
                    case .folder(let value): folder = value; invalidatePreview()
                    case .preview: Task { await plan() }
                    case .lookup(let id): previewLookup = id.uuidString; Task { await loadPreview() }
                    case .inspect: if let frozen, let task = frozen.tasks.first { Task { await inspectTask(frozen, task: task) } }
                    case .prepareApply: if let frozen { Task { await prepareReview(frozen) } }
                    case .grant(let sudo, let docker, let tasks): grantConsent = sudo; dockerConsent = docker; taskConsent = tasks
                    case .submit: if let frozen, let applyReview { Task { await submit(frozen, review: applyReview) } }
                    case .search(let value): search = value; matches = screen.search(value)
                    case .requestCancel: if workflow?.canCancel == true { confirmCancel = true }
                    case .confirmCancel: if confirmCancel { confirmCancel = false; cancelConfirmed() }
                    default: break
                    }
                }, snapshot: { ["trimAvailable": String(ProvisioningTrim.isAvailable(for: snapshot.profile.factory) && source != "none"), "trim": String(trimOptionalApps), "source": source, "preview": frozen?.id.uuidString ?? "", "review": applyReview?.reviewIdentity ?? "", "updateReviewed": String(applyReview?.systemUpdateRequired == true), "failure": String(failure != nil), "planning": String(planning), "inspected": String(inspectedTasks.count), "taskBytes": String(taskText?.utf8.count ?? 0), "grant": String(grantConsent), "taskConsent": String(taskConsent), "attempted": String(submissionAttempted), "execution": String(executionEnabled), "matches": matches.map(String.init) ?? "", "cancelPending": String(confirmCancel), "continuation": continuationMessage, "savedLog": String(showingSavedLog)] })
            } }
            #endif
        }
        .onDisappear { Task { await screen.detach() } }
    }
    private func cancelConfirmed() { if let workflow, workflow.canCancel { Task { await model.cancelSetup(workflow.id) } } }
    private var cancelPresentation: Binding<Bool> {
        #if DEBUG
        if acceptance != nil { return .constant(false) }
        #endif
        return $confirmCancel
    }
    private var taskPresentation: Binding<Bool> {
        #if DEBUG
        if acceptance != nil { return .constant(false) } // Inspect state without ordering a native sheet.
        #endif
        return $showingTask
    }
    private var actingService: (any ProvisioningWorkflowActing)? { model.setupService as? any ProvisioningWorkflowActing }
    @ViewBuilder private func workflowActions(_ workflow: ProvisioningWorkflowSnapshot) -> some View {
        if !workflow.availableActions.isEmpty || workflowActionReview?.workflowID == workflow.id {
            GroupedPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Reviewed workflow actions").font(Theme.sans(14, weight: .semibold))
                    ForEach(workflow.availableActions, id: \.self) { action in
                        HStack {
                            Text(action.explanation).font(Theme.sans(13)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Review " + action.title.lowercased() + "…") { Task { await prepareWorkflowAction(workflow, action: action) } }
                                .disabled(actingService?.executionEnabled != true || actionBusy)
                        }
                    }
                    if let review = workflowActionReview, review.workflowID == workflow.id {
                        Text(review.action.title).bold()
                        Text(review.action.explanation).font(Theme.sans(13))
                        DisclosureGroup("Details") {
                            Text("Session: " + review.sessionID.uuidString).font(.caption).textSelection(.enabled)
                            Text("Input fingerprint: " + review.inputDigest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text("Review: " + review.reviewIdentity).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        Toggle("I approve this exact " + review.action.title.lowercased() + " action for this guest and session.", isOn: $actionAcknowledged)
                            .disabled(actionBusy || actionAttempted)
                        Button(review.action.title) { Task { await performWorkflowAction(workflow, review: review) } }
                            .disabled(actingService?.executionEnabled != true || !actionAcknowledged || actionBusy || actionAttempted)
                    }
                    if actionAttempted { Text("Action submission was attempted. Inspect the workflow state. A new attempt needs a fresh explicit review.").font(.caption).foregroundStyle(.secondary) }
                    if actingService?.executionEnabled != true { Text("Workflow execution is unavailable in this build or service.").font(.caption).foregroundStyle(.secondary) }
                }.padding(20)
            }
        }
    }
    @MainActor private func prepareWorkflowAction(_ workflow: ProvisioningWorkflowSnapshot, action: ProvisioningWorkflowAction) async {
        guard let service = actingService, !actionBusy else { return }
        if actionRequested != action || actionAttempted || workflowActionReview != nil { actionRequestID = nil }
        let id = actionRequestID ?? UUID(); actionRequestID = id; actionRequested = action
        actionBusy = true; actionAcknowledged = false; workflowActionReview = nil; failure = nil
        defer { actionBusy = false }
        do {
            let review = try await service.prepareAction(workflow.id, action: action, reviewID: id)
            guard self.workflow?.id == workflow.id else { return }
            workflowActionReview = review; actionAttempted = false
        } catch { actionRequestID = nil; failure = "This workflow action could not be reviewed. Verify its current state, exact guest session and original helper ownership. No action was automatically submitted." }
    }
    @MainActor private func performWorkflowAction(_ workflow: ProvisioningWorkflowSnapshot, review: ProvisioningWorkflowActionReview) async {
        guard let service = actingService, !actionBusy, !actionAttempted, actionAcknowledged else { return }
        actionAttempted = true; actionBusy = true; failure = nil
        defer { actionBusy = false }
        do {
            _ = try await service.performAction(workflow.id, consent: .init(reviewID: review.id, action: review.action, reviewIdentity: review.reviewIdentity, acknowledged: true))
            workflowActionReview = nil; actionAcknowledged = false
        } catch { failure = "The action was not confirmed. Inspect the workflow state and cleanup requirement before preparing a fresh review. No automatic retry was made." }
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
    private var reviewingService: (any ProvisioningReviewing)? { model.setupService as? any ProvisioningReviewing }
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
    private var executionEnabled: Bool { reviewingService?.executionEnabled == true }
    private func invalidatePreview() {
        planRevision = UUID(); captureID = nil; frozen = nil; preview = nil; applyReview = nil
        grantConsent = false; dockerConsent = false; taskConsent = false; inspectedTasks.removeAll(); submissionAttempted = false; failure = nil
    }
    private func display(_ value: ProvisioningPlanPreview) throws {
        guard value.vmID == snapshot.id else { throw ProvisioningReviewFailure.invalid }
        frozen = value; captureID = value.id; applyReview = nil
        grantConsent = false; dockerConsent = false; taskConsent = false; inspectedTasks.removeAll(); submissionAttempted = false
        let document = try JSONSerialization.jsonObject(with: value.proposal)
        let readable = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        preview = String(decoding: readable, as: UTF8.self)
    }
    /// Plain steps for the review, from the frozen proposal and the prepared review only.
    private func runSteps(_ value: ProvisioningPlanPreview, review: ProvisioningApplyReview) -> [String] {
        var steps: [String] = []
        if review.systemUpdateRequired { steps.append("Updates Omarchy and system packages with Omarchy’s own updater.") }
        let names = ProvisioningReviewedProfilesView.names(value.proposal)
        steps.append(names.isEmpty ? "Applies the reviewed configuration." : "Installs " + names.joined(separator: " + ") + (review.dockerRootAccessRequired ? ", including Docker without sudo." : "."))
        let look = ProvisioningAppearanceSummary(proposal: value.proposal)
        if look.layoutIncluded || look.layoutRemoved || look.theme != nil {
            let layout = look.layoutExample?.title ?? (look.layoutIncluded ? "your custom layout" : look.layoutRemoved ? "Omarchy’s default layout" : nil)
            let theme = look.theme.map { $0.hasPrefix("https://github.com/") ? String($0.dropFirst(19)) + " theme" : $0 == "most-starred" ? "the most-starred theme" : $0 == "random" ? "a random theme" : $0 }
            steps.append("Applies " + [layout, theme].compactMap { $0 }.joined(separator: " and ") + " at the next desktop login.")
        }
        if !value.tasks.isEmpty { steps.append("Runs \(value.tasks.count) custom task\(value.tasks.count == 1 ? "" : "s") from this configuration.") }
        if review.persistentGrantRequired { steps.append("Uses temporary admin access while it runs; cleanup removes it.") }
        steps.append("Finishes with a restart and a configuration check, each reviewed before it runs.")
        return steps
    }
    private func consent(_ title: String, note: String, isOn: Binding<Bool>, warning: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.sans(13, weight: .medium)).foregroundStyle(warning ? Theme.amber : Theme.text)
                Text(note).font(Theme.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(warning ? Theme.amber.opacity(0.07) : Theme.ground))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(warning ? Theme.amber.opacity(0.45) : Theme.border))
    }
    private func reviewActions(_ value: ProvisioningPlanPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(value.tasks, id: \.name) { task in
                HStack {
                    Text(task.name).bold()
                    Spacer()
                    Button(inspectedTasks.contains(task.name) ? "Inspect again…" : "Inspect frozen task…") { Task { await inspectTask(value, task: task) } }.accessibilityIdentifier("setup.inspect").disabled(inspectingTask || submitting)
                }
            }
            if let review = applyReview {
                Text("this run").font(Theme.mono(13, weight: .medium)).foregroundStyle(Theme.green).padding(.top, 4)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(runSteps(value, review: review).enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)").font(Theme.mono(12)).foregroundStyle(Theme.label).frame(width: 16, alignment: .leading)
                            Text(step).font(Theme.sans(13)).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    if review.persistentGrantRequired {
                        consent("Allow temporary admin access while setup runs", note: "A sudo grant in this VM across setup steps, until cleanup revokes it. Unconfirmed cleanup keeps the run marked Cleanup required.", isOn: $grantConsent)
                    }
                    if review.dockerRootAccessRequired {
                        consent("Allow Docker without sudo", note: "The guest owner gets root-equivalent access inside this VM. It stays after setup.", isOn: $dockerConsent, warning: true)
                    }
                    if review.taskTrustIdentity != nil {
                        consent("Allow custom tasks from this configuration", note: value.tasks.allSatisfy { inspectedTasks.contains($0.name) }
                                ? "Custom Ansible tasks can run on this Mac and in the VM, using credentials available to Ansible. Covers the reviewed configuration, task files and assets."
                                : "Inspect each custom task above before allowing it.", isOn: $taskConsent, warning: true)
                            .disabled(!value.tasks.allSatisfy { inspectedTasks.contains($0.name) })
                    }
                }.padding(.top, 6)
                HStack {
                    Spacer()
                    Button("Run setup") { Task { await submit(value, review: review) } }
                        .buttonStyle(.primaryAction)
                        .accessibilityIdentifier("setup.apply")
                        .disabled(!canSubmit(value, review: review))
                }
            } else {
                Button(preparingApply ? "Preparing the review…" : "Review this run…") { Task { await prepareReview(value) } }
                    .accessibilityIdentifier("setup.prepare-apply")
                    .disabled(!executionEnabled || preparingApply || submitting)
            }
            if submissionAttempted { Text("Submission was attempted. Inspect the workflow state before taking another action; this view will not repeat it automatically.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    @MainActor private func plan() async {
        guard let service = reviewingService else { failure = "Setup coordination is unavailable."; return }
        guard !planning, appearance.failure == nil, !preparingApply, !submitting, applyReview == nil, source != "none", source != "local" || folder != nil, source != "bundled" || !profiles.isEmpty else { return }
        planning = true; failure = nil; preview = nil
        let revision = UUID(); planRevision = revision
        let id = frozen == nil ? (captureID ?? UUID()) : UUID(); captureID = id; frozen = nil
        let selection: ProvisioningSetupSource
        if source == "local", let folder { selection = .init(directory: folder.path, profiles: profiles.isEmpty ? nil : profiles.sorted(), trimOptionalApps: ProvisioningTrim.isAvailable(for: snapshot.profile.factory) && trimOptionalApps, appearance: appearance.selection) }
        else { selection = .init(profiles: profiles.sorted(), trimOptionalApps: ProvisioningTrim.isAvailable(for: snapshot.profile.factory) && trimOptionalApps, appearance: appearance.selection) }
        defer { planning = false }
        do {
            let value = try await service.preview(id: id, vmID: snapshot.id, source: selection)
            guard revision == planRevision else { return }; try display(value)
        } catch ProvisioningReviewFailure.conflictingProfiles { guard revision == planRevision else { return }; failure = "These profiles have conflicting settings. Choose a compatible combination or resolve the settings in your local vm.yml."
        } catch { guard revision == planRevision else { return }; failure = ProvisioningAppearance.failureMessage(error) ?? "This setup could not be frozen. Check its manifest, files, package admission and private preview quota." }
    }
    @MainActor private func loadPreview() async {
        guard let service = reviewingService, let id = UUID(uuidString: previewLookup) else { return }
        planning = true; failure = nil; let revision = planRevision; defer { planning = false }
        do { let value = try await service.preview(id); guard revision == planRevision else { return }; try display(value) }
        catch { failure = "The saved preview is unavailable. Existing job results are shown below. Choose a source to review a new setup." }
    }
    @MainActor private func inspectTask(_ value: ProvisioningPlanPreview, task: ProvisioningTaskReview) async {
        guard let service = reviewingService else { return }
        inspectingTask = true; defer { inspectingTask = false }
        do {
            var data = Data()
            while true {
                let chunk = try await service.taskSource(value.id, name: task.name, offset: data.count)
                guard chunk.sha256 == task.sha256, chunk.total <= 64 * 1024, chunk.offset == data.count else { throw ProvisioningReviewFailure.invalid }
                data += chunk.bytes
                if data.count == chunk.total { break }
            }
            guard frozen?.id == value.id, let text = String(data: data, encoding: .utf8) else { throw ProvisioningReviewFailure.changed }
            taskText = text; showingTask = true; inspectedTasks.insert(task.name)
        } catch { failure = "The complete frozen task could not be displayed. Native review is limited to 64 KiB per task; larger files need explicit CLI inspection." }
    }
    @MainActor private func prepareReview(_ value: ProvisioningPlanPreview) async {
        guard executionEnabled, !preparingApply, !submitting else { return }
        guard let service = reviewingService else { return }
        preparingApply = true; failure = nil; defer { preparingApply = false }
        do {
            let review = try await service.prepareApply(value.id)
            guard frozen?.id == value.id else { return }; applyReview = review
            grantConsent = false; dockerConsent = false; taskConsent = false
        } catch { failure = "Apply review is unavailable. Execution must be enabled and the exact guest session, SSH identity and dependencies must be admitted. Inspect any preparation workflow before retrying." }
    }
    private func canSubmit(_ value: ProvisioningPlanPreview, review: ProvisioningApplyReview) -> Bool {
        executionEnabled && !submitting && !submissionAttempted && grantConsent &&
            (!review.dockerRootAccessRequired || dockerConsent) &&
            (review.taskTrustIdentity == nil || (taskConsent && value.tasks.allSatisfy { inspectedTasks.contains($0.name) }))
    }
    @MainActor private func submit(_ value: ProvisioningPlanPreview, review: ProvisioningApplyReview) async {
        guard let service = reviewingService, canSubmit(value, review: review) else { return }
        submissionAttempted = true; submitting = true; failure = nil; defer { submitting = false }
        do {
            _ = try await service.apply(value.id, consent: .init(reviewIdentity: review.reviewIdentity,
                taskTrustIdentity: taskConsent ? review.taskTrustIdentity : nil, persistentGrantAcknowledged: grantConsent, dockerRootAccessAcknowledged: dockerConsent))
            applyReview = nil
        } catch { failure = "Submission was not confirmed. Inspect its workflow state and exact hashes before any explicit retry. No automatic retry was made." }
    }
}
