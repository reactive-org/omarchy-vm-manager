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
    case layout(String)
    case appearance(String)

    var message: String {
        switch self {
        case .unavailable: "Developer setup is unavailable. Choose Source: None to create this VM without it."
        case .folderRequired: "Choose a local setup folder in Customise."
        case .profilesRequired: "Select at least one profile in Customise."
        case .layout(let reason): "Layout: " + reason
        case .appearance(let reason): "Theme: " + reason
        }
    }
    /// The New VM pane that resolves this blocker.
    var isLayout: Bool { if case .layout = self { true } else { false } }
}

/// The New VM setup choices shared by the Layout and Customise panes. A draft only:
/// nothing is captured, frozen or provisioned until Create.
struct NewVMSetupDraft: Equatable {
    var source = "none"
    var folder: URL?
    var profiles: Set<String> = ["developer"]
    var trimOptionalApps = false
    var appearance = ProvisioningAppearanceDraft()

    /// A layout only applies when setup runs, so choosing one turns setup on with the
    /// Developer profile. The saved desktop default's theme comes with it; the chosen
    /// layout wins over the default's layout.
    mutating func turnOnForLayout(defaults: ProvisioningAppearanceSelection?) {
        guard source == "none" else { return }
        source = "bundled"; profiles = ["developer"]
        guard let defaults, appearance.themeChoice == .source else { return }
        let saved = ProvisioningAppearanceDraft(defaults)
        appearance.themeChoice = saved.themeChoice; appearance.theme = saved.theme; appearance.minimumStars = saved.minimumStars
    }
    /// Turning setup on from Customise starts from the saved desktop default, unless a
    /// layout or theme was already chosen.
    mutating func sourceChanged(from old: String, defaults: ProvisioningAppearanceSelection?) {
        profiles = source == "bundled" ? ["developer"] : []
        if old == "none", source != "none", appearance == ProvisioningAppearanceDraft(), let defaults {
            appearance = ProvisioningAppearanceDraft(defaults)
        }
    }
    func blocker(planning: Bool) -> NewVMSetupBlocker? {
        guard source != "none" else { return nil }
        if !planning { return .unavailable }
        if source == "local", folder == nil { return .folderRequired }
        if source == "bundled", profiles.isEmpty { return .profilesRequired }
        if let reason = appearance.layoutFailure { return .layout(reason) }
        if let reason = appearance.failure { return .appearance(reason) }
        return nil
    }
    func selection(factory: String, planning: Bool) -> ProvisioningSetupSource? {
        guard source != "none", blocker(planning: planning) == nil else { return nil }
        let trim = factory == "official" && trimOptionalApps
        if source == "local", let folder {
            return .init(directory: folder.path, profiles: profiles.isEmpty ? nil : profiles.sorted(), trimOptionalApps: trim, appearance: appearance.selection)
        }
        return .init(profiles: profiles.sorted(), trimOptionalApps: trim, appearance: appearance.selection)
    }
}

