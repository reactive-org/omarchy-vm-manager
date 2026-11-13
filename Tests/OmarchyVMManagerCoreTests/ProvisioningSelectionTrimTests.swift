import Foundation
import Testing
@testable import DevVMProvisioningCore
@testable import OmarchyVMManagerCore

@Suite("Optional-app trim selection — offline/local fixtures") struct ProvisioningSelectionTrimTests {
    @Test func trimChoiceIsFrozenReviewableAndRequiresAFreshAcknowledgment() async throws {
        let f = try await CreationFixture()
        let original = try Data(contentsOf: f.source.appendingPathComponent("vm.yml"))
        let off = try await f.service.prepareCreation(source: .init(directory: f.source.path, trimOptionalApps: false))
        let on = try await f.service.prepareCreation(source: .init(directory: f.source.path, trimOptionalApps: true))
        #expect(!ProvisioningTrim.isRequested(in: off.proposal) && ProvisioningTrim.isRequested(in: on.proposal))
        #expect(on.inputDigest != off.inputDigest && on.reviewIdentity != off.reviewIdentity)
        let doc = try PlainDataParser.parse(on.proposal, format: .json)
        #expect(doc.object?["requirements"]?.object?["removals"]?.array?.contains(.string("libreoffice-fresh")) == true)
        #expect(try Data(contentsOf: f.source.appendingPathComponent("vm.yml")) == original)
        let id = try await f.create(on)
        #expect(await f.manager.snapshots().first?.id == id)
        #expect(ProvisioningTrim.isRequested(in: try await f.service.preview(on.id).proposal))
        await f.assertInert(); await f.close()
    }
    @Test func unsupportedFactoryCannotConsumeATrimmedCreationReview() async throws {
        let f = try await CreationFixture()
        let review = try await f.service.prepareCreation(source: .init(profiles: ["developer"], trimOptionalApps: true))
        let custom = FactoryIdentity(kind: .custom, name: "Try Omarchy", manifestSHA256: String(repeating: "b", count: 64), diskSHA256: String(repeating: "c", count: 64))
        for factory in [nil, custom] as [FactoryIdentity?] {
            #expect(!ProvisioningTrim.isAvailable(for: factory))
            await #expect(throws: ProvisioningReviewFailure.invalid) {
                _ = try await f.service.reserveCreation(.init(reviewID: review.id, reviewIdentity: review.reviewIdentity, acknowledged: true), vmID: UUID(), configurationDigest: String(repeating: "a", count: 64), factory: factory)
            }
        }
        #expect(await f.service.creations[review.id]?.reservation == nil)
        #expect(ProvisioningTrim.isAvailable(for: .official))
        _ = try await f.create(review)
        await f.assertInert(); await f.close()
    }
    @Test func nativeOffExplicitlyOverridesLocalTrimWhileLegacySelectionPreservesIt() async throws {
        let f = try await CreationFixture(manifest: "schema_version: 1\nid: local-trim\nvm: {lean_developer: true, packages: ['pkg:obsidian']}\n")
        let legacy = try await f.prepare()
        let off = try await f.service.prepareCreation(source: .init(directory: f.source.path, trimOptionalApps: false))
        #expect(ProvisioningTrim.isRequested(in: legacy.proposal) && !ProvisioningTrim.isRequested(in: off.proposal))
        let doc = try PlainDataParser.parse(legacy.proposal, format: .json)
        #expect(doc.object?["requirements"]?.object?["removals"]?.array?.contains(.string("obsidian")) == false)
        #expect(try SetupManifest.parse(Data(contentsOf: f.source.appendingPathComponent("vm.yml")), format: .yaml).vm.leanDeveloper)
        await f.assertInert(); await f.close()
    }
    @Test(arguments: ["true", "false", "null", "string", "number"])
    func trimWireIsStrictAndRoundTripsOnlyBooleans(kind: String) throws {
        var request = ProvisioningExternalRequest(sequence: 1, operation: .prepareCreation)
        request.previewID = UUID(); request.source = .init(profiles: ["developer"], trimOptionalApps: true)
        var object = try #require(JSONSerialization.jsonObject(with: helperJSON(request)) as? [String: Any])
        var source = try #require(object["source"] as? [String: Any])
        source["trimOptionalApps"] = switch kind { case "true": true; case "false": false; case "null": NSNull(); case "string": "true"; default: 1 }
        object["source"] = source
        let bytes = try JSONSerialization.data(withJSONObject: object)
        if kind == "true" || kind == "false" { #expect(try ProvisioningExternalRequest.decode(bytes).source?.trimOptionalApps == (kind == "true")) }
        else { #expect(throws: Error.self) { _ = try ProvisioningExternalRequest.decode(bytes) } }
    }
}
