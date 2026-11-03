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
                        }.frame(maxWidth: 340)
                        if source == "local" { Button("Choose folder…") { choosingFolder = true } }
                        Spacer()
                        Button("Preview plan") { Task { await plan() } }.disabled(source == "none" || planning || (source == "local" && folder == nil))
                        if planning { ProgressView().controlSize(.small) }
                    }
                    if let folder, source == "local" { Text(folder.lastPathComponent + "/vm.yml").font(.caption).foregroundStyle(.secondary) }
                    Text("Preview software, removals, update policy, dotfiles and restart requirements before applying. Custom tasks require separate trust tied to the frozen inputs.").font(.callout).foregroundStyle(.secondary)
                    Text("Setup execution is disabled pending guest acceptance. A preview does not change this VM or its resource settings.").font(.callout).foregroundStyle(.secondary)
                    Button("Apply reviewed setup…") { }.disabled(true)
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
        .onChange(of: source) { _, _ in planRevision = UUID(); preview = nil; failure = nil }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { planRevision = UUID(); folder = url; preview = nil }
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
    @MainActor private func plan() async {
        planning = true; failure = nil; preview = nil
        let revision = UUID(); planRevision = revision
        let source = source, folder = folder
        let layout = ProvisioningPackageLayout(contents: Bundle.main.bundleURL.appendingPathComponent("Contents"))
        defer { planning = false }
        do {
            let data = try await Task.detached {
                if source == "local", let folder { return try BundledProvisioning.plan(repository: folder, layout: layout) }
                return try BundledProvisioning.plan(preset: source, layout: layout)
            }.value
            guard revision == planRevision else { return }
            let document = try JSONSerialization.jsonObject(with: data)
            let readable = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            preview = String(decoding: readable, as: UTF8.self)
        } catch { guard revision == planRevision else { return }; failure = "This setup could not be planned. Check the manifest, its source files and bundled package admission." }
    }
}
