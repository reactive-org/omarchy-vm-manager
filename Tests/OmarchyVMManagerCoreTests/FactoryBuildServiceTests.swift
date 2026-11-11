import Darwin
@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private actor FactoryFixtureEnvironment: FactoryBuildEnvironment {
    var builds = 0, imports = 0, cleanups = 0
    var paused = false, uncertain = false, lowSpace = false
    var inspections = 0, pauseInspection = false, pauseCleanup = false
    private var inspectionWaiter: CheckedContinuation<Void, Never>?
    private var cleanupWaiter: CheckedContinuation<Void, Never>?
    var identity = String(repeating: "a", count: 64)
    func configure(paused: Bool = false, uncertain: Bool = false, lowSpace: Bool = false) { self.paused = paused; self.uncertain = uncertain; self.lowSpace = lowSpace }
    func changeEngine() { identity = String(repeating: "b", count: 64) }
    func holdInspection() { pauseInspection = true }
    func holdCleanup() { pauseCleanup = true }
    func releaseInspection() { pauseInspection = false; inspectionWaiter?.resume(); inspectionWaiter = nil }
    func releaseCleanup() { pauseCleanup = false; cleanupWaiter?.resume(); cleanupWaiter = nil }
    func inspect(root: URL) async -> FactoryBuildInspection {
        inspections += 1
        if pauseInspection { await withCheckedContinuation { inspectionWaiter = $0 } }
        return .init(admission: .init(context: "fixture", endpoint: "unix:///private/tmp/fixture.sock", engineSHA256: identity, toolSHA256: String(repeating: "c", count: 64)), availableBytes: lowSpace ? 0 : 100 * 1_073_741_824)
    }
    func build(plan: FactoryBuildPlan, id: UUID, root: URL, admission: FactoryDockerAdmission, output: FactoryBuildOutput, progress: @escaping @Sendable (FactoryBuildStage) async throws -> Void) async throws -> URL {
        builds += 1; output.append(Data("synthetic factory build output\n".utf8)); try await progress(.image)
        // URLSession and other adapters may wrap cancellation in their own error.
        if paused { do { try await Task.sleep(for: .seconds(60)) } catch { throw URLError(.cancelled) } }
        if uncertain { throw FactoryBuildFailure.cleanupRequired }
        return root.appendingPathComponent(id.uuidString).appendingPathComponent("output")
    }
    func prepareAndImport(output: URL, plan: FactoryBuildPlan, id: UUID, root: URL) -> FactoryIdentity {
        imports += 1
        return .init(kind: .custom, name: plan.name, manifestSHA256: String(repeating: "d", count: 64), diskSHA256: String(repeating: "e", count: 64))
    }
    func cleanup(id: UUID, admission: FactoryDockerAdmission) async {
        cleanups += 1
        if pauseCleanup { await withCheckedContinuation { cleanupWaiter = $0 } }
    }
}
private final class FactoryServiceFixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("factory-service-" + UUID().uuidString)
    let environment = FactoryFixtureEnvironment()
    let service: FactoryBuildService
    init() throws { try PrivateFiles.directory(root, create: true); service = FactoryBuildService(fixtureRoot: root, environment: environment) }
    deinit { try? FileManager.default.removeItem(at: root) }
}
private actor RecordingBuildTrash: FactoryTrashService {
    var moved: [URL] = []
    var fail = false
    func failNext() { fail = true }
    func moveToTrash(_ directory: URL) async throws {
        if fail { fail = false; throw CocoaError(.fileWriteNoPermission) }
        moved.append(directory)
        try FileManager.default.removeItem(at: directory)
    }
}
private actor RecordingFactoryQuit { var done = false; func complete() { done = true } }
@Suite("Factory jobs — fake environment and disposable local metadata", .serialized) struct FactoryBuildServiceTests {
    @Test func commandSocketUsesTheSameControllerWithoutResolvingOrStartingGuests() async throws {
        let f = try FactoryServiceFixture(), files = try RegistryFixture(); defer { files.cleanup() }
        let runtime = FakeRuntime()
        let manager = VMManager(runtime: runtime, profiles: [], applicationSupport: files.support)
        let service = GuestCommandService(manager: manager, applicationSupport: files.support, factoryBuilds: f.service)
        let endpoint = ManagerCommandEndpoint(directory: files.support.appendingPathComponent("ipc"))
        let server = try ManagerCommandServer(endpoint: endpoint) { await service.execute($0) }; defer { server.stop() }
        let client = ManagerCommandClient(endpoint: endpoint)
        func send(_ operation: FactoryBuildRequest) async throws -> GuestCommandResponse {
            var request = GuestCommandRequest(command: .factoryBuild); request.factoryBuild = operation
            let message = request
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(with: Result { try client.send(message) }) }
            }
        }
        let planned = try await send(.init(operation: .plan, name: "CLI fixture", sizeGiB: 20))
        let preview = try #require(planned.factoryBuild?.review)
        #expect(planned.ok && preview.plan.name == "CLI fixture")
        #expect(await f.environment.builds == 0)
        let started = try await send(.init(operation: .start, id: preview.id))
        #expect(started.ok && started.factoryBuild?.jobs?.first?.id == preview.id)
        #expect(await eventually { (try? await f.service.jobs().first?.stage) == .succeeded })
        let logs = try await send(.init(operation: .logs, id: preview.id))
        #expect(logs.ok && logs.factoryBuild?.bytes == Data("synthetic factory build output\n".utf8))
        await f.environment.configure(lowSpace: true)
        let invalid = try await send(.init(operation: .plan, name: "CLI fixture", sizeGiB: 20))
        #expect(!invalid.ok && invalid.error?.code == "factory-build-insufficientSpace")
        #expect(invalid.error?.message.contains("More free space") == true)
        #expect(await f.environment.builds == 1)
        #expect(runtime.startRequests.isEmpty && !FileManager.default.fileExists(atPath: files.storage.vms.path))
    }
    @Test func reviewIsInertAndStartIsBoundToLatestSelectionAndOneJob() async throws {
        let f = try FactoryServiceFixture()
        let old = try await f.service.review(), current = try await f.service.review(name: "Reviewed foundation", sizeGiB: 32)
        #expect(try await f.service.jobs().isEmpty)
        #expect(await f.environment.builds == 0)
        await #expect(throws: Error.self) { _ = try await f.service.start(reviewID: old.id) }
        let job = try await f.service.start(reviewID: current.id)
        _ = try await f.service.start(reviewID: current.id)
        #expect(job.plan.name == current.plan.name && job.plan.sizeGiB == 32)
        #expect(await eventually { (try? await f.service.jobs().first?.stage) == .succeeded })
        #expect(await f.environment.builds == 1); #expect(await f.environment.imports == 1)
        #expect(try await f.service.output(job.id, after: 0).bytes == Data("synthetic factory build output\n".utf8))
        let reloaded = FactoryBuildService(fixtureRoot: f.root, environment: f.environment)
        #expect(try await reloaded.jobs().first?.stage == .succeeded)
        #expect(try await reloaded.output(job.id, after: 0).bytes.isEmpty)
    }
    @Test(arguments: ["space", "engine"])
    func changedAdmissionCannotBeginABuild(kind: String) async throws {
        let f = try FactoryServiceFixture(), review = try await f.service.review()
        if kind == "space" { await f.environment.configure(lowSpace: true) } else { await f.environment.changeEngine() }
        _ = try await f.service.start(reviewID: review.id)
        #expect(await eventually { (try? await f.service.jobs().first?.stage) == .failed })
        #expect(await f.environment.builds == 0); #expect(await f.environment.imports == 0)
    }
    @Test func cancellationNeverImportsAndAnotherServiceCannotRecoverALiveBuild() async throws {
        let f = try FactoryServiceFixture(); await f.environment.configure(paused: true)
        let review = try await f.service.review(), job = try await f.service.start(reviewID: review.id)
        #expect(await eventually { await f.environment.builds == 1 })
        let second = FactoryBuildService(fixtureRoot: f.root, environment: f.environment)
        #expect(try await second.jobs().first?.cleanupRequired == true)
        await #expect(throws: FactoryBuildFailure.busy) { try await second.recover(job.id) }
        #expect(await f.environment.cleanups == 0)
        try await f.service.cancel(job.id); await f.service.cancelAndWait()
        #expect(try await f.service.jobs().first?.stage == .cancelled)
        #expect(await f.environment.imports == 0)
    }
    @Test func uncertainCleanupBlocksBuildsAndRecoveryNeverReplaysBuildOrImport() async throws {
        let f = try FactoryServiceFixture(); await f.environment.configure(uncertain: true)
        let review = try await f.service.review(), job = try await f.service.start(reviewID: review.id)
        #expect(await eventually { (try? await f.service.jobs().first?.cleanupRequired) == true })
        await #expect(throws: FactoryBuildFailure.busy) { _ = try await f.service.review() }
        try await f.service.recover(job.id)
        #expect(await f.environment.builds == 1); #expect(await f.environment.imports == 0); #expect(await f.environment.cleanups == 1)
        #expect(try await f.service.jobs().first?.stage == .failed)
    }
    @Test func staleControllerCannotBypassAnotherControllersCleanupHold() async throws {
        let f = try FactoryServiceFixture()
        let stale = FactoryBuildService(fixtureRoot: f.root, environment: f.environment)
        let staleReview = try await stale.review()
        await f.environment.configure(uncertain: true)
        let review = try await f.service.review()
        _ = try await f.service.start(reviewID: review.id)
        #expect(await eventually { (try? await f.service.jobs().first?.cleanupRequired) == true })
        await #expect(throws: FactoryBuildFailure.busy) { _ = try await stale.start(reviewID: staleReview.id) }
        await stale.cancelAndWait()
        #expect(await f.environment.builds == 1)
        #expect(try await FactoryBuildService(fixtureRoot: f.root, environment: f.environment).jobs().count == 1)
    }
    @Test func staleRecoveryCannotOverwriteACompletedOwnersJournal() async throws {
        let f = try FactoryServiceFixture(); await f.environment.configure(paused: true)
        let review = try await f.service.review(), job = try await f.service.start(reviewID: review.id)
        #expect(await eventually { await f.environment.builds == 1 })
        let stale = FactoryBuildService(fixtureRoot: f.root, environment: f.environment)
        #expect(try await stale.jobs().first?.cleanupRequired == true)
        try await f.service.cancel(job.id); await f.service.cancelAndWait()
        await #expect(throws: FactoryBuildFailure.invalidRequest) { try await stale.recover(job.id) }
        #expect(await f.environment.cleanups == 0)
        #expect(try await FactoryBuildService(fixtureRoot: f.root, environment: f.environment).jobs().first?.stage == .cancelled)
    }
    @Test func quitFencesPreviouslyReviewedAndNewBuildAdmission() async throws {
        let f = try FactoryServiceFixture(), review = try await f.service.review()
        await f.service.cancelAndWait()
        await #expect(throws: FactoryBuildFailure.busy) { _ = try await f.service.start(reviewID: review.id) }
        await #expect(throws: FactoryBuildFailure.busy) { _ = try await f.service.review() }
        await f.service.cancelAndWait()
        #expect(await f.environment.builds == 0)
    }
    @Test func cancelledQuitRequiresAFreshPreviewBeforeStartingAgain() async throws {
        let f = try FactoryServiceFixture(), old = try await f.service.review()
        await f.service.cancelAndWait(); await f.service.resumeAfterCancelledQuit()
        await #expect(throws: Error.self) { _ = try await f.service.start(reviewID: old.id) }
        let fresh = try await f.service.review()
        _ = try await f.service.start(reviewID: fresh.id)
        #expect(await eventually { (try? await f.service.jobs().first?.stage) == .succeeded })
        #expect(await f.environment.builds == 1)
    }
    @Test func quitInvalidatesAnInspectionAlreadyInFlight() async throws {
        let f = try FactoryServiceFixture(); await f.environment.holdInspection()
        let review = Task { [service = f.service] in try await service.review() }
        #expect(await eventually { await f.environment.inspections == 1 })
        let finished = RecordingFactoryQuit()
        let quit = Task { [service = f.service] in await service.cancelAndWait(); await finished.complete() }
        #expect(await eventually { await f.service.admissionSuspended })
        #expect(await finished.done == false)
        await f.environment.releaseInspection(); await quit.value
        await #expect(throws: Error.self) { _ = try await review.value }
        #expect(await finished.done)
        #expect(await f.environment.builds == 0)
    }
    @Test func quitWaitsForOwnedRecoveryAndDoesNotReplayIt() async throws {
        let f = try FactoryServiceFixture(); await f.environment.configure(uncertain: true)
        let review = try await f.service.review(), job = try await f.service.start(reviewID: review.id)
        #expect(await eventually { (try? await f.service.jobs().first?.cleanupRequired) == true })
        await f.environment.holdCleanup()
        let recovery = Task { [service = f.service] in try await service.recover(job.id) }
        #expect(await eventually { await f.environment.cleanups == 1 })
        let finished = RecordingFactoryQuit()
        let quit = Task { [service = f.service] in await service.cancelAndWait(); await finished.complete() }
        #expect(await eventually { await f.service.admissionSuspended })
        #expect(await finished.done == false)
        await f.environment.releaseCleanup(); try await recovery.value; await quit.value
        #expect(await finished.done)
        await #expect(throws: FactoryBuildFailure.busy) { _ = try await f.service.review() }
        await f.service.resumeAfterCancelledQuit()
        _ = try await f.service.review()
        #expect(await f.environment.cleanups == 1)
        #expect(await f.environment.builds == 1)
    }
    @Test func deletingAJournalCannotEraseAnExistingCleanupHold() async throws {
        let f = try FactoryServiceFixture(); await f.environment.configure(uncertain: true)
        let preview = try await f.service.review(), job = try await f.service.start(reviewID: preview.id)
        #expect(await eventually { (try? await f.service.jobs().first?.cleanupRequired) == true })
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("Records/" + job.id.uuidString + ".json"))
        await #expect(throws: FactoryBuildFailure.invalidRequest) { try await f.service.recover(job.id) }
        #expect(await f.environment.cleanups == 0)
        #expect(try await f.service.jobs().first?.cleanupRequired == true)
        #expect(await f.service.cancelAndWait() == false)
    }
    @Test func quitRefusesUnconfirmedCleanupAndRetriesOnlyAfterExplicitRecovery() async throws {
        let f = try FactoryServiceFixture(); await f.environment.configure(uncertain: true)
        let preview = try await f.service.review(), job = try await f.service.start(reviewID: preview.id)
        #expect(await eventually { (try? await f.service.jobs().first?.cleanupRequired) == true })
        #expect(await f.service.cancelAndWait() == false)
        await f.service.resumeAfterCancelledQuit()
        try await f.service.recover(job.id)
        #expect(await f.service.cancelAndWait())
        #expect(await f.environment.builds == 1)
        #expect(await f.environment.imports == 0)
        #expect(await f.environment.cleanups == 1)
    }
    @Test func wireRejectsUnknownFieldsAndCannotSelectHostPathsOrDockerCommands() throws {
        let request = GuestCommandRequest(command: .factoryBuild)
        var data = try #require(JSONSerialization.jsonObject(with: helperJSON(request)) as? [String: Any])
        for extra in ["dockerHost", "root", "command", "privileged"] {
            data["factoryBuild"] = ["operation": "plan", extra: "untrusted"]
            #expect(throws: Error.self) { _ = try GuestCommandRequest.decodeStrict(JSONSerialization.data(withJSONObject: data)) }
        }
        for args in [["factory-build", "start"], ["factory-build", "plan", "--size-gib", "19"], ["factory-build", "start", UUID().uuidString, "--yes"], ["factory-build", "plan", "--docker-host", "ssh://example.invalid"]] {
            #expect(throws: Error.self) { _ = try FactoryBuildCLI.parse(args) }
        }
    }
    @Test func channelIsAPlanOnlyChoiceThatDefaultsToStable() throws {
        let (plain, _) = try #require(try FactoryBuildCLI.parse(["factory-build", "plan"]))
        #expect(plain.channel == nil)
        let (edge, _) = try #require(try FactoryBuildCLI.parse(["factory-build", "plan", "--channel", "edge", "--name", "Edge foundation"]))
        #expect(edge.channel == .edge && edge.name == "Edge foundation")
        for args in [["factory-build", "plan", "--channel", "rc"], ["factory-build", "plan", "--channel", "stable", "--channel", "edge"],
                     ["factory-build", "plan", "--channel"], ["factory-build", "status", "--channel", "edge"]] {
            #expect(throws: Error.self) { _ = try FactoryBuildCLI.parse(args) }
        }
        #expect(throws: Error.self) { try FactoryBuildRequest(operation: .status, channel: .edge).validate() }
        let request = GuestCommandRequest(command: .factoryBuild)
        var data = try #require(JSONSerialization.jsonObject(with: helperJSON(request)) as? [String: Any])
        data["factoryBuild"] = ["operation": "plan", "channel": "edge"]
        let decoded = try GuestCommandRequest.decodeStrict(JSONSerialization.data(withJSONObject: data))
        #expect(decoded.factoryBuild?.channel == .edge)
        data["factoryBuild"] = ["operation": "plan", "channel": "nightly"]
        #expect(throws: Error.self) { _ = try GuestCommandRequest.decodeStrict(JSONSerialization.data(withJSONObject: data)) }
    }
    @Test func reviewRecordsTheChosenChannelAndOlderJournalRecordsStillLoad() async throws {
        let f = try FactoryServiceFixture()
        #expect(try await f.service.review().plan.channel == .stable)
        let review = try await f.service.review(name: "Edge foundation", sizeGiB: 20, channel: .edge)
        #expect(review.plan.channel == .edge)
        let job = try await f.service.start(reviewID: review.id)
        #expect(await f.service.cancelAndWait())
        let records = f.root.appendingPathComponent("Records")
        let path = records.appendingPathComponent(job.id.uuidString + ".json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var jobObject = try #require(object["job"] as? [String: Any]), plan = try #require(jobObject["plan"] as? [String: Any])
        #expect(plan["channel"] as? String == "edge")
        // A record written before channels existed has no channel and built edge.
        plan.removeValue(forKey: "channel"); jobObject["plan"] = plan; object["job"] = jobObject
        let legacy = FactoryBuildService(fixtureRoot: f.root, environment: f.environment)
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), name: path.lastPathComponent, in: records)
        let loaded = try #require(try await legacy.jobs().first { $0.id == job.id })
        #expect(loaded.plan.channel == nil && loaded.plan.resolvedChannel == .edge)
    }
    @Test func onlyTheBuildersFixedSentenceMarksAnUnreviewedOmarchyRelease() {
        let marked = FactoryBuildOutput()
        marked.append(Data(repeating: 46, count: 300_000))
        marked.append(Data("Image compatibility failed: This Omarchy release changes setup programs that Omarchy VM Manager hasn't reviewed yet.\n".utf8))
        #expect(FactoryBuildService.reportsUnreviewedOmarchy(marked))
        let other = FactoryBuildOutput(); other.append(Data("Dependency resolution failed\n".utf8))
        #expect(!FactoryBuildService.reportsUnreviewedOmarchy(other))
        let job = FactoryBuildJob(id: UUID(), plan: try! FactoryBuildPlan(), stage: .failed, failure: FactoryBuildJob.unreviewedOmarchyFailure)
        #expect(job.failureExplanation.contains("can’t check automatically"))
    }
    @Test func finishedBuildsMoveToTrashAndLeaveHistoryWhileOthersAreKept() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("factory-remove-" + UUID().uuidString)
        try PrivateFiles.directory(root, create: true); defer { try? FileManager.default.removeItem(at: root) }
        let environment = FactoryFixtureEnvironment(), trash = RecordingBuildTrash()
        let service = FactoryBuildService(fixtureRoot: root, environment: environment, trash: trash)
        let review = try await service.review()
        let job = try await service.start(reviewID: review.id)
        #expect(await eventually { (try? await service.jobs().first?.stage) == .succeeded })
        let workspace = root.appendingPathComponent("Jobs").appendingPathComponent(job.id.uuidString)
        try Data("retained output".utf8).write(to: workspace.appendingPathComponent("factory.img.zst"))
        // A failed Trash keeps the files and the history entry.
        await trash.failNext()
        await #expect(throws: VMFailure.self) { try await service.remove(job.id) }
        let kept = try await service.jobs().count
        #expect(FileManager.default.fileExists(atPath: workspace.path) && kept == 1)
        try await service.remove(job.id)
        #expect(await trash.moved == [workspace])
        let remaining = try await service.jobs()
        #expect(remaining.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Records/" + job.id.uuidString + ".json").path))
        await #expect(throws: FactoryBuildFailure.self) { try await service.remove(job.id) }
        // An interrupted job needs verified cleanup first and cannot be removed.
        await environment.configure(uncertain: true)
        let heldReview = try await service.review()
        let held = try await service.start(reviewID: heldReview.id)
        #expect(await eventually { (try? await service.jobs().first?.stage) == .cleanupRequired })
        await #expect(throws: FactoryBuildFailure.self) { try await service.remove(held.id) }
        #expect(await trash.moved.count == 1)
    }
    @Test func compiledStableGateCannotBeChangedByAnEnvironmentOrWireField() async throws {
        let f = try FactoryServiceFixture()
        let service = FactoryBuildService(applicationSupport: f.root, environment: f.environment)
        #expect(service.enabled == (AppChannel.current == .development))
        if !service.enabled { await #expect(throws: Error.self) { _ = try await service.review() } }
        #expect(await f.environment.builds == 0)
    }
}
