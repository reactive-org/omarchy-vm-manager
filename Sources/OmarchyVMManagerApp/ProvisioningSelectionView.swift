import OmarchyVMManagerCore
import SwiftUI
import UniformTypeIdentifiers

struct ProvisioningFeatureSelectionView: View {
    @Binding var selection: ProvisioningFeatureSelection
    @State private var expanded: Bool
    init(selection: Binding<ProvisioningFeatureSelection>, initiallyExpanded: Bool = false) {
        _selection = selection; _expanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        DisclosureGroup("Feature choices", isExpanded: $expanded) {
            ForEach(ProvisioningCommonFeature.allCases, id: \.self) { feature in
                Picker(feature.title, selection: Binding(get: { selection.choice(feature) }, set: { selection = selection.setting(feature, to: $0) })) {
                    ForEach(ProvisioningFeatureChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            Text("Use source keeps the preset or manifest choice. The shared planner resolves profiles, dependencies and conflicts. Disabling a feature does not remove installed packages. Custom features and options stay in the source manifest.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// New VM only: review and save a selection without provisioning or changing
/// the resource and factory fields owned by the parent form.
struct NewVMSetupSelectionView: View {
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @ObservedObject var model: AppModel
    @Binding var consent: ProvisioningCreationConsent?
    @Binding var ready: Bool
    @State private var source = "none"
    @State private var folder: URL?
    @State private var choosingFolder = false
    @State private var features = ProvisioningFeatureSelection()
    @State private var review: ProvisioningCreationReview?
    @State private var requestID: UUID?
    @State private var revision = UUID()
    @State private var busy = false
    @State private var acknowledged = false
    @State private var failure: String?
    var body: some View {
        Section("Developer setup") {
            Picker("Source", selection: $source) {
                Text("None").tag("none")
                ForEach(BundledProvisioning.presets, id: \.self) { Text($0).tag($0) }
                Text("Local setup folder").tag("local")
            }.disabled(busy)
            if source != "none" {
                if source == "local" {
                    Button("Choose setup folder…") { choosingFolder = true }.disabled(busy)
                    if let folder { Text(folder.lastPathComponent + "/vm.yml").font(.caption).foregroundStyle(.secondary) }
                }
                ProvisioningFeatureSelectionView(selection: $features).disabled(busy)
                Button(busy ? "Freezing selection…" : review == nil ? "Review setup selection" : "Refresh setup review") { Task { await prepare() } }
                    .accessibilityIdentifier("new-vm.review")
                    .disabled(busy || (source == "local" && folder == nil) || model.setupService == nil)
                if let review {
                    Text("Review: " + review.id.uuidString).font(.caption).textSelection(.enabled)
                    Text("Inputs: " + review.inputDigest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    DisclosureGroup("Exact frozen proposal") {
                        ScrollView([.horizontal, .vertical]) {
                            Text(readable(review.proposal)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(8)
                        }.frame(height: 180)
                    }
                    Toggle("Save this exact selection with the new VM. This does not authorize setup execution or custom tasks.", isOn: $acknowledged)
                }
                Text("The selection is copied into private manager storage. VM resources and factory come from this form. Creation does not start setup. Execution remains disabled pending guest acceptance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }
        .background {
            #if DEBUG
            if let acceptance { Color.clear.allowsHitTesting(false).onAppear {
                acceptance.bind("selection", action: { command in
                    switch command {
                    case .source(let value): source = value
                    case .feature(let feature, let choice): features = features.setting(feature, to: choice)
                    case .folder(let value): folder = value; invalidate()
                    case .preview: Task { await prepare() }
                    case .acknowledge(let value): acknowledged = value
                    default: break
                    }
                }, snapshot: { ["source": source, "review": review?.id.uuidString ?? "", "acknowledged": String(acknowledged), "busy": String(busy), "ready": String(ready), "failure": String(failure != nil)] })
            } }
            #endif
        }
        .onChange(of: source) { _, _ in invalidate() }
        .onChange(of: features) { _, _ in invalidate() }
        .onChange(of: acknowledged) { _, _ in publish() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folder = url; invalidate() }
        }
    }
    private func readable(_ bytes: Data) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: bytes), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "Proposal unavailable" }
        return String(decoding: data, as: UTF8.self)
    }
    private func invalidate() { revision = UUID(); review = nil; requestID = nil; acknowledged = false; failure = nil; publish() }
    private func publish() {
        consent = review.flatMap { acknowledged ? .init(reviewID: $0.id, reviewIdentity: $0.reviewIdentity, acknowledged: true) : nil }
        ready = source == "none" || consent != nil
    }
    @MainActor private func prepare() async {
        guard !busy, source != "none", source != "local" || folder != nil else { return }
        guard let service = model.setupService as? any ProvisioningCreationPlanning else { failure = "Setup coordination is unavailable."; return }
        let id = review == nil ? (requestID ?? UUID()) : UUID(), stamp = revision
        requestID = id; review = nil; acknowledged = false; failure = nil; busy = true; publish()
        defer { busy = false }
        let edits = features.isEmpty ? nil : features
        let selection: ProvisioningSetupSource
        if source == "local", let folder { selection = .init(directory: folder.path, features: edits) }
        else { selection = .init(preset: source, features: edits) }
        do { let value = try await service.prepareCreation(id: id, source: selection); guard stamp == revision else { return }; review = value; publish() }
        catch { guard stamp == revision else { return }; failure = "The selection could not be frozen. Check the manifest, feature dependencies, referenced files and private preview quota. No VM was created." }
    }
}
