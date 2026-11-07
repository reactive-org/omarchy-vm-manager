import Darwin
import Foundation
import Testing
@testable import DevVMProvisioningCore

private actor FactoryFakeProcess: FactoryBuildProcessRunning {
    var commands: [[String]] = []
    var remote = false, wrongArch = false, failImage = false, foreign = false, lostCreate = false, renamed = false, changedEngine = false
    var volume = false, container = false, tamperConfiguration = false
    let root: URL
    let token: String
    init(root: URL, jobID: UUID) { self.root = root; token = jobID.uuidString.lowercased() }
    func configure(remote: Bool = false, wrongArch: Bool = false, failImage: Bool = false, foreign: Bool = false, lostCreate: Bool = false, renamed: Bool = false, changedEngine: Bool = false, tamperConfiguration: Bool = false) { self.tamperConfiguration = tamperConfiguration; self.lostCreate = lostCreate; self.renamed = renamed; self.changedEngine = changedEngine; self.remote = remote; self.wrongArch = wrongArch; self.failImage = failImage; self.foreign = foreign }
    func run(_ command: FactoryBuildCommand, output: @escaping @Sendable (Data) -> Void) async throws -> FactoryBuildCommandResult {
        if command.executable.path == "/usr/bin/tar" { return try await LocalFactoryBuildProcess().run(command, output: output) }
        commands.append(command.arguments)
        var a = command.arguments
        if a.first == "--host" { a.removeFirst(2) }
        var configuration: URL?
        if a.first == "--config" {
            configuration = URL(fileURLWithPath: a[1]); a.removeFirst(2)
            guard configuration == command.directory.appendingPathComponent("docker-config"),
                  command.environment["DOCKER_CONFIG"] == nil,
                  try Data(contentsOf: configuration!.appendingPathComponent("config.json")) == Data("{\"auths\":{\"https://index.docker.io/v1/\":{}}}\n".utf8),
                  try configuration!.appendingPathComponent("config.json").resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  (try FileManager.default.attributesOfItem(atPath: configuration!.appendingPathComponent("config.json").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw FactoryBuildFailure.invalidRequest }
        }
        func response(_ object: Any) throws -> FactoryBuildCommandResult { .init(status: 0, output: try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) }
        if a == ["context", "show"] { return .init(status: 0, output: Data("fixture\n".utf8)) }
        if a.starts(with: ["context", "inspect"]) { return try response(remote ? "tcp://example.invalid:2375" : "unix:///private/tmp/fixture.sock") }
        if a.first == "info" { return try response(["architecture": wrongArch ? "amd64" : "aarch64", "os": "linux", "id": changedEngine ? "changed-engine" : "synthetic-engine"]) }
        if a.first == "build" {
            guard let configuration else { throw FactoryBuildFailure.invalidRequest }
            if tamperConfiguration { try Data("{\"credsStore\":\"synthetic-helper\"}".utf8).write(to: configuration.appendingPathComponent("config.json")) }
            let i = a.firstIndex(of: "--iidfile")!; try Data(("sha256:" + String(repeating: "a", count: 64)).utf8).write(to: URL(fileURLWithPath: a[i+1])); return .init(status: 0)
        }
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
    private func executableFixture(in root: URL, size: Int, name: String = "docker-fixture") throws -> URL {
        let url = root.appendingPathComponent(name)
        // Sparse padding is synthetic data. Never invoke a real Docker binary.
        try Data("#!/bin/sh\nprintf 'large fixture\\n'\nexit 0\n".utf8).write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(size))
        guard chmod(url.path, 0o700) == 0 else { throw FactoryBuildFailure.invalidRequest }
        return url
    }
    @Test(arguments: [33_554_432, 33_554_433, 43_052_752, 134_217_728, 134_217_729])
    func dockerExecutableAdmissionHasItsOwnBoundedLimit(_ size: Int) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("factory-size-" + UUID().uuidString)
        try factoryDirectory(root, create: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try executableFixture(in: root, size: size)
        let fake = FactoryFakeProcess(root: root, jobID: UUID())
        if size > 32 * 1024 * 1024 {
            #expect(throws: SequencingFailure.invalidRequest) { _ = try ProvisioningExecutablePin(executable) }
        } else { _ = try ProvisioningExecutablePin(executable).verify() }
        if size > 128 * 1024 * 1024 {
            #expect(throws: SequencingFailure.invalidRequest) { _ = try FactoryDockerClient(executable: executable, home: root, runner: fake) }
            #expect(await fake.commands.isEmpty)
        } else {
            let client = try FactoryDockerClient(executable: executable, home: root, runner: fake)
            let admission = try await client.inspect()
            try await client.revalidate(admission)
            #expect(await fake.commands.count == 4)
            #expect(client.pin.sha256 == digest(try Data(contentsOf: executable)))
        }
    }
    @Test(arguments: [0, 1_048_583, 43_052_751])
    func largeDockerExecutableMutationRefusesNextFakeCommand(_ offset: Int) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("factory-tamper-" + UUID().uuidString)
        try factoryDirectory(root, create: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try executableFixture(in: root, size: 43_052_752)
        let fake = FactoryFakeProcess(root: root, jobID: UUID())
        let client = try FactoryDockerClient(executable: executable, home: root, runner: fake)
        let admission = try await client.inspect()
        let file = try FileHandle(forWritingTo: executable)
        try file.seek(toOffset: UInt64(offset)); try file.write(contentsOf: Data([88])); try file.close()
        await #expect(throws: SequencingFailure.dependencyChanged) { try await client.revalidate(admission) }
        #expect(await fake.commands.count == 3)
    }
    @Test func largeDockerStillRejectsUnsafePermissionsAndRetargetedSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("factory-permissions-" + UUID().uuidString)
        try factoryDirectory(root, create: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try executableFixture(in: root, size: 43_052_752)
        let fake = FactoryFakeProcess(root: root, jobID: UUID())
        chmod(executable.path, 0o777)
        #expect(throws: SequencingFailure.invalidRequest) { _ = try FactoryDockerClient(executable: executable, home: root, runner: fake) }
        chmod(executable.path, 0o700)
        let alias = root.appendingPathComponent("docker-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
        let client = try FactoryDockerClient(executable: alias, home: root, runner: fake)
        let admission = try await client.inspect()
        let replacement = try executableFixture(in: root, size: 43_052_752, name: "replacement")
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: replacement)
        await #expect(throws: SequencingFailure.dependencyChanged) { try await client.revalidate(admission) }
        #expect(await fake.commands.count == 3)
    }
    @Test func factoryHostRunnerUsesTheLargerPolicyForADisposableScript() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("factory-host-size-" + UUID().uuidString)
        try factoryDirectory(root, create: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try executableFixture(in: root, size: 43_052_752)
        let result = try await LocalFactoryBuildProcess().run(.init(executable: executable, arguments: [], directory: root, environment: ["PATH": "/usr/bin:/bin"], timeoutSeconds: 5), output: { _ in })
        #expect(result.status == 0 && result.output == Data("large fixture\n".utf8))
    }
    @Test(arguments: ["flat", "contents", "missing", "tampered"])
    func recipeBundleLayoutsRetainExactPins(_ layout: String) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("factory-bundle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Fixture.bundle")
        let contents = layout == "contents" ? bundleURL.appendingPathComponent("Contents") : bundleURL
        let files = contents.appendingPathComponent("Resources/Resources/FactoryBuild")
        // Flat SwiftPM bundles copy the logical Resources folder at the root.
        let destination = layout == "contents" ? files : bundleURL.appendingPathComponent("Resources/FactoryBuild")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleIdentifier": "dev.omarchy.factory-fixture", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let original = try FactoryRecipe().archive.deletingLastPathComponent()
        if layout != "missing" { try FileManager.default.copyItem(at: original.appendingPathComponent("recipe.json"), to: destination.appendingPathComponent("recipe.json")) }
        try FileManager.default.copyItem(at: original.appendingPathComponent("template.tar.gz"), to: destination.appendingPathComponent("template.tar.gz"))
        if layout == "tampered" { try Data("damaged fixture".utf8).write(to: destination.appendingPathComponent("template.tar.gz")) }
        let bundle = try #require(Bundle(url: bundleURL))
        if layout == "missing" || layout == "tampered" {
            #expect(throws: FactoryBuildFailure.inputsChanged) { _ = try FactoryRecipe(bundle: bundle) }
        } else {
            let recipe = try FactoryRecipe(bundle: bundle)
            try recipe.verify()
            #expect(recipe.downloads.count == 1)
        }
    }
    @Test func bundledRecipeAndPlanAreOfflineAndPinned() throws {
        let recipe = try FactoryRecipe(), plan = try FactoryBuildPlan()
        try recipe.verify()
        #expect(plan.sizeGiB == 20 && plan.minimumArtifactBytes == 24 * 1_073_741_824)
        #expect(plan.privilegedContainer && !plan.guestBootTested)
        // Omarchy comes from the selected channel at build time; only Node is pinned.
        #expect(recipe.downloads.map(\.name) == [recipe.downloads[0].name] && recipe.downloads[0].name.hasPrefix("node-"))
        #expect(plan.channel == .stable && plan.resolvedChannel == .stable)
        #expect(try FactoryBuildPlan(channel: .edge).resolvedChannel == .edge)
        // Records written before channels existed carry no channel and built edge.
        let legacy = try JSONDecoder().decode(FactoryBuildPlan.self, from: Data(#"{"name":"Lean Omarchy","sizeGiB":20,"recipeSHA256":"x"}"#.utf8))
        #expect(legacy.channel == nil && legacy.resolvedChannel == .edge)
        #expect(!String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self).contains("channel"))
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
    @Test(arguments: ["success", "failed", "foreign", "lost-create", "renamed", "config-tamper"])
    func pipelineHasExplicitScopeAndOnlyCleansOwnedResources(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("factory-test-" + UUID().uuidString)
        try factoryDirectory(root, create: true); defer { try? FileManager.default.removeItem(at: root) }
        let userConfig = root.appendingPathComponent(".docker/config.json")
        try FileManager.default.createDirectory(at: userConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalConfig = Data("{\"credsStore\":\"synthetic-forbidden-helper\",\"auths\":{}}".utf8)
        try originalConfig.write(to: userConfig)
        let input = root.appendingPathComponent("fixture-input"); try factoryDirectory(input, create: true)
        let file = input.appendingPathComponent("upstream/test"); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("template".utf8).write(to: file); chmod(file.path, 0o644)
        try FileManager.default.createDirectory(at: input.appendingPathComponent("profile"), withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("template.tgz")
        _ = try await LocalFactoryBuildProcess().run(.init(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-czf", archive.path, "-C", input.path, "upstream", "profile"], directory: root, environment: ["PATH": "/usr/bin:/bin"]), output: { _ in })
        let recipeData = try JSONSerialization.data(withJSONObject: ["format": 1, "templateSHA256": try factoryFileHash(archive), "files": ["upstream/test": ["sha256": digest(Data("template".utf8)), "mode": 420]], "downloads": [["name": "input-1", "url": "https://nodejs.org/fixture", "sha256": digest(Data("fixture".utf8))]], "provenance": ["try_commit": String(repeating: "a", count: 40)]])
        let recipe = try FactoryRecipe(archive: archive, data: recipeData, expected: digest(recipeData)), id = UUID()
        try factoryDirectory(root.appendingPathComponent(id.uuidString), create: true)
        let fake = FactoryFakeProcess(root: root, jobID: id); await fake.configure(failImage: kind == "failed" || kind == "foreign", foreign: kind == "foreign", lostCreate: kind == "lost-create", renamed: kind == "renamed", tamperConfiguration: kind == "config-tamper")
        let docker = try FactoryDockerClient(executable: URL(fileURLWithPath: "/bin/echo"), home: root, runner: fake), admission = try await docker.inspect()
        let engine = FactoryBuildEngine(docker: docker, recipe: recipe, downloader: FactoryFakeDownload()), output = FactoryBuildOutput()
        do {
            let result = try await engine.build(.init(fixtureRecipe: digest(recipeData), channel: kind == "renamed" ? .edge : .stable), jobID: id, root: root, admission: admission, output: output, stage: { _ in })
            #expect(kind == "success" || kind == "renamed")
            #expect(FileManager.default.fileExists(atPath: result.appendingPathComponent("image-build.json").path))
        } catch { #expect(kind != "success" && kind != "renamed"); if kind == "foreign" || kind == "lost-create" { #expect(error as? FactoryBuildFailure == .cleanupRequired) }; if kind == "config-tamper" { #expect(error as? FactoryBuildFailure == .inputsChanged) } }
        let commands = await fake.commands
        #expect(try Data(contentsOf: userConfig) == originalConfig)
        let imageBuilds = commands.filter { $0.contains("build") && !$0.contains("create") }
        #expect(imageBuilds.count == 1 && imageBuilds.allSatisfy { $0.contains("--config") })
        if kind == "config-tamper" { #expect(!commands.contains { $0.contains("create") }) }
        else {
            #expect(commands.contains { $0.contains("--privileged") && $0.contains("linux/arm64") && $0.contains("--pull=never") })
            let channel = kind == "renamed" ? "edge" : "stable"
            #expect(commands.contains { $0.suffix(3) == ["build", "20", channel] && $0.contains("/input-profile/build-container.sh") })
        }
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
    @Test(arguments: [17, 3007, 8191])
    func fragmentedOutputSnapshotRetainsItsTailWithinFourBoundedPages(_ fragmentSize: Int) {
        let output = FactoryBuildOutput()
        var expected = Data()
        for index in 0..<(200_000 / fragmentSize) {
            let fragment = Data(repeating: UInt8(index % 251), count: fragmentSize)
            expected.append(fragment); output.append(fragment)
        }
        var cursor: UInt64 = 0, actual = Data()
        for _ in 0..<4 {
            let page = output.page(after: cursor)
            #expect(!page.reset && page.bytes.count <= 65_536)
            actual.append(page.bytes); cursor = page.sequence
        }
        #expect(actual == expected)
        #expect(output.page(after: cursor).bytes.isEmpty)
    }
    @Test func byteCursorResetsGapsAndFutureCursorsWithoutLosingTheRetainedTail() {
        let output = FactoryBuildOutput(), expected = Data((0..<400_000).map { UInt8($0 % 251) })
        output.append(expected)
        let first = output.page(after: 0)
        #expect(first.reset && first.bytes.count == 65_536)
        let future = output.page(after: UInt64.max)
        #expect(future.reset && future.bytes == first.bytes && future.sequence == first.sequence)
        var cursor: UInt64 = 0, actual = Data()
        for _ in 0..<4 {
            let page = output.page(after: cursor)
            actual.append(page.bytes); cursor = page.sequence
        }
        #expect(actual.count > 254 * 1024 && actual.count <= 256 * 1024)
        #expect(actual == expected.suffix(actual.count) && cursor == UInt64(expected.count))
        let end = output.page(after: cursor)
        #expect(!end.reset && end.bytes.isEmpty && end.sequence == cursor)
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
