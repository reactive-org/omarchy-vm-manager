import Foundation

public struct FeatureCatalogue: Sendable {
    let document: PlainDocument
    let source: ManifestValue
    public init(data: Data, format: ManifestFormat, sourceID: String) throws {
        try relativePath(sourceID)
        document = try PlainDataParser.document(data, format: format)
        source = .object(["path": .string(sourceID), "sha256": .string(digest(data))])
    }
}

public struct ResolvedFeatures: Sendable, Encodable {
    public let document: ManifestValue
    public var features: [String] { document.object!["features"]!.array!.map { $0.string! } }
    public var options: [String: ManifestValue] { document.object!["options"]!.object! }
    public func encode(to encoder: any Encoder) throws { try document.encode(to: encoder) }
}

public enum FeaturePlanner {
    /// Pure, offline resolution. Catalogue bytes must already be explicitly captured.
    public static func resolve(selection: ManifestValue = .object([:]), catalogues: [FeatureCatalogue] = [],
                               profiles: [String] = [], features: [String]? = nil,
                               overrides: ManifestValue = .object([:])) throws -> ResolvedFeatures {
        // Reject changed bundled schemas/catalogue before interpreting their structure.
        _ = try SetupPlanner.engine()
        for value in [selection, overrides] {
            do { _ = try PlainDataParser.parse(canonicalData(value), format: .json) }
            catch let error as ManifestError { throw error }
            catch { throw ManifestError(.schema) }
        }
        let declared = try strings(selection.object?["catalogues"] ?? .array([]))
        let supplied = Set(catalogues.map { $0.source.object!["path"]!.string! })
        guard Set(declared).isSubset(of: supplied) else { throw ManifestError(.reference) }
        let resolver = try Resolver(catalogues: catalogues)
        return try resolver.resolve(selection: selection, profiles: profiles, features: features, overrides: overrides)
    }
}

indirect enum Choice: Equatable {
    case value(ManifestValue), map([String: Choice]), conflict
    init(_ v: ManifestValue) {
        if case .object(let items) = v { self = .map(items.mapValues(Choice.init)) } else { self = .value(v) }
    }
    func plain() throws -> ManifestValue {
        switch self {
        case .value(let v): v
        case .map(let m): .object(try m.mapValues { try $0.plain() })
        case .conflict: throw ManifestError(.conflict)
        }
    }
    func overlay(_ right: Choice) -> Choice {
        guard case .map(var left) = self, case .map(let rightMap) = right, !rightMap.isEmpty else { return right }
        for (k, v) in rightMap { left[k] = left[k].map { $0.overlay(v) } ?? v }
        return .map(left)
    }
    func siblings(_ right: Choice) -> Choice {
        if self == right { return self }
        guard case .map(var left) = self, case .map(let rightMap) = right, !left.isEmpty, !rightMap.isEmpty else { return .conflict }
        for (k, v) in rightMap { left[k] = left[k].map { $0.siblings(v) } ?? v }
        return .map(left)
    }
}

final class Resolver {
    let catalogue: [String: ManifestValue]
    let optionSchema: [String: ManifestValue]
    let catalogueSchema: ManifestValue
    var definitions: [String: ManifestValue]
    var profiles: [String: ManifestValue]
    var order: [String]
    var sources: [ManifestValue]
    var namespaces: Set<String> = ["builtin"]
    var cache: [String: (Set<String>, [String: Choice])] = [:]

