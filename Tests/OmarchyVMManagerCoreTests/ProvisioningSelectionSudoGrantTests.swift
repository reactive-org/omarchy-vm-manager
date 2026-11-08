import Foundation
import Testing
@testable import DevVMProvisioningCore
@testable import OmarchyVMManagerCore

@Suite("Setup sudo grant selection — offline/local fixtures") struct ProvisioningSelectionSudoGrantTests {
    @Test func grantChoiceIsFrozenIntoTheReviewedPlan() async throws {
        let f = try await CreationFixture()
        let timed = try await f.service.prepareCreation(source: .init(directory: f.source.path, permanentSudoGrant: false))
        let permanent = try await f.service.prepareCreation(source: .init(directory: f.source.path, permanentSudoGrant: true))
        let legacy = try await f.prepare()
        #expect(ProvisioningSudoGrant.isTimed(in: timed.proposal))
        #expect(!ProvisioningSudoGrant.isTimed(in: permanent.proposal) && !ProvisioningSudoGrant.isTimed(in: legacy.proposal))
        #expect(timed.reviewIdentity != permanent.reviewIdentity && timed.planDigest != permanent.planDigest)
        await f.assertInert(); await f.close()
    }
    @Test func nativeChoiceOverridesTheManifestWhileLegacySelectionPreservesIt() async throws {
        let f = try await CreationFixture(manifest: "schema_version: 1\nid: local-timed\nvm: {sudo_grant: timed}\n")
        let legacy = try await f.prepare()
        let permanent = try await f.service.prepareCreation(source: .init(directory: f.source.path, permanentSudoGrant: true))
        #expect(ProvisioningSudoGrant.isTimed(in: legacy.proposal) && !ProvisioningSudoGrant.isTimed(in: permanent.proposal))
        await f.assertInert(); await f.close()
    }
    @Test func unsetChoiceIsLeftOutOfSavedSources() throws {
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProvisioningSetupSource(profiles: ["developer"]))) as? [String: Any]
        #expect(legacy?["permanentSudoGrant"] == nil)
        let chosen = try JSONDecoder().decode(ProvisioningSetupSource.self, from: JSONEncoder().encode(ProvisioningSetupSource(profiles: ["developer"], permanentSudoGrant: false)))
        #expect(chosen.permanentSudoGrant == false)
    }
    @Test func cliChoosesTheGrantOnlyWhenAsked() throws {
        let id = UUID()
        let base = ["setup", "prepare-create", id.uuidString, "--preset", "developer"]
        #expect(try ProvisioningSetupCLI.parse(base) == .prepareCreation(id, .init(preset: "developer")))
        #expect(try ProvisioningSetupCLI.parse(base + ["--sudo-grant", "timed"]) == .prepareCreation(id, .init(preset: "developer", permanentSudoGrant: false)))
        #expect(try ProvisioningSetupCLI.parse(base + ["--sudo-grant", "permanent"]) == .prepareCreation(id, .init(preset: "developer", permanentSudoGrant: true)))
        #expect(throws: Error.self) { _ = try ProvisioningSetupCLI.parse(base + ["--sudo-grant", "forever"]) }
    }
    @Test func defaultsStoreRoundTrips() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let store = SetupDefaultsStore(applicationSupport: f.support)
        #expect(try store.load() == SetupDefaults())
        try store.save(SetupDefaults(permanentSudoGrant: true))
        #expect(try store.load().permanentSudoGrant)
    }
    @Test func onlyTheInitialRequestShowsAsTheSudoPrompt() {
        #expect(GuestOperation.requestPersistentGrant.asksForSudoGrant && GuestOperation.requestTemporaryGrant.asksForSudoGrant)
        #expect(!GuestOperation.renewTemporaryGrant.asksForSudoGrant)
        for operation in [GuestOperation.requestTemporaryGrant, .renewTemporaryGrant] {
            #expect(SetupTimeoutNote.step(operation) == "Omarchy’s passwordless sudo prompt wasn’t answered within an hour")
        }
    }
}
