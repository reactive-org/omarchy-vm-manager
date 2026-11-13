import Foundation

/// Offline proposal plus immutable inputs. It is never executable authorization.
public struct SetupPlan: Sendable, Encodable {
    public let document: ManifestValue
    public let snapshot: SourceSnapshot
    public let manifestPath: String
    public var identity: String { document.object!["plan_digest"]!.string! }
    /// Setup asks Omarchy for renewed 60-minute grants instead of one permanent grant.
    public var timedSudoGrant: Bool { document.object?["vm"]?.object?["sudo_grant"] == .string("timed") }
    public func encode(to encoder: any Encoder) throws { try document.encode(to: encoder) }
    public func verify(in repository: URL) throws {
        try snapshot.verify(in: repository)
        guard try SetupPlanner.engine() == document.object!["engine"] else { throw ManifestError(.sourceChanged) }
    }
}

public enum SetupPlanner {
    public static func plan(repository: URL, manifest path: String = "vm.yml") throws -> SetupPlan {
        let builder = try SnapshotBuilder(repository: repository)
        let manifest = try SetupManifest(value: builder.document(path).value)
        let paths = try strings(manifest.selection.object?["catalogues"] ?? .array([]))
        let catalogues = try paths.map { path -> FeatureCatalogue in
            _ = try builder.document(path)
            return try FeatureCatalogue(data: builder.freeze().data(for: path)!, format: sourceFormat(path), sourceID: path)
        }
        var features = try FeaturePlanner.resolve(selection: manifest.selection, catalogues: catalogues)
        var layoutReport: ManifestValue?
        if let layout = features.options["workstation"]?.object?["layout"]?.string, !layout.isEmpty {
            _ = try builder.capture(layout)
            guard let bytes = builder.freeze().data(for: layout) else { throw ManifestError(.file) }
            // A byte-identical bundled example brings the apps it arranges; any other file adds nothing.
            if let example = try LayoutExamples.catalogue().first(where: { $0.sourceSHA256 == digest(bytes) }) {
                let needs = try LayoutNeedsPlanner(example: example, base: features, selection: manifest.selection)
                if let request = needs.request {
                    features = try FeaturePlanner.resolve(selection: manifest.selection, catalogues: catalogues, layout: request)
                }
                layoutReport = needs.report(final: features)
            }
        }
        var dotfiles: [ManifestValue] = [], targets = Set<String>()
        for entry in manifest.dotfiles {
            let files = try builder.capture(entry.source)
            let isFile = builder.freeze().data(for: entry.source) != nil
            for source in files {
                let target = isFile ? entry.target : entry.target + "/" + source.dropFirst(entry.source.count + 1)
                try relativePath(target)
                guard !targets.contains(where: { $0 == target || $0.hasPrefix(target + "/") || target.hasPrefix($0 + "/") })
                else { throw ManifestError(.conflict) }
                targets.insert(target)
                dotfiles.append(.object(["source": .string(source), "target": .string(target),
                                         "sha256": .string(digest(builder.freeze().data(for: source)!)),
                                         "mode": .integer(Int64(entry.mode, radix: 8)!)]))
            }
        }
        var tasks: [ManifestValue] = []
        for task in manifest.tasks {
            _ = try builder.capture(task.file)
            guard builder.freeze().data(for: task.file) != nil else { throw ManifestError(.file) }
            tasks.append(.object(["name": .string(task.name), "file": .string(task.file), "tag": .string("setup." + task.name)]))
        }
        for asset in manifest.assets { _ = try builder.capture(asset) }
        let snapshot = builder.freeze()
        // Rewalk declarations before returning to detect edits/additions during resolution.
        try snapshot.verify(in: repository)
        var vm: [String: ManifestValue] = ["name": .string(manifest.vm.name), "cpus": .integer(manifest.vm.cpus),
            "memory_gib": .integer(manifest.vm.memoryGiB), "disk_gib": .integer(manifest.vm.diskGiB),
            "packages": .array(manifest.vm.packages.map(ManifestValue.string)), "lean_developer": .bool(manifest.vm.leanDeveloper)]
        if let factory = manifest.vm.factory { vm["factory"] = .string(factory) }
        // Omitted when permanent, so plans that predate the field keep their identity.
        if manifest.vm.timedSudoGrant { vm["sudo_grant"] = .string("timed") }
        let inputs = snapshot.receipts.map { ManifestValue.object(["path": .string($0.path), "sha256": .string($0.sha256), "mode": .integer(Int64($0.mode))]) }
        let removals = manifest.vm.leanDeveloper ? try LeanDeveloperPolicy.candidates(keeping: LeanDeveloperPolicy.keep(vmPackages: manifest.vm.packages, features: features.document)) : []
        let restart = features.options["docker"]?.object?["access"] == .string("sudoless")
        var document: [String: ManifestValue] = [
            "schema_version": .integer(1), "planning_api": .integer(1), "id": .string(manifest.id), "vm": .object(vm),
            "engine": try engine(), "features": features.document, "dotfiles": .array(dotfiles), "tasks": .array(tasks),
            "inputs": .array(inputs), "input_digest": .string(snapshot.identity), "execution_available": .bool(false),
            "custom_task_effects": .string("Opaque trusted Ansible code; may execute on the host as well as the guest"),
            "requirements": .object(["planning_tools": .array([]),
                "application_tools": .array(["bash", "ssh", "scp", "sftp", "ansible-playbook", "ansible-inventory"].map(ManifestValue.string)),
                "trusted_tasks_required": .bool(!tasks.isEmpty), "desktop_restart_required": .bool(restart),
                "system_update_required": .bool(true), "system_restart_required": .bool(true),
                "guest_state": .string("not_observed"), "dotfile_conflicts": .string("not_checked"),
                "removals": .array(removals.map(ManifestValue.string)),
                "update_policy": .string("Apply updates Omarchy and all system packages through omarchy update -y before installing selected software; restart and check are reviewed afterward. Check mode never updates. " + (manifest.vm.leanDeveloper ? "Opt-in optional-app trim through Omarchy; candidates only, installed state and dependency safety checked in the guest; selected software and required components retained." : "Native Omarchy/mise ownership; no implicit removal.")),
                "factory_admission": .string("manager_verification_required")])]
        if let layoutReport { document["layout"] = layoutReport }
        document["plan_digest"] = .string(digest(try canonicalData(ManifestValue.object(document))))
        return SetupPlan(document: .object(document), snapshot: snapshot, manifestPath: path)
    }

