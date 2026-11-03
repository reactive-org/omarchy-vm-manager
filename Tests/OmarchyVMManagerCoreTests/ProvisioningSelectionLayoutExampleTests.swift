import Foundation
import Testing
@testable import DevVMProvisioningCore
@testable import OmarchyVMManagerCore

@Suite("Bundled layout cards — frozen local inputs") struct ProvisioningSelectionLayoutExampleTests {
    @Test(arguments: ProvisioningLayoutExampleID.allCases)
    func selectingAnExampleFreezesItsExactLuaWithoutInstallingApps(id: ProvisioningLayoutExampleID) async throws {
        let f = try await CreationFixture()
        let source = ProvisioningSetupSource(profiles: ["developer"], appearance: .init(layoutExample: id))
        let review = try await f.service.prepareCreation(source: source)
        let frozen = try #require(await f.service.creations[review.id]?.frozen)
        #expect(frozen.plan.snapshot.data(for: ProvisioningService.selectionLayout) == (try LayoutExamples.source(id)))
        #expect(frozen.plan.document.object?["vm"]?.object?["packages"] == .array([]))
        #expect(ProvisioningAppearanceSummary(proposal: review.proposal).layoutExample?.id == id)
        #expect(try await f.service.creation(review.id) == review)
        _ = try await f.create(review)
        await f.assertInert(); await f.close()
    }
    @Test func changingCardsNeedsANewReviewAndOldFrozenBytesRemainStable() async throws {
        let f = try await CreationFixture()
        let old = try await f.service.prepareCreation(source: .init(profiles: ["developer"], appearance: .init(layoutExample: .fourTerminals)))
        let next = try await f.service.prepareCreation(source: .init(profiles: ["developer"], appearance: .init(layoutExample: .vscodeBrowser)))
        #expect(old.inputDigest != next.inputDigest && old.reviewIdentity != next.reviewIdentity)
        #expect(try await f.service.creation(old.id) == old)
        let frozen = try #require(await f.service.creations[old.id]?.frozen)
        #expect(frozen.plan.snapshot.data(for: ProvisioningService.selectionLayout) == (try LayoutExamples.source(.fourTerminals)))
        await f.assertInert(); await f.close()
    }
    @Test func examplesCannotBeCombinedWithCustomFileOrRemovalAndOldSourcesStayCompatible() throws {
        for value in [ProvisioningAppearanceSelection(layoutFile: "/private/tmp/fixture.lua", layoutExample: .fourTerminals), .init(removeLayout: true, layoutExample: .fourTerminals)] {
            #expect(throws: ProvisioningAppearanceFailure.invalidLayout) { try value.validate() }
        }
        let legacy = try JSONDecoder().decode(ProvisioningAppearanceSelection.self, from: Data(#"{"minimumStars":10,"removeLayout":false,"layoutFile":"/private/tmp/fixture.lua"}"#.utf8))
        #expect(legacy.layoutExample == nil && legacy.layoutFile == "/private/tmp/fixture.lua")
    }
    @Test func nativeCLIAndSocketUseTheSameFixedExampleIdentifier() async throws {
        let f = try await CreationFixture(), id = UUID()
        let source: ProvisioningSetupSource
        if case .prepareCreation(_, let selected) = try ProvisioningSetupCLI.parse(["setup", "prepare-create", id.uuidString, "--preset", "developer", "--layout-example", "terminal-browser"]) { source = selected }
        else { throw ProvisioningReviewFailure.invalid }
        #expect(source.appearance?.layoutExample == .terminalBrowser)
        let endpoint = ManagerCommandEndpoint(directory: f.root.appendingPathComponent("le"))
        let server = try ProvisioningExternalServer(endpoint: endpoint, service: f.service); defer { server.stop() }
        let client = ProvisioningExternalClient(endpoint: endpoint)
        let reply = try await client.request(.prepareCreation, previewID: id, source: source)
        #expect(reply.failure == nil)
        let review = try #require(reply.creationReview)
        #expect(ProvisioningAppearanceSummary(proposal: review.proposal).layoutExample?.id == .terminalBrowser)
        #expect(try await f.service.creation(id) == review)
        await client.close(); await f.assertInert(); await f.close()
    }
    @Test(arguments: ["unknown", "path", "null", "number", "both", "removal"])
    func strictWireRejectsUnknownAndAmbiguousExampleChoices(kind: String) throws {
        var request = ProvisioningExternalRequest(sequence: 1, operation: .prepareCreation)
        request.previewID = UUID(); request.source = .init(profiles: ["developer"], appearance: .init(layoutExample: .fourTerminals))
        var object = try #require(JSONSerialization.jsonObject(with: helperJSON(request)) as? [String: Any])
        var source = try #require(object["source"] as? [String: Any]), appearance = try #require(source["appearance"] as? [String: Any])
        switch kind {
        case "unknown": appearance["layoutExample"] = "not-bundled"
        case "path": appearance["layoutExample"] = "../four-terminals.lua"
        case "null": appearance["layoutExample"] = NSNull()
        case "number": appearance["layoutExample"] = 1
        case "both": appearance["layoutFile"] = "/private/tmp/fixture.lua"
        default: appearance["removeLayout"] = true
        }
        source["appearance"] = appearance; object["source"] = source
        #expect(throws: Error.self) { _ = try ProvisioningExternalRequest.decode(JSONSerialization.data(withJSONObject: object)) }
    }
}
