import Darwin
@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private final class ProvisioningPackageFixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    var contents: URL { root.appendingPathComponent("Fixture.app/Contents") }
    var layout: ProvisioningPackageLayout { .init(contents: contents) }
    var resources: URL { contents.appendingPathComponent("Resources/" + ProvisioningPackagePin.resourceBundle + "/Resources") }
    init(nested: Bool = false) throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let bundle = contents.appendingPathComponent("Resources/" + ProvisioningPackagePin.resourceBundle)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        if nested { try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true) }
        try FileManager.default.copyItem(at: repo.appendingPathComponent("Vendor/dev-vm/Sources/DevVMProvisioningCore/Resources"), to: nested ? bundle.appendingPathComponent("Contents/Resources/Resources") : resources)
        try FileManager.default.copyItem(at: repo.appendingPathComponent("Config/DevVMProvisioning.lock.json"), to: contents.appendingPathComponent("Resources/DevVMProvisioning.lock.json"))
        var executables: [String: String] = [:]
        for name in BundledProvisioning.executableNames {
            let url = contents.appendingPathComponent("MacOS/" + name), data = Data("fake executable, never launched".utf8)
            try data.write(to: url); chmod(url.path, 0o700); executables[name] = KitVerifier.sha256(data)
        }
        let distribution: [String: Any] = ["format": 1, "lockSHA256": ProvisioningPackagePin.lockSHA256,
            "engineSHA256": ProvisioningPackagePin.engineSHA256, "executables": executables]
        try JSONSerialization.data(withJSONObject: distribution).write(to: contents.appendingPathComponent("Resources/ProvisioningDistribution.json"))
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite("Pinned provisioning package admission") struct ProvisioningPackageTests {
    @Test(arguments: [false, true]) func exactResourceLayouts(nested: Bool) throws {
        let fixture = try ProvisioningPackageFixture(nested: nested)
        let status = try BundledProvisioning.inspect(fixture.layout)
        #expect(status.sourceRevision == ProvisioningPackagePin.revision)
        #expect(status.sourceSnapshotSHA256 == ProvisioningPackagePin.sourceSnapshotSHA256)
        #expect(status.setupAPI == 1 && status.offlinePlanningIntegrated && status.executionEnabled == (AppChannel.current == .development))
        #expect(status.resourceCount == ProvisioningPackagePin.resources.count)
    }
    @Test(arguments: ["resource", "extra", "lock", "launcher", "distribution", "symlink", "ambiguous"])
    func refusesChangedDistribution(kind: String) throws {
        let fixture = try ProvisioningPackageFixture()
        switch kind {
        case "resource": try Data("{}".utf8).write(to: fixture.resources.appendingPathComponent("catalogue.json"))
        case "extra": try Data().write(to: fixture.resources.appendingPathComponent("extra"))
        case "lock": try Data("{}".utf8).write(to: fixture.contents.appendingPathComponent("Resources/DevVMProvisioning.lock.json"))
        case "launcher": try Data("changed".utf8).write(to: fixture.contents.appendingPathComponent("MacOS/dev-vm-process-host"))
        case "distribution": try Data("{\"format\":1,\"format\":1}".utf8).write(to: fixture.contents.appendingPathComponent("Resources/ProvisioningDistribution.json"))
        case "symlink":
            let file = fixture.resources.appendingPathComponent("catalogue.json")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: fixture.resources.appendingPathComponent("selection.schema.json"))
        default:
            let other = fixture.resources.deletingLastPathComponent().appendingPathComponent("Contents/Resources/Resources")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.resources.appendingPathComponent("engine-identity.json"), to: other.appendingPathComponent("engine-identity.json"))
        }
        #expect(throws: VMFailure.self) { _ = try BundledProvisioning.inspect(fixture.layout) }
    }
    @Test func missingPackageCannotUseDeveloperFallback() throws {
        let fixture = try ProvisioningPackageFixture()
        try FileManager.default.removeItem(at: fixture.contents.appendingPathComponent("Resources/" + ProvisioningPackagePin.resourceBundle))
        #expect(throws: VMFailure.self) { _ = try BundledProvisioning.inspect(fixture.layout) }
    }
    @Test(arguments: BundledProvisioning.presets)
    func bundledPresetsPlanOfflineWithoutATarget(preset: String) throws {
        let f = try ProvisioningPackageFixture()
        let data = try BundledProvisioning.plan(preset: preset, layout: f.layout)
        let document = try PlainDataParser.parse(data, format: .json)
        #expect(document.object?["features"]?.object?["profiles"] == .array([.string(preset)]))
        #expect(document.object?["plan_digest"]?.string?.count == 64)
        #expect(document.object?["tasks"] == .array([]))
    }
    @Test func productCompositionIsSharedAndUsesCompiledChannelPolicy() async throws {
        let f = try ProvisioningPackageFixture()
        let support = f.root.appendingPathComponent("manager-state")
        try PrivateFiles.directory(support, create: true)
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [], applicationSupport: support, hostMemoryMiB: 32768, logicalCPUs: 8)
        let layout = f.layout
        async let first = manager.installProvisioningService(layout: layout)
        async let second = manager.installProvisioningService(layout: layout)
        let (a, b) = try await (first, second)
        #expect(a === b && a.executionEnabled == (AppChannel.current == .development))
        #expect(await a.statuses().isEmpty)
        #expect(runtime.startRequests.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: AppChannel.current.directory(in: support).appendingPathComponent("Provisioning/control").path).isEmpty)
        try await a.closeForReopen()
    }
    @Test func changedPackageStillLoadsOldRiskBeforeAdmissionFails() async throws {
        let f = try ProvisioningPackageFixture(), vmID = UUID()
        let support = f.root.appendingPathComponent("manager-state")
        let directory = AppChannel.current.directory(in: support).appendingPathComponent("Provisioning")
        try PrivateFiles.directory(support, create: true)
        try PrivateFiles.directory(directory.deletingLastPathComponent(), create: true)
        try PrivateFiles.directory(directory, create: true)
        let workflows = try ProvisioningWorkflowJournal(directory: directory.appendingPathComponent("workflows")); _ = try workflows.load()
        var row = ProvisioningWorkflowRecord(id: UUID(), vmID: vmID, originalSessionID: UUID(), planDigest: String(repeating: "a", count: 64),
            inputDigest: String(repeating: "b", count: 64), engineDigest: String(repeating: "c", count: 64))
        row.stage = .cleanupRequired; row.cleanupRequired = true
        try workflows.save([row]); workflows.close()
        let before = try Data(contentsOf: directory.appendingPathComponent("workflows/workflows.json"))
        try Data("changed".utf8).write(to: f.resources.appendingPathComponent("catalogue.json"))
        let runtime = FakeRuntime(), profile = VMProfile(id: vmID, name: "Fixture", clipboardEnabled: false)
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: support, hostMemoryMiB: 32768, logicalCPUs: 8)
        await #expect(throws: VMFailure.self) { _ = try await manager.installProvisioningService(layout: f.layout) }
        await #expect(throws: VMFailure.self) { try await manager.start(vmID) }
        #expect(runtime.startRequests.isEmpty)
        #expect(try Data(contentsOf: directory.appendingPathComponent("workflows/workflows.json")) == before)
    }
    @Test func bundledRuntimeStreamsOnlyLocalFixtureAndCannotGrantInput() async throws {
        let f = try ProvisioningPackageFixture(), source = f.root.appendingPathComponent("source"), inputs = f.root.appendingPathComponent("inputs")
        try PrivateFiles.directory(source, create: true); try PrivateFiles.directory(inputs, create: true)
        try Data("schema_version: 1\nid: local-fixture\nsetup: {features: {enable: [cli]}}\n".utf8).write(to: source.appendingPathComponent("vm.yml"))
        let plan = try SetupPlanner.plan(repository: source)
        let target = try GuestBinding(vmID: UUID(), sessionID: UUID(), owner: "fixture", ownerUID: 1000, hostKeyDigest: String(repeating: "a", count: 64))
        let request = try ProvisioningRequest(jobID: UUID(), plan: plan, repository: source, target: target, dependencyDigest: String(repeating: "b", count: 64), mode: .check)
        let delivery = try ProvisioningFrozenDelivery(request: request, approval: .init(reviewIdentity: request.reviewIdentity), archive: plan.snapshot.privateArchive())
        let scope = ProvisioningRecoveryExpectation(challenge: UUID(), jobID: request.jobID, vmID: target.vmID, sessionID: target.sessionID, payloadID: UUID(),
            workerToken: UUID(), engineDigest: try ProvisioningCoordinator.engineIdentity(plan), dependencyDigest: request.dependencyDigest,
            bindingDigest: try ProvisioningCoordinator.bindingIdentity(target), reviewDigest: request.reviewIdentity, checkpointDigest: String(repeating: "c", count: 64))
        let registration = ProvisioningHelperWorkerRegistration(scope: scope, planDigest: plan.identity, inputDigest: plan.snapshot.identity, mode: .check, delivery: delivery.receipt)
        let input = try ProvisioningValidatedFrozenContext.load(delivery.bytes, registration: registration, parent: inputs)
        let terminal = try ProvisioningTerminal()
        let runner = try ProvisioningOperationalBackends.worker(input: input, terminal: terminal, layout: f.layout)
        let script = source.appendingPathComponent("fixture.sh")
        try Data("#!/bin/sh\nprintf 'local fixture output\\n'\n".utf8).write(to: script); chmod(script.path, 0o700)
        let context = GuestJobContext(jobID: request.jobID, payloadID: UUID(), target: target, dependencyDigest: request.dependencyDigest, mode: .check)
        func invocation(_ input: ProvisioningProcessInput) -> ProvisioningProcessInvocation {
            .init(id: UUID(), commandID: UUID(), context: context, purpose: .identity, executable: script, arguments: [], environment: [:],
                workingDirectory: source, input: input, output: .terminalStream, timeoutSeconds: 2)
        }
        let result = await runner.run(invocation(.closed))
        if case .exited(status: 0, reason: .normal) = result.termination {} else { Issue.record("Local fixture failed") }
        #expect(String(decoding: terminal.snapshot().frames.flatMap { $0.bytes }, as: UTF8.self).contains("local fixture output"))
        #expect(!terminal.snapshot().acceptsInput)
        if case .notStarted = await runner.run(invocation(.terminalLease(UUID()))).termination {} else { Issue.record("Unowned input was accepted") }
        try Data("changed".utf8).write(to: f.resources.appendingPathComponent("catalogue.json"))
        #expect(throws: Error.self) { _ = try ProvisioningOperationalBackends.worker(input: input, terminal: terminal, layout: f.layout) }
    }

}
