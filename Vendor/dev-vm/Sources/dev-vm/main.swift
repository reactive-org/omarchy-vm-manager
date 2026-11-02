import DevVMProvisioningCore
import Foundation

// Migration surface only. Legacy Python make entry points retain their current behavior.
let args = Array(CommandLine.arguments.dropFirst())
if args == ["--help"] || args == ["-h"] {
    print("Usage: dev-vm validate-manifest <manifest.json|manifest.yml|manifest.yaml>")
    print("       dev-vm plan <repository> [manifest.json|manifest.yml|manifest.yaml]")
    print("Offline validation/planning only; no host tool probes or VM operations.")
} else if (2...3).contains(args.count), args[0] == "plan" {
    do {
        let plan = try SetupPlanner.plan(repository: URL(fileURLWithPath: args[1]), manifest: args.count == 3 ? args[2] : "vm.yml")
        FileHandle.standardOutput.write(try canonicalPlan(plan))
    } catch {
        let message = (error as? ManifestError)?.description ?? "manifest.file"
        FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
    }
} else if args.count == 2, args[0] == "validate-manifest" {
    do {
        let manifest = try SetupManifest.read(URL(fileURLWithPath: args[1]))
        // Do not echo manifest values, paths, variables or custom task contents.
        print("{\"api_version\":1,\"schema_version\":1,\"structure_valid\":true,\"resolved\":false,\"execution_available\":false,\"dotfiles\":\(manifest.dotfiles.count),\"tasks\":\(manifest.tasks.count),\"assets\":\(manifest.assets.count)}")
    } catch {
        let message = (error as? ManifestError)?.description ?? "manifest.file"
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
} else {
    FileHandle.standardError.write(Data("Usage: dev-vm validate-manifest <manifest.json|manifest.yml|manifest.yaml>\n       dev-vm plan <repository> [manifest]\n".utf8))
    exit(2)
}

func canonicalPlan(_ plan: SetupPlan) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(plan); data.append(10); return data
}
