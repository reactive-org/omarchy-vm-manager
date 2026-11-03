import Darwin
@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

/// No VM roots, process runners, host dependency probes or guest sessions.
final class CreationFixture: Sendable {
    let root: URL, source: URL, state: URL
    let registry: RegistryStore, manager: VMManager, runtime: FakeRuntime
    let provider: SessionFixtureProvider, dependencies: WorkflowFixtureDependencies, launcher: WorkflowFixtureLauncher
    let service: ProvisioningService, engine: String
    init(manifest: String = "schema_version: 1\nid: creation-fixture\nsetup: {features: {enable: [cli]}}\n", themeResolver: ThemeResolver? = nil) async throws {
        root = URL(fileURLWithPath: "/private/tmp/provisioning-selection-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); state = root.appendingPathComponent("state")
        try PrivateFiles.directory(root, create: true); try PrivateFiles.directory(source, create: true)
        try Data(manifest.utf8).write(to: source.appendingPathComponent("vm.yml"))
        registry = try RegistryStore(applicationSupport: root); _ = try registry.load()
        runtime = FakeRuntime(initialEvents: [.ready])
        manager = VMManager(runtime: runtime, profiles: [], applicationSupport: root, hostMemoryMiB: 32768, logicalCPUs: 8,
            registry: registry, portProbe: TransportFixturePorts())
        provider = try SessionFixtureProvider(); dependencies = WorkflowFixtureDependencies(try provider.admittedReport()); launcher = WorkflowFixtureLauncher(provider: provider)
        engine = try ProvisioningCoordinator.engineIdentity(SetupPlanner.plan(repository: source))
        var environment = ProvisioningServiceEnvironment(executionEnabled: false,
            engineDigest: engine, dependencies: dependencies, launcher: launcher, transportPolicy: .fixture(provider.root), admitPackage: {})
        if let themeResolver { environment.themeResolver = themeResolver }
        service = try await ProvisioningService.open(manager: manager, directory: state, environment: environment)
        try await manager.installProvisioningService(service)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func prepare(_ features: ProvisioningFeatureSelection? = nil, id: UUID = UUID()) async throws -> ProvisioningCreationReview {
        try await service.prepareCreation(id: id, source: .init(directory: source.path, features: features))
    }
    func create(_ review: ProvisioningCreationReview, name: String = "Manager chosen", memory: Int = 8192, acknowledged: Bool = true) async throws -> UUID {
        try await manager.create(name: name, memoryMiB: memory, cpus: 4, diskGiB: 128, clipboardEnabled: false,
            immersiveMode: false, sshEnabled: false, useOwnerDefaults: false, factory: "official",
            setupConsent: .init(reviewID: review.id, reviewIdentity: review.reviewIdentity, acknowledged: acknowledged))
    }
    func assertInert() async {
        #expect(runtime.startRequests.isEmpty)
        #expect(await dependencies.inspections == 0); #expect(await launcher.launches == 0)
        #expect(!FileManager.default.fileExists(atPath: ManagerStorage(applicationSupport: root).directory.appendingPathComponent("VMs").path))
    }
    func close() async { try? await service.closeForReopen(); await launcher.close() }
}

@Suite("Native feature selection and New VM handoff — local fixtures") struct ProvisioningSelectionTests {
    @Test func guestTouchIDAndSetupReviewSurviveTheSameCreateRequestAndProfile() async throws {
        let f = try await CreationFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let review = try await f.prepare()
        let request = try #require(GuestCLIInvocation.parse(["create", "Merged fixture", "--guest-touch-id", "on",
            "--ssh", "off", "--owner-defaults", "off", "--inherit-default-public-key", "off",
            "--setup-review-id", review.id.uuidString, "--setup-review", review.reviewIdentity, "--ack-setup-selection"]).request)
        let decoded = try GuestCommandRequest.decodeStrict(helperJSON(request))
        #expect(decoded.config?.guestTouchID == true && decoded.setupConsent == request.setupConsent)
        let result = await GuestCommandService(manager: f.manager, applicationSupport: f.root).execute(decoded)
        #expect(result.ok)
        let profile = try #require(await f.manager.snapshots().first?.profile)
        #expect(profile.guestTouchIDEnabled && profile.developerSetup != nil)
        #expect(try JSONDecoder().decode(VMProfile.self, from: JSONEncoder().encode(profile)) == profile)
        await f.assertInert(); await f.close()
    }

    @Test func nativeChoicesReplaceAliasesAndPreserveFrozenSourceAndModes() async throws {
        let text = "schema_version: 1\nid: feature-fixture\nsetup: {features: {enable: [builtin.cli], disable: [builtin.docker]}, options: {docker: {access: sudoless}}}\nvars: {private: SELECTION-PRIVATE-VALUE}\n"
        let f = try await CreationFixture(manifest: text)
        let original = f.source.appendingPathComponent("vm.yml"); #expect(chmod(original.path, 0o640) == 0)
        let plain = try await f.prepare()
        let edits = ProvisioningFeatureSelection(enable: [.docker], disable: [.cli])
        let chosen = try await f.prepare(edits)
        #expect(chosen.inputDigest != plain.inputDigest && chosen.planDigest != plain.planDigest && chosen.reviewIdentity != plain.reviewIdentity)
        #expect(chosen.restartRequired)
        let draft = try #require(await f.service.creations[chosen.id])
        #expect(draft.frozen.plan.snapshot.data(for: "vm.yml") == Data(text.utf8))
        #expect(draft.frozen.plan.snapshot.receipts.first { $0.path == "vm.yml" }?.mode == 0o640)
        let resolved = draft.frozen.plan.document.object?["features"]?.object?["features"]?.array?.compactMap(\.string) ?? []
        #expect(resolved.contains("docker") && !resolved.contains("cli"))
        #expect(try Data(contentsOf: original) == Data(text.utf8))
        #expect(!FileManager.default.fileExists(atPath: f.source.appendingPathComponent(ProvisioningService.selectionManifest).path))
        #expect(!String(reflecting: chosen).contains("SELECTION-PRIVATE-VALUE"))
        try Data("broken: edited-source".utf8).write(to: original)
        #expect(try await f.service.creation(chosen.id) == chosen)
        await f.assertInert(); await f.close()
    }
    @Test func useSourceKeepsExactSharedPlannerIdentityAndNativeEditsUseSharedResolution() async throws {
        let f = try await CreationFixture()
        let p = try await f.prepare(), original = try SetupPlanner.plan(repository: f.source)
        #expect(p.planDigest == original.identity && p.inputDigest == original.snapshot.identity)
        for feature in ProvisioningCommonFeature.allCases {
            let value = try await f.prepare(.init(enable: [feature]))
            let draft = try #require(await f.service.creations[value.id])
            let replanned = try SetupPlanner.plan(repository: draft.frozen.storage.directory, manifest: ProvisioningService.selectionManifest)
            #expect(value.planDigest == replanned.identity)
        }
        await f.assertInert(); await f.close()
    }
    @Test func overridesPreserveProfilesTasksOptionsAndVMDeclarations() async throws {
        let f = try await CreationFixture()
        let text = """
        schema_version: 1
        id: full-fixture
        vm: {name: Source name, cpus: 8, memory_gib: 16, disk_gib: 256}
        setup: {profiles: [web], options: {docker: {access: sudoless}}}
        tasks: [{name: custom, file: custom.yml}]
        dotfiles: [{source: editor.conf, target: .config/editor.conf}]
        vars: {fixture: original}
        """
        try Data(text.utf8).write(to: f.source.appendingPathComponent("vm.yml"))
        try Data("- ansible.builtin.debug: {msg: SYNTHETIC-CUSTOM-SOURCE}\n".utf8).write(to: f.source.appendingPathComponent("custom.yml"))
        try Data("synthetic preferences".utf8).write(to: f.source.appendingPathComponent("editor.conf"))
        let p = try await f.prepare(.init(enable: [.docker])), draft = try #require(await f.service.creations[p.id])
        #expect(p.tasks.count == 1 && p.tasks.first?.name == "custom" && p.restartRequired)
        #expect(draft.frozen.plan.document.object?["vm"]?.object?["cpus"] == .integer(8))
        let manifest = try SetupManifest.parse(try #require(draft.frozen.plan.snapshot.data(for: ProvisioningService.selectionManifest)), format: .json)
        #expect(manifest.variables["fixture"] == .string("original"))
        #expect(manifest.selection.object?["profiles"] == .array([.string("web")]))
        let id = try await f.create(p), target = try #require(await f.manager.snapshots().first)
        #expect(target.id == id && target.profile.name == "Manager chosen" && target.profile.cpus == 4)
        #expect(target.profile.memoryMiB == 8192 && target.profile.diskGiB == 128 && target.profile.factory == .official)
        #expect(target.sessionID == nil && target.state == .stopped)
        await f.assertInert(); await f.close()
    }
    @Test func duplicateHandoffCreatesOneProfileAndBindsTheOriginalFrozenInputs() async throws {
        let f = try await CreationFixture(), p = try await f.prepare(.init(enable: [.docker]))
        await #expect(throws: ProvisioningReviewFailure.unavailable) { _ = try await f.service.preview(p.id) }
        let id = try await f.create(p)
        try Data("changed original".utf8).write(to: f.source.appendingPathComponent("vm.yml"))
        let duplicate = try await f.create(p)
        #expect(id == duplicate)
        #expect(await f.manager.snapshots().count == 1)
        let bound = try await f.service.preview(p.id)
        #expect(bound.vmID == id && bound.sessionID == nil && bound.inputDigest == p.inputDigest && bound.proposal == p.proposal)
        await #expect(throws: ProvisioningReviewFailure.conflictingConsent) { _ = try await f.create(p, memory: 12288) }
        let file = ManagerStorage(applicationSupport: f.root).directory.appendingPathComponent("registry.json")
        let bytes = try Data(contentsOf: file), object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        #expect(object["schemaVersion"] as? Int == 6)
        #expect(!String(decoding: bytes, as: UTF8.self).contains(f.source.path))
        let profile = try #require(await f.manager.snapshots().first?.profile)
        #expect(try JSONDecoder().decode(VMProfile.self, from: helperJSON(profile)) == profile)
        await #expect(throws: ProvisioningServiceFailure.disabled) { _ = try await f.service.prepareApply(p.id) }
        await f.assertInert(); await f.close()
    }
    @Test func noAcknowledgementOrLostReviewCannotCreateMetadata() async throws {
        let f = try await CreationFixture(), p = try await f.prepare()
        await #expect(throws: ProvisioningReviewFailure.consentRequired) { _ = try await f.create(p, acknowledged: false) }
        try await f.service.closeForReopen()
        await #expect(throws: Error.self) { _ = try await f.create(p) }
        #expect(await f.manager.snapshots().isEmpty)
        await f.assertInert(); await f.close()
    }
    @Test func invalidResourcesDoNotConsumeReview() async throws {
        let f = try await CreationFixture(), p = try await f.prepare()
        await #expect(throws: VMFailure.self) { _ = try await f.create(p, memory: 1024) }
        #expect(await f.service.creations[p.id]?.reservation == nil)
        _ = try await f.create(p)
        await f.assertInert(); await f.close()
    }
    @Test func unknownRegistryOutcomeConsumesTheReservationWithoutAutomaticRetry() async throws {
        let f = try await CreationFixture(), p = try await f.prepare()
        let file = f.registry.directory.appendingPathComponent("registry.json"), changed = Data("external-registry-edit".utf8)
        try changed.write(to: file)
        await #expect(throws: Error.self) { _ = try await f.create(p) }
        #expect(await f.service.creations[p.id]?.reservation != nil)
        await #expect(throws: ProvisioningReviewFailure.conflictingConsent) { _ = try await f.create(p) }
        #expect(await f.manager.snapshots().isEmpty)
        #expect(try Data(contentsOf: file) == changed)
        await f.assertInert(); await f.close()
    }
    @Test func reopeningKeepsReceiptForLookupButCannotReconstructFrozenAuthority() async throws {
        let f = try await CreationFixture(), p = try await f.prepare(), id = try await f.create(p)
        let profile = try #require(await f.manager.snapshots().first?.profile)
        try await f.service.closeForReopen()
        let reopened = VMManager(runtime: f.runtime, profiles: [profile], applicationSupport: f.root, hostMemoryMiB: 32768, logicalCPUs: 8, registry: f.registry, portProbe: TransportFixturePorts())
        let same = try await reopened.create(name: "Manager chosen", memoryMiB: 8192, cpus: 4, diskGiB: 128, clipboardEnabled: false,
            immersiveMode: false, sshEnabled: false, useOwnerDefaults: false, factory: "official",
            setupConsent: .init(reviewID: p.id, reviewIdentity: p.reviewIdentity, acknowledged: true))
        #expect(same == id)
        #expect(await reopened.snapshots().count == 1)
        let next = try await ProvisioningService.open(manager: reopened, directory: f.state, environment: .init(executionEnabled: false,
            engineDigest: f.engine, dependencies: f.dependencies, launcher: f.launcher, transportPolicy: .fixture(f.provider.root), admitPackage: {}))
        await #expect(throws: ProvisioningReviewFailure.unavailable) { _ = try await next.creation(p.id) }
        await #expect(throws: ProvisioningReviewFailure.unavailable) { _ = try await next.preview(p.id) }
        try await next.closeForReopen(); await f.assertInert(); await f.close()
    }
    @Test(arguments: ["overlap", "duplicate", "private-edit", "reserved-file", "quota"])
    func malformedChangedAndExhaustedSelectionsFailClosed(kind: String) async throws {
        let f = try await CreationFixture(), id = UUID(), p = try await f.prepare(id: id)
        switch kind {
        case "overlap": await #expect(throws: Error.self) { _ = try await f.prepare(.init(enable: [.cli], disable: [.cli])) }
        case "duplicate": await #expect(throws: Error.self) { _ = try await f.prepare(.init(enable: [.cli, .cli])) }
        case "private-edit":
            let draft = try #require(await f.service.creations[id]); try Data("changed private input".utf8).write(to: draft.frozen.storage.directory.appendingPathComponent("vm.yml"))
            await #expect(throws: ProvisioningReviewFailure.changed) { _ = try await f.create(p) }
        case "reserved-file":
            try Data("schema_version: 1\nid: collision\nassets: [.omarchy-manager-selection.json]\n".utf8).write(to: f.source.appendingPathComponent("vm.yml"))
            let sentinel = f.source.appendingPathComponent(ProvisioningService.selectionManifest); try Data("sentinel".utf8).write(to: sentinel)
            await #expect(throws: Error.self) { _ = try await f.prepare(.init(enable: [.cli])) }
            #expect(try Data(contentsOf: sentinel) == Data("sentinel".utf8))
        default:
            for _ in 1..<16 { _ = try await f.prepare() }
            await #expect(throws: ProvisioningReviewFailure.quota) { _ = try await f.prepare() }
            #expect(try await f.service.creation(p.id) == p)
        }
        await #expect(throws: Error.self) { _ = try await f.prepare(.init(enable: [.docker]), id: id) }
        #expect(await f.manager.snapshots().isEmpty)
        await f.assertInert(); await f.close()
    }
    @Test func customCatalogueDependenciesStillControlNativeDisabling() async throws {
        let f = try await CreationFixture()
        try Data("schema_version: 1\nnamespace: team\nfeatures: {tools: {description: Fixture tools, requires: [builtin.cli]}}\n".utf8).write(to: f.source.appendingPathComponent("catalogue.yml"))
        try Data("schema_version: 1\nid: dependency-fixture\nsetup: {catalogues: [catalogue.yml], features: {enable: [team.tools]}}\n".utf8).write(to: f.source.appendingPathComponent("vm.yml"))
        let p = try await f.prepare(.init(enable: [.docker])), draft = try #require(await f.service.creations[p.id])
        let features = draft.frozen.plan.document.object?["features"]?.object?["features"]?.array?.compactMap(\.string) ?? []
        #expect(features.contains("team.tools") && features.contains("cli"))
        #expect(draft.frozen.plan.snapshot.data(for: "catalogue.yml") != nil)
        await #expect(throws: Error.self) { _ = try await f.prepare(.init(disable: [.cli])) }
        await f.assertInert(); await f.close()
    }
    @Test func guestCommandCreationReturnsReceiptAndDuplicateRequestsNeverLaunch() async throws {
        let f = try await CreationFixture(), p = try await f.prepare(), commands = GuestCommandService(manager: f.manager, applicationSupport: f.root)
        var request = GuestCommandRequest(command: .create, config: .init(name: "CLI fixture", memoryMiB: 8192, cpus: 4, diskGiB: 96, ssh: false, ownerDefaults: false))
        request.setupConsent = .init(reviewID: p.id, reviewIdentity: p.reviewIdentity, acknowledged: true)
        let reply = await commands.execute(request), duplicate = await commands.execute(request)
        #expect(reply.ok && duplicate.ok && reply.guest?.id == duplicate.guest?.id && reply.guest?.developerSetup?.reviewID == p.id)
        #expect(reply.guest?.memoryMiB == 8192 && reply.guest?.diskGiB == 96 && reply.guest?.state == "stopped")
        var forbidden = request; forbidden.start = true
        #expect(await commands.execute(forbidden).ok == false)
        #expect(await f.manager.snapshots().count == 1)
        await f.assertInert(); await f.close()
    }
    @Test func concurrentHandoffCannotPublishTwoProfilesOrDuplicateSSHReservations() async throws {
        let f = try await CreationFixture(), a = try await f.prepare(), b = try await f.prepare()
        let manager = f.manager
        func create(_ review: ProvisioningCreationReview, name: String) async throws -> UUID {
            try await manager.create(name: name, memoryMiB: 4096, cpus: 4, clipboardEnabled: false, immersiveMode: false, useOwnerDefaults: false,
                setupConsent: .init(reviewID: review.id, reviewIdentity: review.reviewIdentity, acknowledged: true))
        }
        async let first = create(a, name: "Concurrent A")
        async let second = create(b, name: "Concurrent B")
        // A losing stale port reservation may fail closed; explicit new review is required.
        var successes = 0
        do { _ = try await first; successes += 1 } catch { }
        do { _ = try await second; successes += 1 } catch { }
        #expect(successes >= 1)
        let profiles = await manager.snapshots().map(\.profile)
        #expect(profiles.count == successes && Set(profiles.compactMap { $0.ssh?.hostPort }).count == profiles.count)
        await f.assertInert(); await f.close()
    }
    @Test(arguments: ["unknown", "null", "missing-ack", "duplicate-key", "start"])
    func creationConsentWireIsStrict(kind: String) throws {
        let id = UUID(), digest = String(repeating: "a", count: 64)
        var request = GuestCommandRequest(command: .create, config: .init(name: "strict fixture"))
        request.setupConsent = .init(reviewID: id, reviewIdentity: digest, acknowledged: true)
        var object = try JSONSerialization.jsonObject(with: helperJSON(request)) as! [String: Any]
        var consent = object["setupConsent"] as! [String: Any]
        switch kind {
        case "unknown": consent["execute"] = true
        case "null": consent["acknowledged"] = NSNull()
        case "missing-ack": consent.removeValue(forKey: "acknowledged")
        case "start": object["start"] = true
        default: break
        }
        object["setupConsent"] = consent
        var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if kind == "duplicate-key" { bytes = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"acknowledged\":true", with: "\"acknowledged\":true,\"acknowledged\":true").utf8) }
        #expect(throws: Error.self) { _ = try GuestCommandRequest.decodeStrict(bytes) }
    }
    @Test func frozenSelectionCanBeReviewedOverTheStrictExternalProtocol() async throws {
        let f = try await CreationFixture(), session = ProvisioningExternalSession(service: f.service), id = UUID()
        var request = ProvisioningExternalRequest(sequence: 1, operation: .prepareCreation)
        request.previewID = id; request.source = .init(directory: f.source.path, features: .init(enable: [.docker]))
        let reply = try await session.handle(ProvisioningExternalRequest.decode(helperJSON(request)))
        let decoded = try ProvisioningExternalReply.decode(helperJSON(reply), request: request)
        let review = try #require(decoded.creationReview)
        #expect(review.id == id && decoded.failure == nil)
        var lookup = ProvisioningExternalRequest(sequence: 2, operation: .creation); lookup.previewID = id
        #expect(try await session.handle(lookup).creationReview == review)
        _ = try await f.create(review)
        var bound = ProvisioningExternalRequest(sequence: 3, operation: .preview); bound.previewID = id
        let preview = try await session.handle(bound)
        #expect(try ProvisioningExternalReply.decode(helperJSON(preview), request: bound).previewPlan?.inputDigest == review.inputDigest)
        await session.close(); await f.assertInert(); await f.close()
    }
    @Test func typedCLIRequiresExplicitCreationAcknowledgementAndNeverCombinesStart() throws {
        let id = UUID(), digest = String(repeating: "a", count: 64)
        #expect(try ProvisioningSetupCLI.parse(["setup", "prepare-create", id.uuidString, "--preset", "developer", "--enable", "docker", "--disable", "cli"]) == .prepareCreation(id, .init(preset: "developer", features: .init(enable: [.docker], disable: [.cli]))))
        #expect(try ProvisioningSetupCLI.parse(["setup", "creation", id.uuidString]) == .creation(id))
        #expect(try ProvisioningSetupCLI.parse(["setup", "preview", id.uuidString, "--preset", "developer", "--preview-id", id.uuidString, "--disable", "cli"]) == .createPreview(id, id, .init(preset: "developer", features: .init(disable: [.cli]))))
        let args = ["create", "fixture", "--setup-review-id", id.uuidString, "--setup-review", digest, "--ack-setup-selection"]
        let request = try #require(GuestCLIInvocation.parse(args).request)
        #expect(request.setupConsent?.reviewID == id && !request.start && request.waitFor == nil)
        #expect(try GuestCommandRequest.decodeStrict(helperJSON(request)).setupConsent == request.setupConsent)
        for extra in [["--start"], ["--start", "--wait"], ["--wait"], ["--ack-setup-selection"]] {
            #expect(throws: Error.self) { _ = try GuestCLIInvocation.parse(args + extra) }
        }
        #expect(throws: Error.self) { _ = try GuestCLIInvocation.parse(Array(args.dropLast())) }
        #expect(throws: Error.self) { _ = try GuestCLIInvocation.parse(["update", id.uuidString] + Array(args.dropFirst(2))) }
        #expect(try GuestCLIInvocation.parse(["create", "legacy", "--start"]).request?.start == true)
        for tail in [["--enable", "docker", "--disable", "docker"], ["--enable", "unknown"], ["--enable", "cli", "--enable", "cli"], ["--preview-id", id.uuidString]] {
            #expect(throws: Error.self) { _ = try ProvisioningSetupCLI.parse(["setup", "prepare-create", id.uuidString, "--preset", "developer"] + tail) }
        }
    }
    @Test(arguments: ["unknown", "null", "duplicate", "overlap", "extra-vm", "duplicate-key"])
    func strictWireRejectsMalformedNativeChoices(kind: String) throws {
        let id = UUID().uuidString
        let features: String
        switch kind {
        case "unknown": features = "{\"enable\":[\"unknown\"],\"disable\":[]}"
        case "null": features = "null"
        case "duplicate": features = "{\"enable\":[\"cli\",\"cli\"],\"disable\":[]}"
        case "overlap": features = "{\"enable\":[\"cli\"],\"disable\":[\"cli\"]}"
        case "duplicate-key": features = "{\"enable\":[\"cli\"],\"enable\":[],\"disable\":[]}"
        default: features = "{\"enable\":[\"cli\"],\"disable\":[],\"vmID\":\"\(id)\"}"
        }
        let json = "{\"version\":1,\"requestID\":\"\(id)\",\"sequence\":1,\"operation\":\"prepareCreation\",\"previewID\":\"\(id)\",\"source\":{\"preset\":\"developer\",\"features\":\(features)}}"
        #expect(throws: Error.self) { _ = try ProvisioningExternalRequest.decode(Data(json.utf8)) }
    }
}
