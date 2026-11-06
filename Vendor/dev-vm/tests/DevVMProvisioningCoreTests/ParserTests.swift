import CryptoKit
import Foundation
import Testing
@testable import DevVMProvisioningCore

private func yaml(_ source: String) throws -> ManifestValue {
    try PlainDataParser.parse(Data(source.utf8), format: .yaml)
}
private func manifest(_ suffix: String = "") throws -> SetupManifest {
    try SetupManifest.parse(Data(("schema_version: 1\nid: example\n" + suffix).utf8), format: .yaml)
}

@Test func exampleAndDefaults() throws {
    let example = try #require(Bundle.module.url(forResource: "example", withExtension: "yml", subdirectory: "Fixtures"))
    let parsed = try SetupManifest.read(example)
    #expect(parsed.id == "example")
    #expect(parsed.vm.cpus == 8)
    #expect(parsed.vm.factory == "official")
    #expect(parsed.dotfiles.count == 2)
    #expect(parsed.tasks.count == 3)
    #expect(parsed.assets == ["templates"])
    let defaults = try manifest()
    #expect(defaults.vm.memoryGiB == 20)
    #expect(defaults.vm.diskGiB == 64)
    #expect(defaults.vm.packages == [])
    #expect(!defaults.vm.leanDeveloper)
    #expect(defaults.vm.factory == nil)
}

@Test func plainScalarsAndOpaqueStrings() throws {
    #expect(try yaml("[true, false, yes, OFF, null, ~, 123, -4, 1.5, 1e3]") ==
            .array([.bool(true), .bool(false), .bool(true), .bool(false), .null, .null,
                    .integer(123), .integer(-4), .number(1.5), .number(1000)]))
    #expect(try yaml("['yes', '0644', '2026-01-01', '&anchor', '*alias', '!tag']") ==
            .array([.string("yes"), .string("0644"), .string("2026-01-01"),
                    .string("&anchor"), .string("*alias"), .string("!tag")]))
    #expect(try yaml("script: |\n  &anchor *alias !tag\n") == .object(["script": .string("&anchor *alias !tag\n")]))
    #expect(try yaml("x: 'café 🚀' # comment\ny: []\nz: {}") ==
            .object(["x": .string("café 🚀"), "y": .array([]), "z": .object([:])]))
}

@Test(arguments: [
    "a: 1\na: 2", "a: {b: 1, b: 2}", "{yes: value}", "{1: value}", "{null: value}",
    "{[a]: value}", "a: &x [1, 2]", "a: *x", "&x {a: 1}", "a: !custom hi", "a: !!str 1",
    "a: !<tag:example.org,2026:x> hi", "a: {<<: {x: 1}}", "a: {'<<': 1}",
    "%YAML 1.1\n---\na: 1", "%TAG !e! tag:example.org,2026:\n---\na: 1",
    "---\na: 1\n---\nb: 2", "a: '{{ secret }}'", "a: '{% x %}'", "a: '{# x #}'",
    "a: .inf", "a: -.Inf", "a: .NaN", "a: 1e999", "a: 9223372036854775808",
    "a: 012", "a: 0xFF", "a: 0b10", "a: 1_000", "a: 1_000.5", "a: 1:20", "a: 2026-01-01", "a: ["
]) func rejectsUnsafePlainData(source: String) {
    #expect(throws: ManifestError.self) { try yaml(source) }
}

@Test(arguments: ["{'a':1}", "{a:1}", "{\"a\":1,}", "{\"a\":1,// hi\n\"b\":2}",
                  "{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}", "[NaN]", "[01]", "[+1]", "[.5]",
                  "[\"\\uD800\"]", "[\"\\uDC00\"]", "[\"{{secret}}\"]", "{\"<<\":{}}", "[1e999]", "[9223372036854775808]"])
func jsonDoesNotFallback(source: String) {
    #expect(throws: ManifestError.self) { try PlainDataParser.parse(Data(source.utf8), format: .json) }
}

@Test func jsonAndYAMLAgree() throws {
    let json = Data(#"{"schema_version":1,"id":"example","vm":{"cpus":4},"vars":{"enabled":true,"text":"yes","empty":null}}"#.utf8)
    #expect(try PlainDataParser.parse(json, format: .json) == PlainDataParser.parse(json, format: .yaml))
    #expect(try SetupManifest.parse(json, format: .json).vm.cpus == 4)
    #expect(try PlainDataParser.parse(Data(#"{"emoji":"\uD83D\uDE80"}"#.utf8), format: .json) == .object(["emoji": .string("🚀")]))
}

@Test func inputAndDepthBounds() throws {
    #expect(try yaml(String(repeating: "[", count: 30) + "0" + String(repeating: "]", count: 30)) != .null)
    #expect(throws: ManifestError.self) {
        try yaml(String(repeating: "[", count: 31) + "0" + String(repeating: "]", count: 31))
    }
    #expect(throws: ManifestError.self) { try yaml(String(repeating: "[", count: 31) + String(repeating: "]", count: 31)) }
    #expect(throws: ManifestError.self) {
        try PlainDataParser.parse(Data((String(repeating: "[", count: 31) + String(repeating: "]", count: 31)).utf8), format: .json)
    }
    #expect(throws: ManifestError.self) { try yaml(String(repeating: "[", count: 100_000)) }
    #expect(try yaml(String(repeating: "x", count: PlainDataParser.maximumBytes)).string?.count == PlainDataParser.maximumBytes)
    #expect(throws: ManifestError.self) { try yaml(String(repeating: "x", count: PlainDataParser.maximumBytes + 1)) }
    #expect(throws: ManifestError.self) { try PlainDataParser.parse(Data([0xff]), format: .yaml) }
}

