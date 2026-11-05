import Darwin
import Foundation
import Testing
@testable import DevVMProvisioningCore

private actor FactoryFakeProcess: FactoryBuildProcessRunning {
    var commands: [[String]] = []
    var remote = false, wrongArch = false, failImage = false, foreign = false, lostCreate = false, renamed = false, changedEngine = false
    var volume = false, container = false
    let root: URL
    let token: String
    init(root: URL, jobID: UUID) { self.root = root; token = jobID.uuidString.lowercased() }
    func configure(remote: Bool = false, wrongArch: Bool = false, failImage: Bool = false, foreign: Bool = false, lostCreate: Bool = false, renamed: Bool = false, changedEngine: Bool = false) { self.lostCreate = lostCreate; self.renamed = renamed; self.changedEngine = changedEngine; self.remote = remote; self.wrongArch = wrongArch; self.failImage = failImage; self.foreign = foreign }
    func run(_ command: FactoryBuildCommand, output: @escaping @Sendable (Data) -> Void) async throws -> FactoryBuildCommandResult {
        if command.executable.path == "/usr/bin/tar" { return try await LocalFactoryBuildProcess().run(command, output: output) }
        commands.append(command.arguments)
        var a = command.arguments
        if a.first == "--host" { a.removeFirst(2) }
        func response(_ object: Any) throws -> FactoryBuildCommandResult { .init(status: 0, output: try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) }
        if a == ["context", "show"] { return .init(status: 0, output: Data("fixture\n".utf8)) }
        if a.starts(with: ["context", "inspect"]) { return try response(remote ? "tcp://example.invalid:2375" : "unix:///private/tmp/fixture.sock") }
        if a.first == "info" { return try response(["architecture": wrongArch ? "amd64" : "aarch64", "os": "linux", "id": changedEngine ? "changed-engine" : "synthetic-engine"]) }
        if a.first == "build" { let i = a.firstIndex(of: "--iidfile")!; try Data(("sha256:" + String(repeating: "a", count: 64)).utf8).write(to: URL(fileURLWithPath: a[i+1])); return .init(status: 0) }
        if a.starts(with: ["volume", "create"]) { volume = true; return .init(status: 0, output: Data(("omarchy-factory-" + token).utf8)) }
        if a.first == "create" { container = true; if lostCreate { throw FactoryBuildFailure.cancelled }; return .init(status: 0, output: Data(String(repeating: "b", count: 64).utf8)) }
        if a.first == "start" { output(Data("synthetic image output\n".utf8)); return .init(status: failImage ? 1 : 0) }
        if a.first == "wait" { return .init(status: 0, output: Data("0\n".utf8)) }
        if a.count >= 2, a[1] == "ls" { let exists = a[0] == "volume" ? volume : container && (!renamed || a.contains("{{json .ID}}")); return .init(status: 0, output: exists ? try JSONSerialization.data(withJSONObject: a.contains("{{json .ID}}") ? String(repeating: "b", count: 64) : "omarchy-factory-" + token, options: .fragmentsAllowed) : Data()) }
        if a.count >= 2, a[1] == "inspect" { var object: [String: Any] = ["id": a[0] == "container" ? String(repeating: "b", count: 64) : "omarchy-factory-" + token, "labels": ["dev.omarchy.factory-build": foreign ? "foreign" : token]]; if a.contains(where: { $0.contains("running") }) { object["running"] = false }; return try response(object) }
        if a.count >= 2, a[1] == "rm" { if a[0] == "container" { container = false } else { volume = false }; return .init(status: 0) }
        throw FactoryBuildFailure.invalidRequest
    }
}
private struct FactoryFakeDownload: FactoryBuildDownloading {
    func download(_ input: FactoryRecipe.Download, to destination: URL) async throws { try Data("fixture".utf8).write(to: destination); chmod(destination.path, 0o600) }
}
@Suite("Factory builder — fake Docker and disposable local files", .serialized) struct FactoryBuildTests {
    @Test func bundledRecipeAndPlanAreOfflineAndPinned() throws {
        let recipe = try FactoryRecipe(), plan = try FactoryBuildPlan()
        try recipe.verify()
        #expect(plan.sizeGiB == 20 && plan.minimumArtifactBytes == 24 * 1_073_741_824)
        #expect(plan.privilegedContainer && !plan.guestBootTested)
        #expect(recipe.downloads.count == 3)
        for size in [0,19,129] { #expect(throws: FactoryBuildFailure.self) { _ = try FactoryBuildPlan(sizeGiB: size) } }
        #expect(throws: FactoryBuildFailure.self) { _ = try FactoryBuildPlan(name: "bad\nname") }
    }
    @Test(arguments: ["remote", "architecture"])
    func admissionRejectsUnsupportedEngines(kind: String) async throws {
        let fake = FactoryFakeProcess(root: URL(fileURLWithPath: "/private/tmp"), jobID: UUID())
        await fake.configure(remote: kind == "remote", wrongArch: kind == "architecture")
        let client = try FactoryDockerClient(executable: URL(fileURLWithPath: "/bin/echo"), home: URL(fileURLWithPath: "/private/tmp"), runner: fake)
        await #expect(throws: FactoryBuildFailure.self) { _ = try await client.inspect() }
        #expect(await fake.commands.allSatisfy { !$0.contains("build") && !$0.contains("run") })
    }
    @Test(arguments: ["success", "failed", "foreign", "lost-create", "renamed"])
    func pipelineHasExplicitScopeAndOnlyCleansOwnedResources(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("factory-test-" + UUID().uuidString)
        try factoryDirectory(root, create: true); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("fixture-input"); try factoryDirectory(input, create: true)
        let file = input.appendingPathComponent("upstream/test"); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("template".utf8).write(to: file); chmod(file.path, 0o644)
        try FileManager.default.createDirectory(at: input.appendingPathComponent("profile"), withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("template.tgz")
        _ = try await LocalFactoryBuildProcess().run(.init(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-czf", archive.path, "-C", input.path, "upstream", "profile"], directory: root, environment: ["PATH": "/usr/bin:/bin"]), output: { _ in })
        let recipeData = try JSONSerialization.data(withJSONObject: ["format": 1, "templateSHA256": try factoryFileHash(archive), "files": ["upstream/test": ["sha256": digest(Data("template".utf8)), "mode": 420]], "downloads": (1...3).map { ["name": "input-\($0)", "url": "https://nodejs.org/fixture", "sha256": digest(Data("fixture".utf8))] }, "provenance": ["try_commit": String(repeating: "a", count: 40)]])
        let recipe = try FactoryRecipe(archive: archive, data: recipeData, expected: digest(recipeData)), id = UUID()
        try factoryDirectory(root.appendingPathComponent(id.uuidString), create: true)
        let fake = FactoryFakeProcess(root: root, jobID: id); await fake.configure(failImage: kind == "failed" || kind == "foreign", foreign: kind == "foreign", lostCreate: kind == "lost-create", renamed: kind == "renamed")
        let docker = try FactoryDockerClient(executable: URL(fileURLWithPath: "/bin/echo"), home: root, runner: fake), admission = try await docker.inspect()
        let engine = FactoryBuildEngine(docker: docker, recipe: recipe, downloader: FactoryFakeDownload()), output = FactoryBuildOutput()
        do {
            let result = try await engine.build(.init(fixtureRecipe: digest(recipeData)), jobID: id, root: root, admission: admission, output: output, stage: { _ in })
            #expect(kind == "success" || kind == "renamed")
            #expect(FileManager.default.fileExists(atPath: result.appendingPathComponent("image-build.json").path))
        } catch { #expect(kind != "success" && kind != "renamed"); if kind == "foreign" || kind == "lost-create" { #expect(error as? FactoryBuildFailure == .cleanupRequired) } }
        let commands = await fake.commands
        #expect(commands.contains { $0.contains("--privileged") && $0.contains("linux/arm64") })
        #expect(!commands.contains { $0.contains("prune") })
        if kind == "lost-create" {
            #expect(!commands.contains { $0.contains("start") })
            try await engine.cleanup(jobID: id, admission: admission)
        }
        #expect(commands.filter { $0.contains("rm") && $0.contains("container") }.allSatisfy { $0.last == String(repeating: "b", count: 64) })
        if kind == "foreign" { #expect(!commands.contains { $0.contains("rm") }) }
        else { let volume = await fake.volume, container = await fake.container; #expect(!volume && !container) }
    }
    @Test func changedEngineRefusesMutation() async throws {
        let root = URL(fileURLWithPath: "/private/tmp"), fake = FactoryFakeProcess(root: root, jobID: UUID())
        let client = try FactoryDockerClient(executable: URL(fileURLWithPath: "/bin/echo"), home: root, runner: fake)
        let admission = try await client.inspect()
        await fake.configure(changedEngine: true)
        await #expect(throws: FactoryBuildFailure.engineChanged) { _ = try await client.run(admission, ["build"], directory: root) }
        #expect(await fake.commands.allSatisfy { !$0.contains("build") })
    }
    @Test func outputRingIsBoundedAndReportsGaps() {
        let output = FactoryBuildOutput()
        output.append(Data(repeating: 65, count: 1024 * 1024))
        let page = output.page(after: 0)
        #expect(page.reset && page.bytes.count <= 65536)
    }
    @Test func hostProcessesCancelAndBoundMetadataWithoutLeavingTheirGroup() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let runner = LocalFactoryBuildProcess()
        let task = Task { try await runner.run(.init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"], directory: root, environment: ["PATH": "/usr/bin:/bin"]), output: { _ in }) }
        try await Task.sleep(for: .milliseconds(50)); task.cancel()
        await #expect(throws: FactoryBuildFailure.cancelled) { _ = try await task.value }
        await #expect(throws: FactoryBuildFailure.commandFailed) {
            _ = try await runner.run(.init(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], directory: root, environment: [:], timeoutSeconds: 2), output: { _ in })
        }
        let result = try await runner.run(.init(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["fixture"], directory: root, environment: [:]), output: { _ in })
        #expect(result.status == 0)
    }
}
