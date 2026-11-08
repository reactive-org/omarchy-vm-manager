import Foundation

/// Syntactically validated input, not a resolved plan or permission to execute.
/// Source paths and factory references are declarations only; no asset/factory admission occurs.
public struct SetupManifest: Sendable, Equatable {
    public static let schemaVersion = 1
    public static let apiVersion = 1
    public let id: String
    public let vm: VMDeclaration
    public let selection: ManifestValue
    public let dotfiles: [DotfileDeclaration]
    public let tasks: [TaskDeclaration]
    public let assets: [String]
    public let variables: [String: ManifestValue]

    public static func parse(_ data: Data, format: ManifestFormat) throws -> SetupManifest {
        try SetupManifest(value: PlainDataParser.parse(data, format: format))
    }
    public static func read(_ url: URL) throws -> SetupManifest {
        try SetupManifest(value: PlainDataParser.read(url))
    }
    init(value: ManifestValue) throws {
        let root = try fields(value, allowed: ["schema_version", "id", "vm", "setup", "dotfiles", "tasks", "assets", "vars"],
                              required: ["schema_version", "id"])
        guard root["schema_version"] == .integer(1), let id = root["id"]?.string,
              matches(id, "[a-z][a-z0-9_-]{0,63}") else { throw ManifestError(.schema) }
        self.id = id
        vm = try VMDeclaration(value: root["vm"] ?? .object([:]))
        let selection = root["setup"] ?? .object([:])
        try SelectionSchema.validate(selection)
        for path in try strings(selection.object?["catalogues"] ?? .array([])) { try relativePath(path) }
        self.selection = selection
        var targets = Set<String>()
        dotfiles = try items(root["dotfiles"] ?? .array([])).map { item in
            let entry = try fields(item, allowed: ["source", "target", "mode"], required: ["source", "target"])
            let source = try string(entry["source"])
            try relativePath(source)
            var target = try string(entry["target"])
            if target.hasPrefix("~/") { target = String(target.dropFirst(2)) }
            try relativePath(target)
            guard !target.hasPrefix("~"),
                  ![".ssh", ".gnupg", ".aws"].contains(String(target.split(separator: "/")[0])),
                  !target.hasPrefix(".local/state/dev-vm"),
                  !targets.contains(where: { $0 == target || $0.hasPrefix(target + "/") || target.hasPrefix($0 + "/") })
            else { throw ManifestError(.schema) }
            targets.insert(target)
            let mode = try string(entry["mode"] ?? .string("0644"))
            guard matches(mode, "0[0-7]{3}") else { throw ManifestError(.schema) }
            return DotfileDeclaration(source: source, target: target, mode: mode)
        }
        var names = Set<String>()
        tasks = try items(root["tasks"] ?? .array([])).map { item in
            let entry = try fields(item, allowed: ["name", "file"], required: ["name", "file"])
            let name = try string(entry["name"])
            guard name != "all", matches(name, "[a-z][a-z0-9_-]*"), names.insert(name).inserted
            else { throw ManifestError(.schema) }
            let file = try string(entry["file"])
            try relativePath(file)
            return TaskDeclaration(name: name, file: file)
        }
        assets = try strings(root["assets"] ?? .array([]))
        for path in assets { try relativePath(path) }
        guard let variables = (root["vars"] ?? .object([:])).object else { throw ManifestError(.schema) }
        self.variables = variables
    }
}

public struct DotfileDeclaration: Sendable, Equatable {
    public let source: String
    public let target: String
    public let mode: String
}
public struct TaskDeclaration: Sendable, Equatable {
    public let name: String
    public let file: String
}
public struct VMDeclaration: Sendable, Equatable {
    public let name: String
    public let factory: String?
    public let cpus: Int64
    public let memoryGiB: Int64
    public let diskGiB: Int64
    public let packages: [String]
    public let leanDeveloper: Bool
    /// `sudo_grant: timed` asks Omarchy for 60-minute grants renewed during
    /// setup; absent or `permanent` keeps the single permanent grant.
    public let timedSudoGrant: Bool

    fileprivate init(value: ManifestValue) throws {
        let vm = try fields(value, allowed: ["name", "factory", "cpus", "memory_gib", "disk_gib", "packages", "lean_developer", "sudo_grant"])
        name = try string(vm["name"] ?? .string("Dev Omarchy"))
        guard boundedText(name, bytes: 128) else { throw ManifestError(.schema) }
        if let v = vm["factory"] {
            let text = try string(v)
            guard boundedText(text, bytes: 4096) else { throw ManifestError(.schema) }
            factory = text
        } else { factory = nil }
        cpus = try integer(vm["cpus"] ?? .integer(8), range: 4...128)
        memoryGiB = try integer(vm["memory_gib"] ?? .integer(20), range: 4...1024)
        diskGiB = try integer(vm["disk_gib"] ?? .integer(64), range: 64...8192)
        guard case .bool(let lean) = vm["lean_developer"] ?? .bool(false) else { throw ManifestError(.schema) }
        leanDeveloper = lean
        switch vm["sudo_grant"] ?? .string("permanent") {
        case .string("permanent"): timedSudoGrant = false
        case .string("timed"): timedSudoGrant = true
        default: throw ManifestError(.schema)
        }
        packages = try strings(vm["packages"] ?? .array([]))
        var seen = Set<String>()
        for package in packages {
            let trimmed = package.trimmingCharacters(in: .whitespacesAndNewlines)
            let source: String
            let name: String
            if trimmed.hasPrefix("mise:") { source = "mise:"; name = String(trimmed.dropFirst(5)) }
            else if trimmed.hasPrefix("pkg:") { source = "pkg:"; name = String(trimmed.dropFirst(4)) }
            else { source = "pkg:"; name = trimmed }
            guard matches(name, "[A-Za-z0-9][A-Za-z0-9._+@/-]*"), seen.insert(source + name).inserted
            else { throw ManifestError(.schema) }
        }
    }
}

func fields(_ value: ManifestValue, allowed: Set<String>, required: Set<String> = []) throws -> [String: ManifestValue] {
    guard let object = value.object, Set(object.keys).isSubset(of: allowed), required.isSubset(of: Set(object.keys))
    else { throw ManifestError(.schema) }
    return object
}
func string(_ value: ManifestValue?) throws -> String {
    guard let text = value?.string else { throw ManifestError(.schema) }
    return text
}
func items(_ value: ManifestValue) throws -> [ManifestValue] {
    guard let items = value.array else { throw ManifestError(.schema) }
    return items
}
func strings(_ value: ManifestValue) throws -> [String] { try items(value).map { try string($0) } }
private func integer(_ value: ManifestValue, range: ClosedRange<Int64>) throws -> Int64 {
    guard let number = value.integer, range.contains(number) else { throw ManifestError(.schema) }
    return number
}
func boundedText(_ text: String, bytes: Int) -> Bool {
    !text.isEmpty && text.utf8.count <= bytes && !text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
}
func relativePath(_ path: String) throws {
    guard boundedText(path, bytes: PlainDataParser.maximumBytes), !path.hasPrefix("/"), !path.contains("\\"),
          !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { ["", ".", "..", ".git"].contains($0) })
    else { throw ManifestError(.schema) }
}
