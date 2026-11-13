import Foundation
import Testing
@testable import DevVMProvisioningCore

/// Disposable UUID planning roots only; no guest, network or VM storage is touched.
private final class LayoutFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ name: String, _ data: Data) throws { try data.write(to: root.appendingPathComponent(name)) }
    /// Plans `profiles` with an optional layout file, the way the manager writes its selection.
    func plan(profiles: [String], layout: Data?, disable: [String] = [], lean: Bool = false) throws -> SetupPlan {
        var setup = "setup:\n  profiles: [\(profiles.joined(separator: ", "))]\n"
        if !disable.isEmpty { setup += "  features: {disable: [\(disable.joined(separator: ", "))]}\n" }
        if let layout {
            try write(".omarchy-manager-layout.lua", layout)
            setup += "  options: {workstation: {layout: .omarchy-manager-layout.lua}}\n"
        }
        let vm = lean ? "vm: {lean_developer: true}\n" : ""
        try write("vm.yml", Data(("schema_version: 1\nid: fixture\n" + vm + setup).utf8))
        return try SetupPlanner.plan(repository: root)
    }
}

private extension SetupPlan {
    var features: [String] { document.object!["features"]!.object!["features"]!.array!.compactMap(\.string) }
    func list(_ feature: String, _ key: String) -> [String]? {
        document.object!["features"]!.object!["options"]!.object![feature]?.object?[key]?.array?.compactMap(\.string)
    }
    var packages: Set<String> { Set(document.object!["features"]!.object!["packages"]!.object!.keys) }
    var layout: [String: ManifestValue]? { document.object!["layout"]?.object }
    func applications(_ key: String) -> [String] { layout?[key]?.array?.compactMap { $0.object?["application"]?.string } ?? [] }
}

/// The issue's table: what each bundled layout needs from setup.
private let expected: [LayoutExampleID: (installs: [String: (String, [String])], missing: [String])] = [
    .fourTerminals: ([:], []),
    .terminalBrowser: (["Chromium": ("browsers", ["chromium"])], []),
    .vscodeBrowser: (["VS Code": ("editors", ["vscode"]), "Chromium": ("browsers", ["chromium"])], []),
    .claudeWorkspace: (["Chromium": ("browsers", ["chromium"])], ["Claude Desktop"]),
    .multiWorkspace: (["VS Code": ("editors", ["vscode"]), "Chromium": ("browsers", ["chromium"])], ["Claude Desktop"]),
    .claudeBrowserCodeTerminals: (["VS Code": ("editors", ["vscode"]), "Chromium": ("browsers", ["chromium"])], ["Claude Desktop"]),
    .smallScreen: (["VS Code": ("editors", ["vscode"]), "Chromium": ("browsers", ["chromium"])], ["Claude Desktop"]),
]

