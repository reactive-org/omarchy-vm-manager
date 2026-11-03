import Foundation

/// Offline proposal plus immutable inputs. It is never executable authorization.
public struct SetupPlan: Sendable, Encodable {
    public let document: ManifestValue
    public let snapshot: SourceSnapshot
    public let manifestPath: String
    public var identity: String { document.object!["plan_digest"]!.string! }
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
        let features = try FeaturePlanner.resolve(selection: manifest.selection, catalogues: catalogues)
        if let layout = features.options["workstation"]?.object?["layout"]?.string, !layout.isEmpty {
            _ = try builder.capture(layout)
            guard builder.freeze().data(for: layout) != nil else { throw ManifestError(.file) }
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
        let inputs = snapshot.receipts.map { ManifestValue.object(["path": .string($0.path), "sha256": .string($0.sha256), "mode": .integer(Int64($0.mode))]) }
        let restart = features.options["docker"]?.object?["access"] == .string("sudoless")
        var document: [String: ManifestValue] = [
            "schema_version": .integer(1), "planning_api": .integer(1), "id": .string(manifest.id), "vm": .object(vm),
            "engine": try engine(), "features": features.document, "dotfiles": .array(dotfiles), "tasks": .array(tasks),
            "inputs": .array(inputs), "input_digest": .string(snapshot.identity), "execution_available": .bool(false),
            "custom_task_effects": .string("Opaque trusted Ansible code; may execute on the host as well as the guest"),
            "requirements": .object(["planning_tools": .array([]),
                "application_tools": .array((features.features.isEmpty && dotfiles.isEmpty && tasks.isEmpty ? [] : ["bash", "ssh", "scp", "sftp", "ansible-playbook", "ansible-inventory"]).map(ManifestValue.string)),
                "trusted_tasks_required": .bool(!tasks.isEmpty), "desktop_restart_required": .bool(restart),
                "guest_state": .string("not_observed"), "dotfile_conflicts": .string("not_checked"),
                "removals": .array([]), "update_policy": .string("Native Omarchy/mise ownership; no implicit removal or update"),
                "factory_admission": .string("manager_verification_required")])]
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
