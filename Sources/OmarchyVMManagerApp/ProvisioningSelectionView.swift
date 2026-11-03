import OmarchyVMManagerCore
import SwiftUI
import UniformTypeIdentifiers

enum ProvisioningSetupHelp {
    static let source = "Choose bundled configuration or a local folder containing vm.yml. Select profiles separately below; folder profiles and settings stay included. Review setup saves a copy of the selected inputs."
}

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
    @Binding var factory: String
    @State private var trimOptionalApps = false
    @State private var appearance = ProvisioningAppearanceDraft()
    @Binding var consent: ProvisioningCreationConsent?
    @Binding var ready: Bool
    @State private var source = "none"
    @State private var folder: URL?
    @State private var choosingFolder = false
    @State private var profiles: Set<String> = ["developer"]
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
                Text("Bundled configuration").tag("bundled")
                Text("Local setup folder").tag("local")
            }.help(ProvisioningSetupHelp.source).disabled(busy)
            if source != "none" {
                if source == "local" {
                    Button("Choose setup folder…") { choosingFolder = true }.disabled(busy)
                    if let folder { Text(folder.lastPathComponent + "/vm.yml").font(.caption).foregroundStyle(.secondary) }
                }
                ProvisioningProfileSelectionView(selection: $profiles, localSource: source == "local").disabled(busy)
                if factory == "official" { ProvisioningTrimSelectionView(selection: $trimOptionalApps).disabled(busy) }
                ProvisioningAppearanceSelectionView(draft: $appearance).disabled(busy)
                Button(busy ? "Preparing preview…" : review == nil ? "Review setup" : "Update preview") { Task { await prepare() } }
                    .accessibilityIdentifier("new-vm.review")
                    .disabled(busy || (source == "local" && folder == nil) || (source == "bundled" && profiles.isEmpty) || appearance.failure != nil || model.setupService == nil)
                if let review {
                    ProvisioningReviewedProfilesView(proposal: review.proposal)
                    ProvisioningReviewedTrimView(proposal: review.proposal)
                    ProvisioningReviewedAppearanceView(proposal: review.proposal)
                    DisclosureGroup("Details") {
                        Text("Review ID: " + review.id.uuidString).font(.caption).textSelection(.enabled)
                        Text("Input fingerprint: " + review.inputDigest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("Exact frozen proposal").font(.caption.bold())
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
                    case .profiles(let value): profiles = Set(value)
                    case .appearance(let value): appearance = ProvisioningAppearanceDraft(value)
                    case .trim(let value): if factory == "official" { trimOptionalApps = value }
                    case .folder(let value): folder = value; invalidate()
                    case .preview: Task { await prepare() }
                    case .acknowledge(let value): acknowledged = value
                    default: break
                    }
                }, snapshot: { ["trimAvailable": String(factory == "official" && source != "none"), "trim": String(trimOptionalApps), "source": source, "review": review?.id.uuidString ?? "", "acknowledged": String(acknowledged), "busy": String(busy), "ready": String(ready), "failure": String(failure != nil)] })
            } }
            #endif
        }
        .onChange(of: source) { _, _ in profiles = source == "bundled" ? ["developer"] : []; invalidate() }
        .onChange(of: factory) { _, _ in trimOptionalApps = false; invalidate() }
        .onChange(of: appearance) { _, _ in invalidate() }
        .onChange(of: trimOptionalApps) { _, _ in invalidate() }
        .onChange(of: profiles) { _, _ in invalidate() }
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
        guard !busy, appearance.failure == nil, source != "none", source != "local" || folder != nil, source != "bundled" || !profiles.isEmpty else { return }
        guard let service = model.setupService as? any ProvisioningCreationPlanning else { failure = "Setup coordination is unavailable."; return }
        let id = review == nil ? (requestID ?? UUID()) : UUID(), stamp = revision
        requestID = id; review = nil; acknowledged = false; failure = nil; busy = true; publish()
        defer { busy = false }
        let selection: ProvisioningSetupSource
        if source == "local", let folder { selection = .init(directory: folder.path, profiles: profiles.isEmpty ? nil : profiles.sorted(), trimOptionalApps: factory == "official" && trimOptionalApps, appearance: appearance.selection) }
        else { selection = .init(profiles: profiles.sorted(), trimOptionalApps: factory == "official" && trimOptionalApps, appearance: appearance.selection) }
        do { let value = try await service.prepareCreation(id: id, source: selection); guard stamp == revision else { return }; review = value; publish() }
        catch ProvisioningReviewFailure.conflictingProfiles { guard stamp == revision else { return }; failure = "These profiles have conflicting settings. Choose a compatible combination or resolve the settings in a local vm.yml." }
        catch { guard stamp == revision else { return }; failure = ProvisioningAppearance.failureMessage(error) ?? "The selection could not be frozen. Check the manifest, feature dependencies, referenced files and private preview quota. No VM was created." }
    }
}
