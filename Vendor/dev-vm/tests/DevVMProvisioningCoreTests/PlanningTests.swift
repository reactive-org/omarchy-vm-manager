import Darwin
import Foundation
import Testing
@testable import DevVMProvisioningCore

private final class PlanningFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
    deinit { try? FileManager.default.removeItem(at: root) } // UUID fixture roots only, never VM storage.
    func file(_ name: String, _ data: Data, mode: mode_t = 0o644) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        #expect(chmod(url.path, mode) == 0)
    }
    func file(_ name: String, _ text: String, mode: mode_t = 0o644) throws { try file(name, Data(text.utf8), mode: mode) }
    func manifest(_ extra: String = "") throws {
        try file("vm.yml", "schema_version: 1\nid: fixture\n" + extra)
    }
    func plan() throws -> SetupPlan { try SetupPlanner.plan(repository: root) }
}

@Test func planningContractFixtures() throws {
    let url = try #require(Bundle.module.url(forResource: "planning-contract", withExtension: "json", subdirectory: "Fixtures"))
    let cases = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    for row in cases {
        let fixture = try PlanningFixture()
        let files = try #require(row["files"] as? [String: String])
        for (name, text) in files { try fixture.file(name, text) }
        try fixture.file("vm.json", JSONSerialization.data(withJSONObject: #require(row["manifest"])))
        if row["valid"] as? Bool == true {
            let plan = try SetupPlanner.plan(repository: fixture.root, manifest: "vm.json")
            #expect(plan.document.object?["execution_available"] == .bool(false))
            #expect(plan.identity.count == 64)
            try plan.verify(in: fixture.root)
        } else {
            #expect(throws: ManifestError.self) { try SetupPlanner.plan(repository: fixture.root, manifest: "vm.json") }
        }
    }
}

@Test func immutableSnapshotsAndIdentity() throws {
    let fixture = try PlanningFixture()
    try fixture.file("assets/data", "before", mode: 0o600)
    try fixture.file("unselected", "private-canary")
    try fixture.manifest("assets: [assets]\nvars: {synthetic: private-canary}\n")
    let plan = try fixture.plan()
    #expect(plan.snapshot.data(for: "assets/data") == Data("before".utf8))
    #expect(plan.snapshot.data(for: "unselected") == nil)
    #expect(plan.identity == (try fixture.plan().identity))
    #expect(!String(decoding: try canonicalData(plan), as: UTF8.self).contains("private-canary"))
    try fixture.file("unselected", "an unrelated edit")
    try plan.verify(in: fixture.root)
    try fixture.file("assets/data", "after", mode: 0o600)
    #expect(throws: ManifestError.self) { try plan.verify(in: fixture.root) }
    #expect(plan.snapshot.data(for: "assets/data") == Data("before".utf8))
    #expect(plan.identity != (try fixture.plan().identity))
    try fixture.file("assets/data", "before", mode: 0o600)
    try plan.verify(in: fixture.root)
    try fixture.file("assets/new", "added")
    #expect(throws: ManifestError.self) { try plan.verify(in: fixture.root) }
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("assets/new"))
    #expect(chmod(fixture.root.appendingPathComponent("assets/data").path, 0o644) == 0)
    #expect(throws: ManifestError.self) { try plan.verify(in: fixture.root) }
    #expect(chmod(fixture.root.appendingPathComponent("assets/data").path, 0o600) == 0)
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("assets/data"))
    #expect(throws: ManifestError.self) { try plan.verify(in: fixture.root) }
}

@Test func snapshotIncludesEmptyDirectoriesAndRejectsRootReplacement() throws {
    let fixture = try PlanningFixture()
    try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("assets/empty"), withIntermediateDirectories: true)
    try fixture.manifest("assets: [assets]")
    let plan = try fixture.plan()
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("assets/empty"))
    #expect(throws: ManifestError.self) { try plan.verify(in: fixture.root) }
    let other = try PlanningFixture()
    try other.manifest("assets: [assets]")
    try FileManager.default.createDirectory(at: other.root.appendingPathComponent("assets/empty"), withIntermediateDirectories: true)
    #expect(throws: ManifestError.self) { try plan.verify(in: other.root) }
}

@Test func descriptorTraversalRejectsSymlinksAndSpecialFiles() throws {
    let fixture = try PlanningFixture(), outside = try PlanningFixture()
    try outside.file("private", "outside-canary")
    try fixture.file("assets/ok", "selected")
    let link = fixture.root.appendingPathComponent("assets/link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.root.appendingPathComponent("private"))
    try fixture.manifest("assets: [assets]")
    #expect(throws: ManifestError.self) { try fixture.plan() }
    try FileManager.default.removeItem(at: link)
    #expect(mkfifo(link.path, 0o600) == 0)
    #expect(throws: ManifestError.self) { try fixture.plan() }
    try FileManager.default.removeItem(at: link)
    try fixture.file("assets/.git/config", "not an asset")
    #expect(throws: ManifestError.self) { try fixture.plan() }
    let parent = fixture.root.appendingPathComponent("parent")
    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside.root)
    try fixture.manifest("assets: [parent/private]")
    #expect(throws: ManifestError.self) { try fixture.plan() }
    try fixture.manifest()
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("vm.yml"))
    try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("vm.yml"), withDestinationURL: outside.root.appendingPathComponent("private"))
    #expect(throws: ManifestError.self) { try fixture.plan() }
}

