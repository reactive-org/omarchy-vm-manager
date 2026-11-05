import DevVMProvisioningCore
import Foundation

/// Native controls are a small presentation of pinned built-ins. Resolution,
/// dependency ordering, options and conflicts remain owned by the shared planner.
public enum ProvisioningCommonFeature: String, Codable, CaseIterable, Sendable {
    case workstation, cli, vcs, editors, docker, build, toolchain, languages, browsers, databases, api, quality
    public var title: String {
        switch self {
        case .workstation: "Workstation preferences"
        case .cli: "Command-line tools"
        case .vcs: "Git tools"
        case .editors: "Editors"
        case .docker: "Docker"
        case .build: "Native build tools"
        case .toolchain: "Project-managed toolchain"
        case .languages: "Language runtimes"
        case .browsers: "Browsers"
        case .databases: "Database clients"
        case .api: "API diagnostics"
        case .quality: "Quality tools"
        }
    }
}
public enum ProvisioningFeatureChoice: String, CaseIterable, Sendable { case inherit = "Use source", enable = "Enable", disable = "Disable" }
public struct ProvisioningFeatureSelection: Codable, Equatable, Sendable {
    public let enable: [ProvisioningCommonFeature]
    public let disable: [ProvisioningCommonFeature]
    public init(enable: [ProvisioningCommonFeature] = [], disable: [ProvisioningCommonFeature] = []) { self.enable = enable; self.disable = disable }
    public var isEmpty: Bool { enable.isEmpty && disable.isEmpty }
    public func choice(_ feature: ProvisioningCommonFeature) -> ProvisioningFeatureChoice {
        enable.contains(feature) ? .enable : disable.contains(feature) ? .disable : .inherit
    }
    public func setting(_ feature: ProvisioningCommonFeature, to choice: ProvisioningFeatureChoice) -> Self {
        var on = enable.filter { $0 != feature }, off = disable.filter { $0 != feature }
        if choice == .enable { on.append(feature) }; if choice == .disable { off.append(feature) }
        return .init(enable: on.sorted { $0.rawValue < $1.rawValue }, disable: off.sorted { $0.rawValue < $1.rawValue })
    }
    func validate() throws {
        guard enable.count <= ProvisioningCommonFeature.allCases.count, disable.count <= ProvisioningCommonFeature.allCases.count,
              Set(enable).count == enable.count, Set(disable).count == disable.count, Set(enable).isDisjoint(with: disable) else { throw ProvisioningReviewFailure.invalid }
    }
}
struct ProvisioningFrozenSelection: Sendable {
    let selection: ProvisioningSetupSource
    let storage: ProvisioningPrivateInputTree
    let plan: SetupPlan
    let proposal: Data
    let tasks: [ProvisioningTaskReview]
    let restartRequired: Bool
    func preview(id: UUID, vmID: UUID, sessionID: UUID?, engine: String) throws -> ProvisioningPlanPreview {
        let value = ProvisioningPlanPreview(id: id, vmID: vmID, sessionID: sessionID, planDigest: plan.identity,
            inputDigest: plan.snapshot.identity, engineDigest: engine, proposal: proposal, tasks: tasks, restartRequired: restartRequired)
        try value.validate(); return value
    }
}