    static func engine() throws -> ManifestValue {
        let doc = try SelectionSchema.resource("engine-identity")
        guard let sourceHashes = doc.object?["sources"]?.object else { throw ManifestError(.resource) }
        for (path, expected) in sourceHashes where path.hasPrefix("Sources/DevVMProvisioningCore/Resources/") {
            let name = String(path.dropFirst("Sources/DevVMProvisioningCore/Resources/".count))
            try relativePath(name)
            guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"),
                  let data = try? Data(contentsOf: url), expected == .string(digest(data)) else { throw ManifestError(.resource) }
        }
        return doc
    }
}

/// Works out what a recognised layout example adds to a plan, against the same plan
/// without the layout. Lists are added to each feature's effective value (defaults
/// included), so a layout's VS Code never displaces a profile's Neovim.
struct LayoutNeedsPlanner {
    let example: LayoutExample
    let base: ResolvedFeatures
    private(set) var request: LayoutRequest?
    private var present: [ManifestValue] = [], missing: [ManifestValue] = []
    private var added: [(need: LayoutNeed, items: [String])] = []

    init(example: LayoutExample, base: ResolvedFeatures, selection: ManifestValue) throws {
        self.example = example; self.base = base
        let disabled = Set(try strings(selection.object?["features"]?.object?["disable"] ?? .array([]))
            .map { $0.hasPrefix("builtin.") ? String($0.dropFirst(8)) : $0 })
        var features: [String] = [], options: [String: [String: ManifestValue]] = [:]
        for need in example.needs {
            guard let feature = need.feature, let lists = need.options else {
                missing.append(.object(["application": .string(need.application), "reason": .string("no_feature")])); continue
            }
            guard !disabled.contains(feature) else {
                missing.append(.object(["application": .string(need.application), "feature": .string(feature), "reason": .string("disabled")])); continue
            }
            let selected = base.features.contains(feature)
            var newItems: [String] = []
            for key in lists.keys.sorted() {
                let effective = (options[feature]?[key] ?? (selected ? base.options[feature]?.object?[key] : nil))?.array ?? []
                let needed = lists[key]!.map(ManifestValue.string)
                newItems += needed.filter { !effective.contains($0) }.compactMap(\.string)
                options[feature, default: [:]][key] = .array(selected || options[feature]?[key] != nil ? mergedList(effective, needed) : needed)
            }
            if !newItems.isEmpty, !features.contains(feature) { features.append(feature) }
            if newItems.isEmpty { present.append(.object(["application": .string(need.application), "feature": .string(feature)])) }
            else { added.append((need, newItems)) }
        }
        if !added.isEmpty {
            request = LayoutRequest(id: example.id.rawValue, features: features, options: options.mapValues { .object($0) })
        }
    }

    func report(final: ResolvedFeatures) -> ManifestValue {
        let before = Set(base.document.object?["packages"]?.object?.keys.map { $0 } ?? [])
        let after = final.document.object?["packages"]?.object ?? [:]
        let adds = added.map { need, items -> ManifestValue in
            let feature = need.feature!
            let packages = after.filter { !before.contains($0.key) && ($0.value.array ?? []).contains(.string(feature)) }.keys.sorted()
            return .object(["application": .string(need.application), "feature": .string(feature),
                            "items": .array(items.map(ManifestValue.string)), "packages": .array(packages.map(ManifestValue.string))])
        }
        return .object(["example": .string(example.id.rawValue), "sha256": .string(example.sourceSHA256),
                        "adds": .array(adds), "already_selected": .array(present), "not_installed": .array(missing)])
    }
}
