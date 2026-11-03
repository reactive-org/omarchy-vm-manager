import Foundation
import Testing
@testable import DevVMProvisioningCore
@testable import OmarchyVMManagerCore

@Suite("Multiple setup profiles — offline/local fixtures") struct ProvisioningProfileSelectionTests {
    @Test func bundledProfilesFreezeTheSharedResolvedCombinationAndCreateOnlyMetadata() async throws {
        let f = try await CreationFixture()
        let review = try await f.service.prepareCreation(source: .init(profiles: ["developer", "web"]))
        let draft = try #require(await f.service.creations[review.id])
        let expected = try FeaturePlanner.resolve(profiles: ["developer", "web"])
        #expect(draft.frozen.plan.document.object?["features"] == expected.document)
        let original = try #require(draft.frozen.plan.snapshot.data(for: "SetupProfiles.json"))
        #expect(try SetupManifest.parse(original, format: .json).selection.object?["profiles"] == .array([]))
        let projected = try #require(draft.frozen.plan.snapshot.data(for: ProvisioningService.selectionManifest))
        #expect(try SetupManifest.parse(projected, format: .json).selection.object?["profiles"] == .array([.string("developer"), .string("web")]))
        let id = try await f.create(review)
        #expect(await f.manager.snapshots().first?.id == id)
        #expect(await f.manager.snapshots().first?.state == .stopped)
        await f.assertInert(); await f.close()
    }
    @Test func localProfilesAreAddedWithoutReplacingDeclaredAliasesTasksOrSettings() async throws {
        let f = try await CreationFixture()
        let manifest = """
        schema_version: 1
        id: local-profile-fixture
        setup: {profiles: [builtin.developer], options: {databases: {clients: [sqlite]}}}
        tasks: [{name: custom, file: custom.yml}]
        vars: {fixture: keep}
        """
        try Data(manifest.utf8).write(to: f.source.appendingPathComponent("vm.yml"))
        try Data("- ansible.builtin.debug: {msg: SYNTHETIC-ONLY}\n".utf8).write(to: f.source.appendingPathComponent("custom.yml"))
        let original = try Data(contentsOf: f.source.appendingPathComponent("vm.yml"))
        let review = try await f.service.prepareCreation(source: .init(directory: f.source.path, profiles: ["developer", "python"]))
        let draft = try #require(await f.service.creations[review.id])
        let projected = try #require(draft.frozen.plan.snapshot.data(for: ProvisioningService.selectionManifest))
        let selection = try SetupManifest.parse(projected, format: .json)
        #expect(selection.selection.object?["profiles"] == .array([.string("builtin.developer"), .string("python")]))
        #expect(selection.variables["fixture"] == .string("keep") && review.tasks.map(\.name) == ["custom"])
        #expect(draft.frozen.plan.document.object?["features"]?.object?["features"]?.array?.contains(.string("languages")) == true)
        #expect(try Data(contentsOf: f.source.appendingPathComponent("vm.yml")) == original)
        #expect(!FileManager.default.fileExists(atPath: f.source.appendingPathComponent(ProvisioningService.selectionManifest).path))
        await f.assertInert(); await f.close()
    }
    @Test func siblingConflictsAreRefusedRatherThanChoosingAWinner() async throws {
        let f = try await CreationFixture()
        await #expect(throws: ProvisioningReviewFailure.conflictingProfiles) {
            _ = try await f.service.prepareCreation(source: .init(profiles: ["web", "python"]))
        }
        #expect(await f.service.reviewCount == 0)
        await f.assertInert(); await f.close()
    }
    @Test func explicitLocalOptionsCanResolveCombinedProfileConflicts() async throws {
        let f = try await CreationFixture(manifest: "schema_version: 1\nid: resolved-profiles\nsetup: {profiles: [web], options: {databases: {clients: [sqlite]}}}\n")
        let review = try await f.service.prepareCreation(source: .init(directory: f.source.path, profiles: ["python"]))
        let draft = try #require(await f.service.creations[review.id])
        let features = try #require(draft.frozen.plan.document.object?["features"]?.object)
        #expect(features["options"]?.object?["databases"]?.object?["clients"] == .array([.string("sqlite")]))
        let tools = try #require(features["options"]?.object?["languages"]?.object?["tools"]?.object)
        #expect(Set(tools.keys) == ["node", "pnpm", "python", "uv"])
        await f.assertInert(); await f.close()
    }
    @Test(arguments: ["empty", "missing", "duplicate", "unknown", "mixed", "false", "null", "extra"])
    func strictWireRejectsAmbiguousOrUnsupportedProfileSelections(kind: String) throws {
        var request = ProvisioningExternalRequest(sequence: 1, operation: .prepareCreation)
        request.previewID = UUID(); request.source = .init(profiles: ["developer", "web"])
        var document = try #require(JSONSerialization.jsonObject(with: helperJSON(request)) as? [String: Any])
        var source = ["bundled": true, "profiles": ["developer"]] as [String: Any]
        switch kind {
        case "empty": source["profiles"] = []
        case "missing": source.removeValue(forKey: "profiles")
        case "duplicate": source["profiles"] = ["developer", "developer"]
        case "unknown": source["profiles"] = ["arbitrary"]
        case "mixed": source["directory"] = "/private/tmp"
        case "false": source["bundled"] = false
        case "null": source["profiles"] = NSNull()
        default: source["command"] = "forbidden"
        }
        document["source"] = source
        #expect(throws: Error.self) { _ = try ProvisioningExternalRequest.decode(JSONSerialization.data(withJSONObject: document)) }
    }
    @Test func newProfileSelectionNeedsNewReviewAndOldFrozenBytesStayUnchanged() async throws {
        let f = try await CreationFixture(), id = UUID()
        let old = try await f.service.prepareCreation(id: id, source: .init(profiles: ["developer"]))
        let next = try await f.service.prepareCreation(source: .init(profiles: ["developer", "web"]))
        #expect(old.id != next.id && old.inputDigest != next.inputDigest)
        #expect(try await f.service.creation(id) == old)
        await #expect(throws: ProvisioningJobFailure.jobConflict) {
            _ = try await f.service.prepareCreation(id: id, source: .init(profiles: ["python"]))
        }
        await f.assertInert(); await f.close()
    }
    @Test func nativeAndExternalProfileReviewUseTheSameFrozenInputs() async throws {
        let f = try await CreationFixture(), id = UUID()
        let endpoint = ManagerCommandEndpoint(directory: f.root.appendingPathComponent("profile-ipc"))
        let server = try ProvisioningExternalServer(endpoint: endpoint, service: f.service); defer { server.stop() }
        let client = ProvisioningExternalClient(endpoint: endpoint)
        let reply = try await client.request(.prepareCreation, previewID: id, source: .init(profiles: ["developer", "web"]))
        #expect(reply.creationReview == (try await f.service.creation(id)))
        if case .prepareCreation(_, let oldSource) = try ProvisioningSetupCLI.parse(["setup", "prepare-create", UUID().uuidString, "--preset", "developer"]) {
            #expect(oldSource.preset == "developer" && oldSource.profiles == nil && oldSource.bundled == nil)
        } else { Issue.record("Legacy CLI preset changed") }
        await client.close(); await f.assertInert(); await f.close()
    }
    @Test func cardMetadataComesFromTheSharedResolverIncludingInheritedFeaturesAndTools() throws {
        let cards = try BundledProvisioning.profileSummaries()
        #expect(cards.map(\.id) == BundledProvisioning.presets)
        for card in cards {
            let resolved = try FeaturePlanner.resolve(profiles: [card.id])
            #expect(card.includedFeatures == resolved.features)
            #expect(Set(card.additionalFeatures).isSubset(of: Set(resolved.features)))
        }
        let python = try #require(cards.first { $0.id == "python" }), web = try #require(cards.first { $0.id == "web" })
        #expect(python.includesDeveloper && python.tools == ["python", "uv"] && python.databaseClients == ["sqlite"])
        #expect(web.tools == ["node", "pnpm"] && web.databaseClients == ["postgresql", "sqlite"])
        #expect(!python.additionalFeatures.contains("cli") && python.includedFeatures.contains("cli"))
    }
}