extension ProvisioningService {
    static let selectionManifest = ".omarchy-manager-selection.json"
    func freezeSelection(_ source: ProvisioningSetupSource, appearance: ProvisioningFrozenAppearance? = nil) throws -> ProvisioningFrozenSelection {
        try reviewAvailable(); try source.validate(); try environment.admitPackage()
        let directory: URL, manifest: String
        if let preset = source.preset {
            let url = try BundledProvisioning.presetSource(preset); directory = url.deletingLastPathComponent(); manifest = url.lastPathComponent
        } else if source.bundled == true {
            guard let url = Bundle.module.url(forResource: "SetupProfiles", withExtension: "json") else { throw ProvisioningReviewFailure.unavailable }
            directory = url.deletingLastPathComponent(); manifest = url.lastPathComponent
        } else { directory = URL(fileURLWithPath: source.directory!); manifest = source.manifest ?? "vm.yml" }
        let proposed = try SetupPlanner.plan(repository: directory, manifest: manifest)
        guard try ProvisioningCoordinator.engineIdentity(proposed) == environment.engineDigest else { throw ProvisioningReviewFailure.changed }
        let archive = try FrozenInputsArchive(privateArchive: proposed.snapshot.privateArchive(), expectedIdentity: proposed.snapshot.identity)
        let projected: Data?
        if source.profiles?.isEmpty == false || source.features?.isEmpty == false || source.trimOptionalApps != nil || appearance != nil {
            guard archive.data(for: Self.selectionManifest) == nil, !archive.directoryPaths.contains(Self.selectionManifest),
                  let original = archive.data(for: manifest), case .object(var fields) = try PlainDataParser.parse(original, format: manifest.hasSuffix("json") ? .json : .yaml) else { throw ProvisioningReviewFailure.invalid }
            var setup: [String: ManifestValue] = [:], choices: [String: ManifestValue] = [:]
            if case .object(let value) = fields["setup"] { setup = value }
            if let profiles = source.profiles, !profiles.isEmpty {
                var selected: [ManifestValue] = []
                if case .array(let declared) = setup["profiles"] { selected = declared }
                for name in profiles where !selected.contains(.string(name)) && !selected.contains(.string("builtin." + name)) { selected.append(.string(name)) }
                setup["profiles"] = .array(selected)
            }
            if let features = source.features, !features.isEmpty {
                if case .object(let value) = setup["features"] { choices = value }
                let overridden = Set((features.enable + features.disable).map(\.rawValue))
                func retain(_ value: ManifestValue?) throws -> [ManifestValue] {
                    guard let value else { return [] }; guard case .array(let items) = value else { throw ProvisioningReviewFailure.invalid }
                    return try items.filter { item in
                        guard case .string(let name) = item else { throw ProvisioningReviewFailure.invalid }
                        return !overridden.contains(name.hasPrefix("builtin.") ? String(name.dropFirst(8)) : name)
                    }
                }
                choices["enable"] = .array(try retain(choices["enable"]) + features.enable.map { .string($0.rawValue) })
                choices["disable"] = .array(try retain(choices["disable"]) + features.disable.map { .string($0.rawValue) })
                setup["features"] = .object(choices)
            }
            if let appearance {
                var options: [String: ManifestValue] = [:], workstation: [String: ManifestValue] = [:]
                if case .object(let value) = setup["options"] { options = value }
                let key = options["builtin.workstation"] == nil ? "workstation" : "builtin.workstation"
                if case .object(let value) = options[key] { workstation = value }
                if let theme = appearance.theme { workstation["theme"] = .string(theme) }
                if appearance.layout != nil { workstation["layout"] = .string(Self.selectionLayout); workstation["remove_layout"] = .bool(false) }
                if appearance.selection.removeLayout { workstation["layout"] = .string(""); workstation["remove_layout"] = .bool(true) }
                options[key] = .object(workstation); setup["options"] = .object(options)
                var choices: [String: ManifestValue] = [:], enabled: [ManifestValue] = []
                if case .object(let value) = setup["features"] { choices = value }
                if case .array(let value) = choices["enable"] { enabled = value }
                if !enabled.contains(.string("workstation")) && !enabled.contains(.string("builtin.workstation")) { enabled.append(.string("workstation")) }
                choices["enable"] = .array(enabled); setup["features"] = .object(choices)
            }
            fields["setup"] = .object(setup)
            if let trim = source.trimOptionalApps {
                var vm: [String: ManifestValue] = [:]
                if case .object(let value) = fields["vm"] { vm = value }
                vm["lean_developer"] = .bool(trim)
                fields["vm"] = .object(vm)
            }
            var assets: [ManifestValue] = []
            if case .array(let value) = fields["assets"] { assets = value }
            if !assets.contains(.string(manifest)) { assets.append(.string(manifest)) }
            fields["assets"] = .array(assets)
            projected = try helperJSON(ManifestValue.object(fields))
        } else { projected = nil }
        try ProvisioningSourceRetention.admit(archive, into: sourceDirectory, additionalBytes: (projected?.count ?? 0) + (appearance?.layout?.count ?? 0), additionalEntries: (projected == nil ? 0 : 1) + (appearance?.layout == nil ? 0 : 1))
        let storage = try ProvisioningPrivateInputTree(archive: archive, parent: sourceDirectory)
        if let projected { try storage.writeSelectionManifest(projected, name: Self.selectionManifest) }
        if let layout = appearance?.layout {
            guard archive.data(for: Self.selectionLayout) == nil, !archive.directoryPaths.contains(Self.selectionLayout) else { throw ProvisioningReviewFailure.invalid }
            try storage.writeSelectionManifest(layout, name: Self.selectionLayout)
        }
        let plan: SetupPlan
        do { plan = try SetupPlanner.plan(repository: storage.directory, manifest: projected == nil ? manifest : Self.selectionManifest) }
        catch let error as ManifestError where error.code == .conflict { throw ProvisioningReviewFailure.conflictingProfiles }
        if appearance != nil {
            guard case .object(let document) = plan.document, case .object(let features) = document["features"],
                  case .array(let names) = features["features"], names.contains(.string("workstation")) else { throw ProvisioningAppearanceFailure.workstationDisabled }
        }
        if projected == nil {
            guard plan.identity == proposed.identity, plan.snapshot.identity == archive.identity else { throw ProvisioningReviewFailure.changed }
        }
        guard try ProvisioningCoordinator.engineIdentity(plan) == environment.engineDigest,
              case .object(let document) = plan.document, case .array(let taskFields) = document["tasks"],
              case .object(let requirements) = document["requirements"] else { throw ProvisioningReviewFailure.changed }
        let tasks = try taskFields.map { value -> ProvisioningTaskReview in
            guard case .object(let fields) = value, case .string(let name) = fields["name"], case .string(let file) = fields["file"],
                  let receipt = plan.snapshot.receipts.first(where: { $0.path == file }) else { throw ProvisioningReviewFailure.invalid }
            return .init(name: name, file: file, sha256: receipt.sha256)
        }
        try environment.admitPackage()
        let value = ProvisioningFrozenSelection(selection: source, storage: storage, plan: plan, proposal: try helperJSON(plan), tasks: tasks,
            restartRequired: requirements["desktop_restart_required"] == .bool(true))
        // Same review bounds for attached and not-yet-created guests.
        _ = try value.preview(id: UUID(), vmID: UUID(), sessionID: nil, engine: environment.engineDigest)
        return value
    }
}
