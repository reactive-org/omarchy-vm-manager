import DevVMProvisioningCore
import Foundation
@testable import OmarchyVMManagerCore
import Testing

@Suite("Frozen review UI/CLI contract", .serialized) struct ProvisioningReviewProtocolTests {
    @Test func socketAndNativeServiceShareOneFrozenReviewAndSingleSubmission() async throws {
        let source = "- ansible.builtin.debug: {msg: SYNTHETIC-REVIEW-ONLY-CONTENT}\n"
        let f = try await WorkflowFixture(task: source)
        let endpoint = ManagerCommandEndpoint(directory: f.root.appendingPathComponent("review-ipc"))
        let server = try ProvisioningExternalServer(endpoint: endpoint, service: f.service); defer { server.stop() }
        let cli = ProvisioningExternalClient(endpoint: endpoint), id = UUID()
        let created = try await cli.request(.previewCreate, previewID: id, vmID: f.profile.id, source: .init(directory: f.source.path))
        let preview = try #require(created.previewPlan)
        #expect(preview == (try await f.service.preview(id)))
        #expect(!String(decoding: try helperJSON(created), as: UTF8.self).contains("SYNTHETIC-REVIEW-ONLY-CONTENT"))
        let chunk = try await cli.request(.taskSource, previewID: id, taskName: "custom", offset: 0)
        #expect(chunk.taskSource?.bytes == Data(source.utf8))
        #expect(!String(reflecting: chunk).contains("SYNTHETIC-REVIEW-ONLY-CONTENT"))
        let prepared = try await cli.request(.prepareApply, previewID: id)
        let review = try #require(prepared.applyReview)
        #expect(try await f.service.prepareApply(id) == review)
        let missingTrust = ProvisioningApplyConsent(reviewIdentity: review.reviewIdentity, persistentGrantAcknowledged: true)
        #expect(try await cli.request(.apply, previewID: id, consent: missingTrust).failure == "task-trust-required")
        let consent = ProvisioningApplyConsent(reviewIdentity: review.reviewIdentity, taskTrustIdentity: review.taskTrustIdentity, persistentGrantAcknowledged: true)
        // Native API submits; CLI retries the exact reviewed consent as a lookup.
        _ = try await f.service.apply(id, consent: consent)
        #expect(try await cli.request(.apply, previewID: id, consent: consent).workflows?.first?.id == id)
        #expect(try await f.service.wait(id).stage == .succeeded)
        #expect(try await cli.request(.status, workflowID: id).workflows?.first?.stage == .succeeded)
        #expect(await f.launcher.launches == 1)
        await cli.close(); await f.close()
    }
    @Test func productEndpointFreezesWithoutProbesAndApplyRemainsDisabled() async throws {
        let f = try await WorkflowFixture(enabled: false)
        let endpoint = ManagerCommandEndpoint(directory: f.root.appendingPathComponent("review-ipc"))
        let server = try ProvisioningExternalServer(endpoint: endpoint, service: f.service); defer { server.stop() }
        let cli = ProvisioningExternalClient(endpoint: endpoint), id = UUID()
        #expect(try await cli.request(.previewCreate, previewID: id, vmID: f.profile.id, source: .init(preset: "developer")).previewPlan?.id == id)
        #expect(try await cli.request(.prepareApply, previewID: id).failure == "disabled")
        #expect(try await cli.request(.apply, previewID: id, consent: .init(reviewIdentity: String(repeating: "a", count: 64), persistentGrantAcknowledged: true)).failure == "disabled")
        #expect(await f.dependencies.inspections == 0); #expect(await f.launcher.launches == 0)
        await cli.close(); await f.close()
    }
    @Test(arguments: ["source-null", "source-extra", "source-double", "source-relative", "consent-null", "consent-extra", "consent-null-bool", "trust-boolean", "scope-null", "task-offset"])
    func strictReviewWireRejectsAmbiguousOrUnscopedInputs(kind: String) throws {
        var request = ProvisioningExternalRequest(sequence: 1, operation: .previewCreate)
        request.previewID = UUID(); request.vmID = UUID(); request.source = .init(preset: "developer")
        if kind.hasPrefix("consent") || kind == "trust-boolean" {
            request = .init(sequence: 1, operation: .apply); request.previewID = UUID()
            request.consent = .init(reviewIdentity: String(repeating: "a", count: 64))
        }
        if kind == "task-offset" { request = .init(sequence: 1, operation: .taskSource); request.previewID = UUID(); request.taskName = "custom"; request.offset = -1 }
        var document = try #require(JSONSerialization.jsonObject(with: helperJSON(request)) as? [String: Any])
        switch kind {
        case "source-null": document["source"] = NSNull()
        case "source-extra": document["source"] = ["preset": "developer", "argv": []] as [String: Any]
        case "source-double": document["source"] = ["preset": "developer", "directory": "/private/tmp"]
        case "source-relative": document["source"] = ["directory": "../escape"]
        case "consent-null": document["consent"] = NSNull()
        case "consent-extra": document["consent"] = ["reviewIdentity": String(repeating: "a", count: 64), "persistentGrantAcknowledged": true, "dockerRootAccessAcknowledged": false, "password": "forbidden"] as [String: Any]
        case "consent-null-bool": document["consent"] = ["reviewIdentity": String(repeating: "a", count: 64), "persistentGrantAcknowledged": NSNull(), "dockerRootAccessAcknowledged": false] as [String: Any]
        case "trust-boolean": document["consent"] = ["reviewIdentity": String(repeating: "a", count: 64), "persistentGrantAcknowledged": true, "dockerRootAccessAcknowledged": false, "taskTrustIdentity": true] as [String: Any]
        case "scope-null": document["previewID"] = NSNull()
        default: break
        }
        #expect(throws: Error.self) { _ = try ProvisioningExternalRequest.decode(JSONSerialization.data(withJSONObject: document)) }
    }
    @Test func commandParsingNeverInfersTrustOrAcceptsSecretsOrDuplicateFlags() throws {
        let id = UUID(), vm = UUID(), hash = String(repeating: "a", count: 64)
        if case .createPreview(let v, let p, let source) = try ProvisioningSetupCLI.parse(["setup", "preview", vm.uuidString, "--preset", "developer", "--preview-id", id.uuidString]) {
            #expect(v == vm && p == id && source.preset == "developer")
        } else { Issue.record("Preview not parsed") }
        if case .apply(let p, let consent) = try ProvisioningSetupCLI.parse(["setup", "apply", id.uuidString, "--review", hash]) {
            #expect(p == id && !consent.persistentGrantAcknowledged && !consent.dockerRootAccessAcknowledged && consent.taskTrustIdentity == nil)
        } else { Issue.record("Consent not parsed") }
        for options in [["--review", hash, "--ack-sudo", "--ack-sudo"], ["--review", hash, "--password", "forbidden"], ["--review", hash, "--trust-tasks", "true"], ["--review", "wrong"]] {
            #expect(throws: VMFailure.self) { _ = try ProvisioningSetupCLI.parse(["setup", "apply", id.uuidString] + options) }
        }
        #expect(throws: VMFailure.self) { _ = try ProvisioningSetupCLI.parse(["setup", "preview", vm.uuidString, "--from", "/path"]) }
        #expect(try ProvisioningSetupCLI.parse(["setup", "status", id.uuidString]) == .status(id))
    }
}