@Test func snapshotLimits() throws {
    let fixture = try PlanningFixture()
    try fixture.manifest("assets: [large]")
    let path = fixture.root.appendingPathComponent("large").path
    let fd = open(path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
    #expect(fd >= 0)
    defer { close(fd) }
    #expect(ftruncate(fd, off_t(SourceSnapshot.maximumBytes + 1)) == 0)
    #expect(throws: ManifestError.self) { try fixture.plan() }
    #expect(ftruncate(fd, off_t(SourceSnapshot.maximumBytes)) == 0)
    // Aggregate includes the manifest, so this exact-size asset also exceeds the cap.
    #expect(throws: ManifestError.self) { try fixture.plan() }
    try fixture.manifest("assets: [many]")
    for n in 0..<SourceSnapshot.maximumFiles { try fixture.file("many/f\(n)", "") }
    #expect(throws: ManifestError.self) { try fixture.plan() }
}

@Test func graphDepthAndOrdering() throws {
    let features = Dictionary(uniqueKeysWithValues: (0..<31).map { n in
        ("f\(n)", ManifestValue.object(["description": .string("fixture"), "requires": .array(n == 30 ? [] : [.string("team.f\(n + 1)")])]))
    })
    let data = try canonicalData(ManifestValue.object(["schema_version": .integer(1), "namespace": .string("team"), "features": .object(features)]))
    let catalogue = try FeatureCatalogue(data: data, format: .json, sourceID: "catalogue.json")
    #expect(throws: ManifestError.self) { try FeaturePlanner.resolve(catalogues: [catalogue]) }
    let yaml = Data("schema_version: 1\nnamespace: team\nfeatures:\n  z:\n    description: Z\n  a:\n    description: A\n".utf8)
    let ordered = try FeatureCatalogue(data: yaml, format: .yaml, sourceID: "catalogue.yml")
    let plan = try FeaturePlanner.resolve(selection: .object(["features": .object(["enable": .array([.string("team.a"), .string("team.z")])])]), catalogues: [ordered])
    #expect(plan.features == ["team.z", "team.a"])
}

@Test func nativeTOMLAndEffectiveOptions() throws {
    for text in ["x = 1\nx = 2", "bad = [", "x = " + String(repeating: "[", count: 31) + "0" + String(repeating: "]", count: 31)] {
        #expect(throws: ManifestError.self) { try validatePromptTOML(text) }
    }
    for text in ["x = [1, 2]\n", "s = '''[literal]'''\na = {b = true}", "# [comment]\nx = '[string]'", "x = 2026-01-01"] {
        try validatePromptTOML(text)
    }
    #expect(throws: ManifestError.self) { try validatePromptTOML(String(repeating: "#🚀", count: 14000)) }
    #expect(throws: ManifestError.self) { try validatePromptTOML(String(repeating: "key.", count: 30) + "key = 1") }
    let override: ManifestValue = .object(["languages": .object(["tools": .object(["pnpm": .null, "node": .string("24")])])])
    let plan = try FeaturePlanner.resolve(profiles: ["web"], overrides: override)
    #expect(plan.options["languages"]?.object?["tools"] == .object(["node": .string("24")]))
    #expect(try FeaturePlanner.resolve(features: []).features.isEmpty)
}

@Test func engineInventoryAndRelocatablePlanIdentity() throws {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let engine = try SetupPlanner.engine()
    for (path, sha) in engine.object!["sources"]!.object! {
        #expect(.string(digest(try Data(contentsOf: source.appendingPathComponent(path)))) == sha)
    }
    let first = try PlanningFixture(), second = try PlanningFixture()
    for fixture in [first, second] {
        try fixture.file("tasks.yml", "not even YAML: [ {{ synthetic }}")
        try fixture.manifest("tasks: [{name: custom, file: tasks.yml}]")
    }
    let a = try first.plan(), b = try second.plan()
    #expect(a.identity == b.identity)
    #expect(a.snapshot.data(for: "tasks.yml") == Data("not even YAML: [ {{ synthetic }}".utf8))
    var object = try #require(a.document.object)
    let expected = object.removeValue(forKey: "plan_digest")
    #expect(expected == .string(digest(try canonicalData(ManifestValue.object(object)))))
    #expect(!String(decoding: try canonicalData(a), as: UTF8.self).contains(first.root.path))
}