    init(catalogues: [FeatureCatalogue]) throws {
        let builtin = try SelectionSchema.resourceDocument("catalogue")
        catalogue = builtin.value.object!
        optionSchema = try SelectionSchema.resource("selection.schema").object!["properties"]!.object!["options"]!.object!
        catalogueSchema = try SelectionSchema.resource("catalogue.schema")
        definitions = catalogue["features"]!.object!
        profiles = catalogue["profiles"]!.object!
        order = builtin.objectKeys[["features"]]!
        // Hash the exact bundled resource bytes, not a reserialization.
        let url = Bundle.module.url(forResource: "catalogue", withExtension: "json", subdirectory: "Resources")!
        sources = [.object(["path": .string("builtin/catalogue.json"), "sha256": .string(digest(try Data(contentsOf: url)))])]
        guard catalogues.count <= 32 else { throw ManifestError(.sourceLimit) }
        for c in catalogues { try load(c) }
        try validate()
    }
    func load(_ input: FeatureCatalogue) throws {
        try SelectionSchema.validate(input.document.value, against: catalogueSchema)
        let root = input.document.value.object!
        let namespace = root["namespace"]!.string!
        guard namespaces.insert(namespace).inserted else { throw ManifestError(.reference) }
        for name in input.document.objectKeys[["features"]] ?? [] {
            let d = root["features"]!.object![name]!.object!
            guard !d["description"]!.string!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ManifestError(.schema) }
            let id = namespace + "." + name
            definitions[id] = .object(["description": d["description"]!, "handler": .string("tools"),
                "requires": d["requires"] ?? .array([]),
                "defaults": .object(["packages": d["packages"] ?? .array([]), "tools": d["mise"] ?? .object([:])])])
            order.append(id)
            _ = try configuration(id, options: [:], validateTOML: false)
        }
        for (name, d) in root["profiles"]?.object ?? [:] { profiles[namespace + "." + name] = d }
        guard definitions.count <= 512, profiles.count <= 512 else { throw ManifestError(.sourceLimit) }
        sources.append(input.source)
    }
    func reference(_ name: String) throws -> String {
        guard matches(name, "[a-z][a-z0-9_-]*(?:\\.[a-z][a-z0-9_-]*)?") else { throw ManifestError(.reference) }
        return name.hasPrefix("builtin.") ? String(name.dropFirst(8)) : name
    }
    func refs(_ v: ManifestValue) throws -> [String] {
        let values = try strings(v).map(reference)
        guard values.count <= 512, Set(values).count == values.count else { throw ManifestError(.reference) }
        return values
    }
    func options(_ value: ManifestValue, validateTOML: Bool = true) throws -> [String: ManifestValue] {
        guard let object = value.object else { throw ManifestError(.schema) }
        var result: [String: ManifestValue] = [:]
        for key in object.keys.sorted() {
            let name = try reference(key)
            guard definitions[name] != nil, result[name] == nil, let config = object[key]?.object else { throw ManifestError(.reference) }
            _ = try configuration(name, options: config, validateTOML: validateTOML)
            result[name] = .object(config)
        }
        return result
    }
    func configuration(_ name: String, options: [String: ManifestValue], validateTOML: Bool = true) throws -> [String: ManifestValue] {
        let definition = definitions[name]!.object!
        var config = definition["defaults"]!.object!.merging(options) { _, new in new }
        guard Set(config.keys) == Set(definition["defaults"]!.object!.keys) else { throw ManifestError(.schema) }
        let rule = optionSchema["properties"]!.object![name] ?? optionSchema["patternProperties"]!.object!.values.first!
        try SelectionSchema.validate(.object(config), against: rule)
        if let tools = config["tools"]?.object { config["tools"] = .object(tools.filter { $0.value != .null }) }
        if name == "workstation" {
            let text = config["starship_config"]!.string!
            guard text.utf8.count <= 65536 else { throw ManifestError(.toml) }
            let theme = config["theme"]!.string!
            guard theme.isEmpty || matches(theme, "https://github\\.com/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9._+\\-]*/?") else { throw ManifestError(.schema) }
            guard config["layout"] == .string("") || config["remove_layout"] == .bool(false) else { throw ManifestError(.conflict) }
            if validateTOML, !text.isEmpty, config["starship"] == .bool(true), config["shell"] == .string("zsh") { try validatePromptTOML(text) }
        }
        return config
    }
    func validate() throws {
        for name in order {
            var d = definitions[name]!.object!
            let requires = try refs(d["requires"] ?? .array([]))
            guard Set(requires).isSubset(of: Set(definitions.keys)) else { throw ManifestError(.reference) }
            d["requires"] = .array(requires.map(ManifestValue.string)); definitions[name] = .object(d)
        }
        for name in profiles.keys.sorted() {
            var d = try fields(profiles[name]!, allowed: ["description", "extends", "features", "options"])
            if let description = d["description"], description.string == nil { throw ManifestError(.schema) }
            let parents = try refs(d["extends"] ?? .array([])), features = try refs(d["features"] ?? .array([]))
            guard Set(parents).isSubset(of: Set(profiles.keys)), Set(features).isSubset(of: Set(definitions.keys)) else { throw ManifestError(.reference) }
            d["extends"] = .array(parents.map(ManifestValue.string)); d["features"] = .array(features.map(ManifestValue.string))
            d["options"] = .object(try options(d["options"] ?? .object([:]), validateTOML: false)); profiles[name] = .object(d)
        }
        try acyclic(definitions, edge: "requires"); try acyclic(profiles, edge: "extends")
    }
    func acyclic(_ nodes: [String: ManifestValue], edge: String) throws {
        var visited = Set<String>(), active = Set<String>()
        func visit(_ name: String) throws {
            guard active.count < 30 else { throw ManifestError(.depth) }
            guard !active.contains(name) else { throw ManifestError(.cycle) }
            if visited.contains(name) { return }
            active.insert(name)
            for parent in nodes[name]!.object![edge]!.array! { try visit(parent.string!) }
            active.remove(name); visited.insert(name)
        }
        for name in nodes.keys.sorted() { try visit(name) }
    }
    func combine(_ left: [String: Choice], _ right: [String: Choice]) -> [String: Choice] {
        left.merging(right) { $0.siblings($1) }
    }
    func profile(_ name: String) -> (Set<String>, [String: Choice]) {
        if let cached = cache[name] { return cached }
        let d = profiles[name]!.object!
        var chosen = Set(d["features"]!.array!.map { $0.string! }), values: [String: Choice] = [:]
        for parent in d["extends"]!.array! {
            let (inherited, options) = profile(parent.string!); chosen.formUnion(inherited); values = combine(values, options)
        }
        let overrides = d["options"]!.object!
        if !overrides.isEmpty, case .map(let merged) = Choice.map(values).overlay(Choice(.object(overrides))) { values = merged }
        cache[name] = (chosen, values); return (chosen, values)
    }
    func resolve(selection: ManifestValue, profiles addedProfiles: [String], features additions: [String]?, overrides: ManifestValue) throws -> ResolvedFeatures {
        try SelectionSchema.validate(selection)
        let setup = selection.object!
        let chosenProfiles = try refs(.array((setup["profiles"]?.array ?? []) + addedProfiles.map(ManifestValue.string)))
        guard Set(chosenProfiles).isSubset(of: Set(profiles.keys)) else { throw ManifestError(.reference) }
        let f = setup["features"]?.object ?? [:]
        var enabled = try refs(f["enable"] ?? .array([]))
        let disabled = Set(try refs(f["disable"] ?? .array([])))
        let extra = try refs(.array((additions ?? []).map(ManifestValue.string)))
        guard Set(enabled + extra).union(disabled).isSubset(of: Set(definitions.keys)) else { throw ManifestError(.reference) }
        var selected = Set<String>(), choices: [String: Choice] = [:], reasons: [String: [String]] = [:]
        for name in chosenProfiles {
            let (features, options) = profile(name); selected.formUnion(features); choices = combine(choices, options)
            for feature in features { reasons[feature, default: []].append("profile " + name) }
        }
        if chosenProfiles.isEmpty, enabled.isEmpty, additions == nil { enabled = ["workstation"] }
        for name in enabled + extra { selected.insert(name); reasons[name, default: []].append("explicit selection") }
        selected.subtract(disabled)
        let user = Choice(.object(try options(setup["options"] ?? .object([:]))))
        let overrideValues = try options(overrides)
        let merged = overrideValues.isEmpty ? user : user.overlay(Choice(.object(overrideValues)))
        if case .map(let values) = merged {
            for (name, value) in values { choices[name] = choices[name].map { $0.overlay(value) } ?? value }
        }
        var ordered: [String] = [], visited = Set<String>()
        func include(_ name: String) throws {
            guard !disabled.contains(name) else { throw ManifestError(.disabledDependency) }
            if visited.contains(name) { return }; visited.insert(name)
            for parent in definitions[name]!.object!["requires"]!.array! {
                reasons[parent.string!, default: []].append("required by " + name); try include(parent.string!)
            }
            ordered.append(name)
        }
        for name in order where selected.contains(name) { try include(name) }
        var configs: [String: ManifestValue] = [:], packages: [String: [String]] = [:], mise: [String: ManifestValue] = [:]
        for name in ordered {
            let config = try configuration(name, options: choices[name]?.plain().object ?? [:])
            let (requested, tools) = try requirements(name, config: config)
            configs[name] = .object(config)
            for package in requested { packages[package, default: []].append(name) }
            for (tool, selector) in tools {
                var item = mise[tool]?.object ?? ["selector": selector, "features": .array([])]
                guard item["selector"] == selector else { throw ManifestError(.conflict) }
                item["features"] = .array(item["features"]!.array! + [.string(name)]); mise[tool] = .object(item)
            }
        }
        for (package, tool) in catalogue["package_tools"]!.object! where packages[package] != nil && mise[tool.string!] != nil { throw ManifestError(.providerConflict) }
        return ResolvedFeatures(document: .object([
            "schema_version": .integer(1), "profiles": .array(chosenProfiles.map(ManifestValue.string)),
            "features": .array(ordered.map(ManifestValue.string)), "options": .object(configs),
            "reasons": .object(Dictionary(uniqueKeysWithValues: ordered.map { ($0, .array(Set(reasons[$0] ?? []).sorted().map(ManifestValue.string))) })),
            "packages": .object(packages.mapValues { .array($0.map(ManifestValue.string)) }), "mise": .object(mise), "sources": .array(sources),
            "effects": effects(configs: configs, hasMise: !mise.isEmpty),
            "limits": .array([.string("Selectors may move; guest package and ARM64 tool availability are checked in the guest."),
                              .string("No authentication, project hooks, project dependencies or application services are configured.")])]))
    }
}