@Test func catalogueNeedsMatchTheIssueTable() throws {
    let examples = try LayoutExamples.catalogue()
    #expect(Set(examples.map(\.id)) == Set(expected.keys))
    for example in examples {
        let want = try #require(expected[example.id])
        let installs = example.needs.filter { $0.feature != nil }
        #expect(Dictionary(uniqueKeysWithValues: installs.map { ($0.application, $0.feature!) }) == want.installs.mapValues(\.0))
        for need in installs { #expect(need.options?.values.flatMap { $0 } == want.installs[need.application]?.1) }
        #expect(example.needs.filter { $0.feature == nil }.map(\.application) == want.missing)
    }
}

@Test(arguments: LayoutExampleID.allCases, [["developer"], ["web"]])
func layoutsAddExactlyWhatProfilesLack(_ id: LayoutExampleID, _ profiles: [String]) throws {
    let fixture = try LayoutFixture()
    let base = try fixture.plan(profiles: profiles, layout: nil)
    let plan = try fixture.plan(profiles: profiles, layout: LayoutExamples.source(id))
    let want = try #require(expected[id])
    let report = try #require(plan.layout)
    #expect(report["example"] == .string(id.rawValue))

    var newFeatures = Set<String>(), adds: [String] = [], present: [String] = []
    for (application, (feature, items)) in want.installs {
        let before = base.features.contains(feature) ? base.list(feature, feature == "editors" ? "editors" : "browsers") ?? [] : []
        let key = feature == "editors" ? "editors" : "browsers"
        // Lists add to the effective value: Developer's Neovim stays beside the layout's VS Code.
        #expect(plan.list(feature, key) == before + items.filter { !before.contains($0) })
        if !base.features.contains(feature) { newFeatures.insert(feature) }
        if items.allSatisfy(before.contains) { present.append(application) } else { adds.append(application) }
    }
    #expect(Set(plan.features).subtracting(base.features) == newFeatures)
    #expect(Set(base.features).isSubset(of: Set(plan.features)))
    #expect(Set(plan.applications("adds")) == Set(adds))
    #expect(Set(plan.applications("already_selected")) == Set(present))
    #expect(plan.applications("not_installed") == want.missing)
    // Nothing else changes: every other feature keeps its exact configuration.
    let options = plan.document.object!["features"]!.object!["options"]!.object!
    let baseOptions = base.document.object!["features"]!.object!["options"]!.object!
    for (name, value) in baseOptions where name != "workstation" && !want.installs.values.contains(where: { $0.0 == name }) {
        #expect(options[name] == value)
    }
    if profiles == ["web"] { #expect(!plan.applications("adds").contains("Chromium")) }
}

@Test func developerVSCodeLayoutKeepsNeovimAndReportsPackages() throws {
    let plan = try LayoutFixture().plan(profiles: ["developer"], layout: LayoutExamples.source(.vscodeBrowser))
    #expect(plan.list("editors", "editors") == ["neovim", "vscode"])
    #expect(plan.list("browsers", "browsers") == ["chromium"])
    let adds = try #require(plan.layout?["adds"]?.array)
    let vscode = try #require(adds.first { $0.object?["application"] == .string("VS Code") }?.object)
    #expect(vscode["items"] == .array([.string("vscode")]))
    #expect(vscode["packages"] == .array([.string("visual-studio-code-bin")]))
    let reasons = plan.document.object!["features"]!.object!["reasons"]!.object!
    #expect(reasons["editors"]?.array?.contains(.string("layout vscode-browser")) == true)
    #expect(reasons["browsers"] == .array([.string("layout vscode-browser")]))
}

@Test func switchingOrClearingALayoutDropsWhatItAdded() throws {
    let fixture = try LayoutFixture()
    let none = try fixture.plan(profiles: ["developer"], layout: nil)
    let vscode = try fixture.plan(profiles: ["developer"], layout: LayoutExamples.source(.vscodeBrowser))
    #expect(vscode.features.contains("browsers"))
    let terminals = try fixture.plan(profiles: ["developer"], layout: LayoutExamples.source(.fourTerminals))
    #expect(terminals.features == none.features)
    #expect(terminals.list("editors", "editors") == ["neovim"])
    #expect(terminals.layout?["adds"] == .array([]))
    let terminal = try fixture.plan(profiles: ["developer"], layout: LayoutExamples.source(.terminalBrowser))
    #expect(terminal.list("editors", "editors") == ["neovim"])
    #expect(!terminal.packages.contains("visual-studio-code-bin"))
}

@Test func onlyByteIdenticalBundledExamplesBringTheirApps() throws {
    var edited = try LayoutExamples.source(.vscodeBrowser)
    edited.append(contentsOf: Data("\n-- local tweak\n".utf8))
    let fixture = try LayoutFixture()
    let none = try fixture.plan(profiles: ["developer"], layout: nil)
    let custom = try fixture.plan(profiles: ["developer"], layout: edited)
    #expect(custom.layout == nil)
    #expect(custom.features == none.features)
    #expect(custom.list("editors", "editors") == ["neovim"])
}

@Test func anOwnerDisabledFeatureIsReportedNotInstalled() throws {
    let plan = try LayoutFixture().plan(profiles: ["developer"], layout: LayoutExamples.source(.vscodeBrowser), disable: ["browsers"])
    #expect(!plan.features.contains("browsers"))
    #expect(plan.list("editors", "editors") == ["neovim", "vscode"])
    let missing = try #require(plan.layout?["not_installed"]?.array)
    #expect(missing == [.object(["application": .string("Chromium"), "feature": .string("browsers"), "reason": .string("disabled")])])
}

@Test func leanTrimKeepsLayoutAddedApps() throws {
    let plan = try LayoutFixture().plan(profiles: ["developer"], layout: LayoutExamples.source(.vscodeBrowser), lean: true)
    #expect(plan.packages.isSuperset(of: ["chromium", "visual-studio-code-bin"]))
    let removals = plan.document.object!["requirements"]!.object!["removals"]!.array!.compactMap(\.string)
    #expect(!removals.contains("chromium") && !removals.contains("visual-studio-code-bin"))
}

@Test func layoutNeedsCanOnlyAddToBuiltinLists() throws {
    let resolver = try Resolver(catalogues: [])
    let apps = ["VS Code", "Chromium", "Claude Desktop"]
    try LayoutExamples.validate([LayoutNeed(application: "VS Code", feature: "editors", options: ["editors": ["vscode"]]),
                                 LayoutNeed(application: "Claude Desktop", feature: nil, options: nil)], applications: apps, resolver: resolver)
    for need in [LayoutNeed(application: "VS Code", feature: "missing", options: ["editors": ["vscode"]]),
                 LayoutNeed(application: "VS Code", feature: "workstation", options: ["oh_my_zsh_plugins": ["git"]]),
                 LayoutNeed(application: "VS Code", feature: "docker", options: ["access": ["native"]]),
                 LayoutNeed(application: "VS Code", feature: "editors", options: ["editors": ["emacs"]]),
                 LayoutNeed(application: "VS Code", feature: "editors", options: [:]),
                 LayoutNeed(application: "VS Code", feature: "editors", options: nil),
                 LayoutNeed(application: "Claude Desktop", feature: nil, options: ["editors": ["vscode"]]),
                 LayoutNeed(application: "Obsidian", feature: "editors", options: ["editors": ["vscode"]])] {
        #expect(throws: ManifestError.self) { try LayoutExamples.validate([need], applications: apps, resolver: resolver) }
    }
}
