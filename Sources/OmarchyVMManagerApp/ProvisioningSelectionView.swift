import OmarchyVMManagerCore
import SwiftUI
import UniformTypeIdentifiers

enum ProvisioningSetupHelp {
    static let source = "Choose bundled configuration or a local folder containing vm.yml. Select profiles separately below; folder profiles and settings stay included. Selected inputs are copied into private manager storage when saved."
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
                .font(Theme.note).foregroundStyle(.secondary)
        }
    }
}

enum NewVMSetupBlocker: Equatable {
    case unavailable, folderRequired, profilesRequired
    case appearance(String)

    var message: String {
        switch self {
        case .unavailable: "Developer setup is unavailable. Choose Source: None to create this VM without it."
        case .folderRequired: "Choose a local setup folder in Developer setup."
        case .profilesRequired: "Select at least one profile in Developer setup."
        case .appearance(let reason): "Theme & layout: " + reason
        }
    }
}

/// New VM only: edit a draft without capturing inputs, provisioning or changing
/// the resource and factory fields owned by the parent form.
struct NewVMSetupSelectionView: View {
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @ObservedObject var model: AppModel
    @Binding var factory: String
    @State private var trimOptionalApps = false
    @State private var appearance = ProvisioningAppearanceDraft()
    @Binding var selection: ProvisioningSetupSource?
    @Binding var blocker: NewVMSetupBlocker?
    @State private var source = "none"
    @State private var folder: URL?
    @State private var choosingFolder = false
    @State private var profiles: Set<String> = ["developer"]
    private var selectionBlocker: NewVMSetupBlocker? {
        guard source != "none" else { return nil }
        if !(model.setupService is any ProvisioningCreationPlanning) { return .unavailable }
        if source == "local", folder == nil { return .folderRequired }
        if source == "bundled", profiles.isEmpty { return .profilesRequired }
        if let reason = appearance.failure { return .appearance(reason) }
        return nil
    }
    private var draft: ProvisioningSetupSource? {
        guard source != "none", selectionBlocker == nil else { return nil }
        if source == "local", let folder {
            return .init(directory: folder.path, profiles: profiles.isEmpty ? nil : profiles.sorted(),
                         trimOptionalApps: factory == "official" && trimOptionalApps, appearance: appearance.selection)
        }
        return .init(profiles: profiles.sorted(), trimOptionalApps: factory == "official" && trimOptionalApps, appearance: appearance.selection)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SpecRow("source") {
                Picker("Source", selection: $source) {
                    Text("None").tag("none")
                    Text("Bundled configuration").tag("bundled")
                    Text("Local setup folder").tag("local")
                }.labelsHidden().frame(maxWidth: 240).help(ProvisioningSetupHelp.source)
            }
            if source != "none" {
                if source == "local" {
                    SpecRow("folder", note: folder.map { $0.lastPathComponent + "/vm.yml" }) {
                        Button("Choose setup folder…") { choosingFolder = true }
                    }
                }
                ProvisioningProfileSelectionView(selection: $profiles, localSource: source == "local")
                if factory == "official" { ProvisioningTrimSelectionView(selection: $trimOptionalApps) }
                ProvisioningAppearanceSelectionView(draft: $appearance)
                SpecNote("Create VM validates and saves these selections with the new VM. It does not start setup. Execution and custom tasks require separate approval.")
            }
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
                    case .folder(let value): folder = value; publish()
                    default: break
                    }
                }, snapshot: { ["trimAvailable": String(factory == "official" && source != "none"), "trim": String(trimOptionalApps), "source": source, "profiles": profiles.sorted().joined(separator: ","), "theme": draft?.appearance?.theme ?? "", "layout": draft?.appearance?.layoutExample?.rawValue ?? "", "ready": String(selectionBlocker == nil)] })
            } }
            #endif
        }
        .onChange(of: source) { _, _ in profiles = source == "bundled" ? ["developer"] : []; publish() }
        .onChange(of: factory) { _, _ in trimOptionalApps = false; publish() }
        .onChange(of: appearance) { _, _ in publish() }
        .onChange(of: trimOptionalApps) { _, _ in publish() }
        .onChange(of: profiles) { _, _ in publish() }
        .onChange(of: selectionBlocker, initial: true) { _, _ in publish() }
        .onChange(of: draft) { _, _ in publish() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folder = url; publish() }
        }
    }
    private func publish() {
        selection = draft
        blocker = selectionBlocker
    }
}