/// New VM's Layout pane: the layout cards only. Picking a layout example or custom
/// file while setup is off turns setup on, because a layout only applies when it runs.
struct NewVMLayoutSelectionView: View {
    @ObservedObject var model: AppModel
    @Binding var draft: NewVMSetupDraft
    @State private var choosingLayout = false
    private var planning: Bool { model.setupService is any ProvisioningCreationPlanning }
    private var layout: Binding<ProvisioningAppearanceDraft> {
        Binding(get: { draft.appearance }, set: { value in
            let chosen = value.layoutMode == "example" || value.layoutMode == "file"
            let changed = value.layoutMode != draft.appearance.layoutMode || value.layoutExample != draft.appearance.layoutExample || value.layoutFile != draft.appearance.layoutFile
            draft.appearance = value
            if chosen, changed { draft.turnOnForLayout(defaults: model.desktopDefaults) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("desktop layout").font(Theme.mono(13, weight: .medium)).foregroundStyle(Theme.green)
                Spacer(minLength: 12)
                Text(draft.source == "none" ? "Choosing a layout turns on developer setup" : "Applied at the next desktop login").font(Theme.note).foregroundStyle(.secondary)
            }
            if planning {
                DesktopLayoutPicker(draft: layout, localSource: draft.source == "local", chooseFile: { choosingLayout = true })
            } else {
                Text(NewVMSetupBlocker.unavailable.message).font(Theme.note).foregroundStyle(.secondary)
            }
            if let failure = draft.appearance.layoutFailure {
                Label(failure, systemImage: "exclamationmark.circle.fill").font(Theme.note).foregroundStyle(Theme.amber)
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("setup.layout")
        .fileImporter(isPresented: $choosingLayout, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { var value = draft.appearance; value.layoutFile = url; value.layoutMode = "file"; layout.wrappedValue = value }
        }
    }
}

/// New VM's Customise pane: source, profiles, trim and the optional theme. Edits the
/// shared draft without capturing inputs, provisioning or changing the resource and
/// factory fields owned by the parent form.
struct NewVMSetupSelectionView: View {
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @ObservedObject var model: AppModel
    @Binding var factory: String
    @Binding var draft: NewVMSetupDraft
    @Binding var selection: ProvisioningSetupSource?
    @Binding var blocker: NewVMSetupBlocker?
    @State private var choosingFolder = false
    private var planning: Bool { model.setupService is any ProvisioningCreationPlanning }
    private var selectionBlocker: NewVMSetupBlocker? { draft.blocker(planning: planning) }
    private var current: ProvisioningSetupSource? { draft.selection(factory: factory, planning: planning) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SpecRow("source") {
                Picker("Source", selection: $draft.source) {
                    Text("None").tag("none")
                    Text("Bundled configuration").tag("bundled")
                    Text("Local setup folder").tag("local")
                }.labelsHidden().frame(maxWidth: 240).help(ProvisioningSetupHelp.source)
            }
            if draft.source != "none" {
                if draft.source == "local" {
                    SpecRow("folder", note: draft.folder.map { $0.lastPathComponent + "/vm.yml" }) {
                        Button("Choose setup folder…") { choosingFolder = true }
                    }
                }
                ProvisioningProfileSelectionView(selection: $draft.profiles, localSource: draft.source == "local")
                if factory == "official" { ProvisioningTrimSelectionView(selection: $draft.trimOptionalApps) }
                ProvisioningThemeSelectionView(draft: $draft.appearance, localSource: draft.source == "local")
                if draft.appearance.layoutFailure == nil, let failure = draft.appearance.failure {
                    Label(failure, systemImage: "exclamationmark.circle.fill").font(Theme.note).foregroundStyle(Theme.amber)
                }
                SpecNote("Setup updates Omarchy and system packages, then applies these selections and installs the apps your layout needs. Create, launch & set up approves this exact plan for this VM’s first launch, including temporary admin access while setup runs and the restart and configuration check that finish it, so you end at an updated, configured desktop. If anything changes before setup starts, it pauses and asks again. Create alone saves the plan for a later review.")
            }
        }
        .background {
            #if DEBUG
            if let acceptance { Color.clear.allowsHitTesting(false).onAppear {
                acceptance.bind("selection", action: { command in
                    switch command {
                    case .source(let value): draft.source = value
                    case .profiles(let value): draft.profiles = Set(value)
                    case .appearance(let value): draft.appearance = ProvisioningAppearanceDraft(value)
                    case .trim(let value): if factory == "official" { draft.trimOptionalApps = value }
                    case .folder(let value): draft.folder = value; publish()
                    default: break
                    }
                }, snapshot: { ["trimAvailable": String(factory == "official" && draft.source != "none"), "trim": String(draft.trimOptionalApps), "source": draft.source, "profiles": draft.profiles.sorted().joined(separator: ","), "theme": current?.appearance?.theme ?? "", "layout": current?.appearance?.layoutExample?.rawValue ?? "", "ready": String(selectionBlocker == nil)] })
            } }
            #endif
        }
        .onChange(of: draft.source) { old, _ in draft.sourceChanged(from: old, defaults: model.desktopDefaults); publish() }
        .onChange(of: factory) { _, _ in draft.trimOptionalApps = false; publish() }
        .onChange(of: draft) { _, _ in publish() }
        .onChange(of: selectionBlocker, initial: true) { _, _ in publish() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { draft.folder = url; publish() }
        }
    }
    private func publish() {
        selection = current
        blocker = selectionBlocker
    }
}
