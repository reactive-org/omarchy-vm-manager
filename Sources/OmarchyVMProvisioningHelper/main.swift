import Foundation
import OmarchyVMManagerCore

// Offline work and an inherited ownership-only control channel. No execution,
// VM registry, Keychain, guest, tool probing or path-addressed socket surface.
func output(_ data: Data, status: Int32 = 0) -> Never {
    FileHandle.standardOutput.write(data + Data([10])); exit(status)
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--help"] {
        output(Data("Offline provisioning helper: --verify-package-json | --validate-manifest-json FILE | --plan-json REPOSITORY [MANIFEST]\nExecution is disabled.".utf8))
    }
    if args == ["--channel-json"] {
        output(try JSONSerialization.data(withJSONObject: ["appChannel": AppChannel.current.rawValue,
            "bundleIdentifier": AppChannel.current.bundleIdentifier], options: [.sortedKeys]))
    }
    guard let executable = Bundle.main.executableURL, executable.deletingLastPathComponent().lastPathComponent == "MacOS" else {
        throw VMFailure(code: "provisioning-package-invalid", message: "Packaged helper required.")
    }
    let layout = ProvisioningPackageLayout(contents: executable.deletingLastPathComponent().deletingLastPathComponent())
    if args.count == 2, args[0] == "--ownership-channel-fd", let fd = Int32(args[1]) {
        _ = try AppChannel.current.enclosingApp(for: executable)
        try await ProvisioningHelperControl.serveInheritedOwnershipChannel(descriptor: fd, layout: layout)
        exit(0)
    }
    if args == ["--verify-package-json"] { output(try JSONEncoder().encode(BundledProvisioning.inspect(layout))) }
    if args.count == 2, args[0] == "--validate-manifest-json" {
        output(try BundledProvisioning.validateManifest(URL(fileURLWithPath: args[1]), layout: layout))
    }
    if (2...3).contains(args.count), args[0] == "--plan-json" {
        output(try BundledProvisioning.plan(repository: URL(fileURLWithPath: args[1]), manifest: args.count == 3 ? args[2] : "vm.yml", layout: layout))
    }
    throw VMFailure(code: "provisioning-execution-disabled", message: "Offline commands only.")
} catch {
    let value: [String: Any] = ["ok": false, "code": (error as? VMFailure)?.code ?? "provisioning-package-invalid"]
    output(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), status: 1)
}
