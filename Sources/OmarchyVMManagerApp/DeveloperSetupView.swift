import AppKit
import OmarchyProvisioningTerminalUI
import OmarchyVMManagerCore
import SwiftUI
import UniformTypeIdentifiers

/// Offline selection and review never creates a VM or authorizes tasks. The
/// running-job pane consumes the same service used by the separate CLI socket.
struct DeveloperSetupView: View {
    @ObservedObject var model: AppModel
    let snapshot: VMSnapshot
    @StateObject private var screen = ProvisioningTerminalScreen()
    @State private var source = "none"
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
    @State private var planning = false
    @State private var planRevision = UUID()
    @State private var failure: String?
    @State private var expanded = false
    @State private var search = ""
    @State private var matches: Int?
    @State private var confirmCancel = false
    @State private var tools = false
    private var workflows: [ProvisioningWorkflowSnapshot] { model.setupWorkflows.filter { $0.vmID == snapshot.id } }
    private var workflow: ProvisioningWorkflowSnapshot? {
        workflows.first { $0.id == selectedWorkflow } ?? workflows.first { $0.canCancel || $0.cleanupRequired } ?? workflows.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Developer setup").font(.largeTitle.bold())
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
                            ForEach(BundledProvisioning.presets, id: \.self) { Text($0).tag($0) }
                            Text("Local setup folder").tag("local")
                        }.frame(maxWidth: 340).disabled(planning || preparingApply || submitting || applyReview != nil)
                        if source == "local" { Button("Choose folder…") { choosingFolder = true }.disabled(planning || preparingApply || submitting || applyReview != nil) }
                        Spacer()
                        Button(frozen == nil ? "Preview plan" : "Refresh preview") { Task { await plan() } }.disabled(source == "none" || planning || preparingApply || submitting || applyReview != nil || (source == "local" && folder == nil))
                        if planning { ProgressView().controlSize(.small) }
                    }
                    if let folder, source == "local" { Text(folder.lastPathComponent + "/vm.yml").font(.caption).foregroundStyle(.secondary) }
                    Text("Preview software, removals, update policy, dotfiles and restart requirements before applying. Custom tasks require separate trust tied to the frozen inputs.").font(.callout).foregroundStyle(.secondary)
                    Text("Setup execution is disabled pending guest acceptance. A preview does not change this VM or its resource settings.").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("Frozen preview UUID from CLI", text: $previewLookup).textFieldStyle(.roundedBorder)
                        Button("Open preview") { Task { await loadPreview() } }.disabled(UUID(uuidString: previewLookup) == nil || planning || preparingApply || submitting || applyReview != nil)
                    }
                    if let frozen { reviewActions(frozen) }
                }.padding(20)
            }
            if let preview {
                DisclosureGroup("Reviewed proposal · offline") {
                    ScrollView([.horizontal, .vertical]) { Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(12) }.frame(height: 220)
                }
            }
            if let failure { Text(failure).foregroundStyle(.orange) }
            if workflows.count > 1 {
                Picker("Workflow", selection: Binding(get: { workflow?.id }, set: { selectedWorkflow = $0 })) {
                    ForEach(workflows, id: \.id) { row in Text(row.title + " · " + row.id.uuidString.prefix(8)).tag(Optional(row.id)) }
                }
            }
            if let workflow {
                Text(workflow.title).font(.title2.bold())
                HStack(spacing: 14) {
                    ForEach(ProvisioningSetupPhase.allCases, id: \.self) { phase in
                        Label(phase.rawValue, systemImage: currentPhase(workflow) == phase ? "circle.inset.filled" : "circle").foregroundStyle(currentPhase(workflow) == phase ? Color.accentColor : Color.secondary)
                    }
                }.accessibilityLabel("Setup stages. Current workflow: " + workflow.title)
                if workflow.cleanupRequired { Label("Cleanup has not been confirmed. Recovery must verify the original guest and authorization state.", systemImage: "exclamationmark.shield").foregroundStyle(.orange) }
                terminal(height: expanded ? 640 : 360)
                HStack {
                    Text("You can leave this page. Setup will continue.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel Setup…") { confirmCancel = true }.disabled(!workflow.canCancel)
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
                Text("No setup job for this guest. Live output will appear here when an admitted job is available.").foregroundStyle(.secondary).font(.callout)
            }
        }
        .onChange(of: source) { _, _ in invalidatePreview() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { invalidatePreview(); folder = url }
        }
        .sheet(isPresented: $showingTask) {
            VStack(alignment: .leading) {
                Text("Frozen task source").font(.title2.bold())
                ScrollView([.horizontal, .vertical]) { Text(taskText ?? "Source unavailable").font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(12) }
                Button("Done") { showingTask = false }
            }.padding(20).frame(width: 760, height: 560)
        }
        .sheet(isPresented: $tools) { ScrollView { ProvisioningToolsView().padding(24) }.frame(width: 680, height: 640) }
        .confirmationDialog("Cancel setup and perform its cleanup?", isPresented: $confirmCancel) {
            Button("Cancel Setup", role: .destructive) { if let workflow { Task { await model.cancelSetup(workflow.id) } } }
        } message: { Text("Cleanup may still need verification. Closing this page only detaches the terminal.") }
        .task(id: workflow?.id) {
            if let workflow, let service = model.setupService { await screen.attach(service: service, workflowID: workflow.id) }
        }
        .onDisappear { Task { await screen.detach() } }
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
            HStack {
                Circle().fill(screen.connected ? .green : .gray).frame(width: 8, height: 8)
                Text("Live terminal").bold()
                Spacer()
                Button("A−") { screen.fontSize -= 1 }.disabled(screen.fontSize <= 10)
                Button("A+") { screen.fontSize += 1 }.disabled(screen.fontSize >= 24)
                Toggle("Follow output", isOn: $screen.follow).toggleStyle(.switch).controlSize(.small)
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.help("Expand terminal")
            }.padding(12).background(.quaternary)
            HStack {
                TextField("Search terminal", text: $search).textFieldStyle(.roundedBorder).onSubmit { matches = screen.search(search) }
                if let matches { Text("\(matches) matching lines").font(.caption) }
                if !screen.connected, let workflow, let service = model.setupService {
                    Button("Reconnect") { Task { await screen.attach(service: service, workflowID: workflow.id) } }
                }
                Button("Jump to latest") { screen.jumpToLatest() }
                if screen.ownsInput { Button("Release input") { Task { await screen.releaseInput() } } }
                else { Button("Take input") { Task { await screen.takeInput() } }.disabled(!screen.connected) }
            }.padding(8)
            ProvisioningNativeTerminal(screen: screen).frame(height: height).clipped()
            HStack {
                Text(screen.message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if screen.acceptsInput { Label("Interactive input available", systemImage: "keyboard").font(.caption) }
            }.padding(10)
        }.background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private var reviewingService: (any ProvisioningReviewing)? { model.setupService as? any ProvisioningReviewing }
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
    private func reviewActions(_ value: ProvisioningPlanPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Frozen preview: " + value.id.uuidString).font(.caption).textSelection(.enabled)
            Text("Inputs: " + value.inputDigest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            ForEach(value.tasks, id: \.name) { task in
                HStack {
                    Text(task.name).bold()
                    Text(String(task.sha256.prefix(12))).font(.system(.caption, design: .monospaced))
                    Spacer()
                    Button(inspectedTasks.contains(task.name) ? "Inspect again…" : "Inspect frozen task…") { Task { await inspectTask(value, task: task) } }.disabled(inspectingTask || submitting)
                }
            }
            if let review = applyReview {
                Text("Review: " + review.reviewIdentity).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Toggle("I approve a persistent sudo grant for this setup until its cleanup is confirmed.", isOn: $grantConsent)
                if review.dockerRootAccessRequired { Toggle("I approve Docker access equivalent to root and the separate restart review.", isOn: $dockerConsent) }
                if let trust = review.taskTrustIdentity {
                    Text("Custom Ansible can run on this Mac, use controller credentials and delegate work. Trust covers all frozen input files and referenced tasks/assets; it is separate from Apply approval.").font(.callout)
                    Text("Task trust: " + trust).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Toggle("I explicitly trust these custom tasks and the complete frozen input snapshot.", isOn: $taskConsent)
                        .disabled(!value.tasks.allSatisfy { inspectedTasks.contains($0.name) })
                }
                Button("Apply reviewed setup") { Task { await submit(value, review: review) } }
                    .disabled(!executionEnabled || submitting || submissionAttempted || !grantConsent || (review.dockerRootAccessRequired && !dockerConsent) || (review.taskTrustIdentity != nil && !taskConsent))
            } else {
                Button(preparingApply ? "Preparing target review…" : "Review apply…") { Task { await prepareReview(value) } }
                    .disabled(!executionEnabled || preparingApply || submitting)
            }
            if submissionAttempted { Text("Submission was attempted. Inspect the workflow state before taking another action; this view will not repeat it automatically.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    @MainActor private func plan() async {
        guard let service = reviewingService else { failure = "Setup coordination is unavailable."; return }
        planning = true; failure = nil; preview = nil
        let revision = UUID(); planRevision = revision
        let id = frozen == nil ? (captureID ?? UUID()) : UUID(); captureID = id; frozen = nil
        let selection: ProvisioningSetupSource
        if source == "local", let folder { selection = .init(directory: folder.standardizedFileURL.path) }
        else { selection = .init(preset: source) }
        defer { planning = false }
        do {
            let value = try await service.preview(id: id, vmID: snapshot.id, source: selection)
            guard revision == planRevision else { return }; try display(value)
        } catch { guard revision == planRevision else { return }; failure = "This setup could not be frozen. Check its manifest, files, package admission and private preview quota." }
    }
    @MainActor private func loadPreview() async {
        guard let service = reviewingService, let id = UUID(uuidString: previewLookup) else { return }
        planning = true; failure = nil; defer { planning = false }
        do { try display(try await service.preview(id)) }
        catch { failure = "This frozen preview is unavailable or belongs to another guest. It cannot be restored from a saved identifier after manager restart." }
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
        guard let service = reviewingService else { return }
        preparingApply = true; failure = nil; defer { preparingApply = false }
        do {
            let review = try await service.prepareApply(value.id)
            guard frozen?.id == value.id else { return }; applyReview = review
            grantConsent = false; dockerConsent = false; taskConsent = false
        } catch { failure = "Apply review is unavailable. Execution must be enabled and the exact guest session, SSH identity and dependencies must be admitted. Inspect any preparation workflow before retrying." }
    }
    @MainActor private func submit(_ value: ProvisioningPlanPreview, review: ProvisioningApplyReview) async {
        guard let service = reviewingService, !submissionAttempted else { return }
        submissionAttempted = true; submitting = true; failure = nil; defer { submitting = false }
        do {
            _ = try await service.apply(value.id, consent: .init(reviewIdentity: review.reviewIdentity,
                taskTrustIdentity: taskConsent ? review.taskTrustIdentity : nil, persistentGrantAcknowledged: grantConsent, dockerRootAccessAcknowledged: dockerConsent))
            applyReview = nil
        } catch { failure = "Submission was not confirmed. Inspect its workflow state and exact hashes before any explicit retry. No automatic retry was made." }
    }
}
