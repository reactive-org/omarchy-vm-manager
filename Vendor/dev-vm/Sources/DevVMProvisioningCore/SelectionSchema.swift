import Foundation

/// Internal validator for the finite keyword subset used by the bundled selection schema.
/// This is not a general JSON Schema implementation; unsupported keywords fail closed.
enum SelectionSchema {
    static func resourceDocument(_ name: String) throws -> PlainDocument {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources")
        else { throw ManifestError(.resource) }
        do { return try PlainDataParser.readDocument(url) }
        catch { throw ManifestError(.resource) }
    }
    static func resource(_ name: String) throws -> ManifestValue {
        try resourceDocument(name).value
    }

    static func validate(_ value: ManifestValue) throws {
        guard var root = value.object else { throw ManifestError(.schema) }
        // External setup manifests default the nested selection version to 1.
        root["schema_version"] = root["schema_version"] ?? .integer(1)
        try validate(.object(root), against: resource("selection.schema"))
        let catalogue = try resource("catalogue")
        guard let definitions = catalogue.object,
              let features = definitions["features"]?.object, let profiles = definitions["profiles"]?.object
        else { throw ManifestError(.resource) }
        try references(root["profiles"]?.array ?? [], builtins: Set(profiles.keys))
        let choices = root["features"]?.object ?? [:]
        for key in ["enable", "disable"] {
            try references(choices[key]?.array ?? [], builtins: Set(features.keys))
        }
        // Aliases denote the same option group; accepting both would depend on merge order.
        let optionNames = (root["options"]?.object ?? [:]).keys.map(canonical)
        guard Set(optionNames).count == optionNames.count else { throw ManifestError(.schema) }
    }

    private static func canonical(_ name: String) -> String {
        name.hasPrefix("builtin.") ? String(name.dropFirst(8)) : name
    }
    private static func references(_ values: [ManifestValue], builtins: Set<String>) throws {
        var seen = Set<String>()
        for value in values {
            guard let name = value.string else { throw ManifestError(.schema) }
            let normalized = canonical(name)
            guard seen.insert(normalized).inserted,
                  normalized.contains(".") || builtins.contains(normalized)
            else { throw ManifestError(.schema) }
        }
    }

    static func validate(_ value: ManifestValue, against schemaValue: ManifestValue) throws {
        guard let schema = schemaValue.object else { throw ManifestError(.resource) }
        let supported: Set<String> = ["$schema", "type", "const", "enum", "properties", "patternProperties",
            "additionalProperties", "propertyNames", "required", "items", "uniqueItems", "pattern", "minLength", "maxLength"]
        guard Set(schema.keys).isSubset(of: supported) else { throw ManifestError(.resource) }
        func require(_ condition: Bool) throws { if !condition { throw ManifestError(.schema) } }
        if let type = schema["type"] {
            let names = type.array ?? [type]
            try require(names.contains { candidate in
                switch (candidate.string, value) {
                case ("null", .null), ("boolean", .bool), ("integer", .integer),
                     ("number", .integer), ("number", .number), ("string", .string),
                     ("array", .array), ("object", .object): true
                default: false
                }
            })
        }
        if let constant = schema["const"] { try require(value == constant) }
        if let choices = schema["enum"]?.array { try require(choices.contains(value)) }
        if case .string(let text) = value {
            if let pattern = schema["pattern"]?.string { try require(matches(text, pattern)) }
            if let minimum = schema["minLength"]?.integer { try require(text.unicodeScalars.count >= minimum) }
            if let maximum = schema["maxLength"]?.integer { try require(text.unicodeScalars.count <= maximum) }
        }
        if case .array(let items) = value {
            if schema["uniqueItems"] == .bool(true) { try require(Set(items).count == items.count) }
            if let itemSchema = schema["items"] {
                for item in items { try validate(item, against: itemSchema) }
            }
        }
        if case .object(let object) = value {
            if let required = schema["required"]?.array {
                for key in required { try require(key.string.map { object[$0] != nil } == true) }
            }
            let properties = schema["properties"]?.object ?? [:]
            let patterns = schema["patternProperties"]?.object ?? [:]
            for (key, item) in object {
                if let names = schema["propertyNames"] { try validate(.string(key), against: names) }
                var matched = false
                if let rule = properties[key] { try validate(item, against: rule); matched = true }
                for (pattern, rule) in patterns where matches(key, pattern) {
                    try validate(item, against: rule); matched = true
                }
                if !matched, let extra = schema["additionalProperties"] {
                    if extra == .bool(false) { throw ManifestError(.schema) }
                    if extra != .bool(true) { try validate(item, against: extra) }
                }
            }
        }
    }
}
