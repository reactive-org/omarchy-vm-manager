import Foundation
import OmarchyVMManagerCore

func reply(_ object: [String: Any], status: Int32) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    FileHandle.standardOutput.write(data + Data([10]))
    exit(status)
}

do {
    let args = CommandLine.arguments
    guard args.count == 4, args[1] == "--trash", let id = UUID(uuidString: args[2]),
          args[2] == id.uuidString, args[3].utf8.count <= 256 else {
        throw VMFailure(code: "invalid-request", message: "A registered UUID and reviewed storage identity are required.")
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
    let storage = ManagerStorage(applicationSupport: support)
    try PrivateFiles.directory(storage.directory)
    struct Registry: Decodable { let schemaVersion: Int; let profiles: [VMProfile]; let pendingDeletions: Set<UUID>? }
    let data = try PrivateFiles.read(storage.directory.appendingPathComponent("registry.json"), maximum: 1_048_576)
    let registry = try JSONDecoder().decode(Registry.self, from: data)
    guard (1...4).contains(registry.schemaVersion), registry.pendingDeletions?.contains(id) == true, registry.profiles.filter({ $0.id == id }).count == 1,
          let profile = registry.profiles.first(where: { $0.id == id }) else {
        throw VMFailure(code: "unregistered-vm", message: "The VM is not uniquely registered.")
    }
    try RegistryStore.validate(profile)
    try storage.trash(profile, expectedIdentity: args[3])
    reply(["ok": true, "id": id.uuidString], status: 0)
} catch {
    reply(["ok": false, "code": (error as? VMFailure)?.code ?? "storage-refused"], status: 1)
}