@Test(arguments: [
    "extra: true", "vm: {extra: true}", "vm: {cpus: true}", "vm: {cpus: 4.0}", "vm: {cpus: 3}",
    "vm: {memory_gib: 2}", "vm: {disk_gib: 32}", "vm: {name: ''}", "vm: {name: \"secret\\nname\"}",
    "vm: {lean_developer: 1}", "vm: {packages: ['pkg:bad;command']}",
    "vm: {packages: ['pkg:foo', foo]}", "vm: {factory: ''}", "vars: []", "tasks: command",
    "setup: {unknown: true}", "setup: {schema_version: true}", "setup: {profiles: [missing]}",
    "setup: {features: {enable: [cli, builtin.cli]}}", "setup: {features: {enable: [missing]}}",
    "setup: {options: {cli: {unknown: true}}}", "setup: {options: {cli: {packages: [bad, bad]}}}",
    "setup: {options: {docker: {access: invalid}}}", "setup: {options: {keyring: {seahorse: 1}}}",
    "setup: {options: {cli: {}, builtin.cli: {}}}", "setup: {catalogues: ['../outside.json']}",
    "tasks: [{name: all, file: tasks.yml}]", "tasks: [{name: x, file: a}, {name: x, file: b}]",
    "tasks: [{name: x, file: /outside}]", "tasks: [{name: x, file: .git/config}]",
    "assets: ['x//y']", "assets: ['.']", "assets: ['x/../y']", "assets: ['x\\y']",
    "dotfiles: [{source: a, target: ~/.ssh/config}]", "dotfiles: [{source: a, target: ~/.local/state/dev-vm/record}]",
    "dotfiles: [{source: a, target: '~another-user/file'}]",
    "dotfiles: [{source: a, target: x, mode: 644}]", "dotfiles: [{source: a, target: x, mode: '0999'}]",
    "dotfiles: [{source: a, target: x}, {source: b, target: x/y}]"
]) func rejectsInvalidManifest(suffix: String) {
    #expect(throws: ManifestError.self) { try manifest(suffix) }
}

@Test(arguments: ["{}", "[]", "schema_version: 2\nid: x", "schema_version: true\nid: x", "schema_version: 1\nid: Bad"])
func rejectsInvalidRoot(source: String) {
    #expect(throws: ManifestError.self) { try SetupManifest.parse(Data(source.utf8), format: .yaml) }
}

@Test func customTaskReferencesAreOpaqueAndExtensionsUnresolved() throws {
    let m = try manifest("tasks: [{name: projects, file: does-not-exist.yml}]\nsetup: {profiles: [team.web], features: {enable: [team.editor]}, options: {team.editor: {tools: {node: '22'}}}}")
    #expect(m.tasks.first?.file == "does-not-exist.yml")
    #expect(m.selection.object?["profiles"] == .array([.string("team.web")]))
    // Accepted only as bounded text here. TOML semantics belong to the resolution step.
    _ = try manifest("setup: {options: {workstation: {starship_config: 'not = valid = toml'}}}")
}

@Test func fileBoundaryAndSanitizedErrors() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) } // Only our disposable fixture directory.
    let file = root.appendingPathComponent("manifest.json")
    try Data(#"{"schema_version":1,"id":"example"}"#.utf8).write(to: file)
    #expect(try SetupManifest.read(file).id == "example")
    let link = root.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(throws: ManifestError.self) { try SetupManifest.read(link) }
    let directory = root.appendingPathComponent("directory.yml")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    #expect(throws: ManifestError.self) { try SetupManifest.read(directory) }
    let pipe = root.appendingPathComponent("pipe.yml")
    #expect(mkfifo(pipe.path, 0o600) == 0)
    #expect(throws: ManifestError.self) { try SetupManifest.read(pipe) }
    do {
        _ = try yaml("credentials: [secret-value")
        Issue.record("Expected syntax error")
    } catch let error as ManifestError {
        #expect(error.code == .syntax)
        #expect(!error.description.contains("secret"))
        #expect(!error.description.contains(root.path))
    }
}

@Test func pinnedSourceAndResourceInventory() throws {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let inventory = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("ThirdParty/ParserInventory.json"))) as! [String: Any]
    let files = try #require(inventory["sha256"] as? [String: String])
    for (path, digest) in files {
        let data = try Data(contentsOf: source.appendingPathComponent(path))
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == digest)
    }
    for name in ["selection.schema.json", "catalogue.json"] {
        #expect(try Data(contentsOf: source.appendingPathComponent("omarchy/features/" + name)) ==
                Data(contentsOf: source.appendingPathComponent("Sources/DevVMProvisioningCore/Resources/" + name)))
    }
}

@Test func plainDataOracleFixtures() throws {
    let file = try #require(Bundle.module.url(forResource: "plain-contract", withExtension: "json", subdirectory: "Fixtures"))
    // This test container includes deliberately invalid template text as test input.
    // It is not itself a user manifest.
    let cases = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
    for object in cases {
        let source = try #require(object["source"] as? String)
        let format: ManifestFormat = object["format"] as? String == "json" ? .json : .yaml
        if object["valid"] as? Bool == true {
            let expected = try JSONSerialization.data(withJSONObject: #require(object["expected"]), options: [.fragmentsAllowed])
            #expect(try PlainDataParser.parse(Data(source.utf8), format: format) == PlainDataParser.parse(expected, format: .json))
        } else {
            #expect(throws: ManifestError.self) { try PlainDataParser.parse(Data(source.utf8), format: format) }
        }
    }
}
