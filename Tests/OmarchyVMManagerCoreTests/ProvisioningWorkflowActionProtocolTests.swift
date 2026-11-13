import Foundation
@testable import OmarchyVMManagerCore
import Testing

@Suite("Reviewed workflow action UI/CLI protocol", .serialized) struct ProvisioningWorkflowActionProtocolTests {
    @Test func cliAndNativeRestartShareOneReviewedActionAndDoNotAutoCheck() async throws {
        let f = try await WorkflowFixture(docker: true, allowRebind: true), id = try await f.apply()
        let endpoint = ManagerCommandEndpoint(directory: f.root.appendingPathComponent("action-ipc"))
        let server = try ProvisioningExternalServer(endpoint: endpoint, service: f.service); defer { server.stop() }
        let cli = ProvisioningExternalClient(endpoint: endpoint), reviewID = UUID()
        let prepared = try await cli.request(.prepareAction, workflowID: id, action: .restart, actionReviewID: reviewID)
        let review = try #require(prepared.workflowActionReview)
        #expect(try await f.service.prepareAction(id, action: .restart, reviewID: reviewID) == review)
        #expect(try await cli.request(.performAction, workflowID: id, actionConsent: .init(reviewID: reviewID, action: .restart, reviewIdentity: review.reviewIdentity)).failure == "review-required")
        let consent = ProvisioningWorkflowActionConsent(reviewID: reviewID, action: .restart, reviewIdentity: review.reviewIdentity, acknowledged: true)
        _ = try await f.service.performAction(id, consent: consent)
        #expect(try await cli.request(.performAction, workflowID: id, actionConsent: consent).workflows?.first?.id == id)
        #expect(f.runtime.startedHandles.count == 1 && f.runtime.startedHandles[0].shutdownCount == 1)
        f.runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(await eventually { f.runtime.startedHandles.count == 2 })
        #expect(try await f.service.wait(id).stage == .waitingForRebind)
        #expect(try await cli.request(.status, workflowID: id).workflows?.first?.stage == .waitingForRebind)
        #expect(await f.launcher.launches == 1) // No implicit check or setup replay.
        try await f.service.cancel(id); await cli.close(); await f.close()
    }
    @Test func disabledProductEndpointAcceptsActionSchemasWithoutDoingWork() async throws {
        let f = try await WorkflowFixture(enabled: false)
        let endpoint = ManagerCommandEndpoint(directory: f.root.appendingPathComponent("action-ipc"))
        let server = try ProvisioningExternalServer(endpoint: endpoint, service: f.service); defer { server.stop() }
        let cli = ProvisioningExternalClient(endpoint: endpoint)
        for action in ProvisioningWorkflowAction.allCases {
            let reviewID = UUID()
            #expect(try await cli.request(.prepareAction, workflowID: UUID(), action: action, actionReviewID: reviewID).failure == "disabled")
            #expect(try await cli.request(.performAction, workflowID: UUID(), actionConsent: .init(reviewID: reviewID, action: action, reviewIdentity: String(repeating: "a", count: 64), acknowledged: true)).failure == "disabled")
        }
        #expect(await f.dependencies.inspections == 0); #expect(await f.launcher.launches == 0)
        #expect(f.runtime.startedHandles[0].shutdownCount == 0)
        await cli.close(); await f.close()
    }
    @Test(arguments: ["null-id", "null-action", "unknown-action", "scope-null", "consent-null", "ack-null", "secret", "preview-scope", "extra", "digest"])
    func actionWireRefusesUnscopedUnknownOrSecretInputs(kind: String) throws {
        var request = ProvisioningExternalRequest(sequence: 1, operation: .prepareAction, workflowID: UUID())
        request.action = .restart; request.actionReviewID = UUID()
        if ["consent-null", "ack-null", "secret", "digest"].contains(kind) {
            request = .init(sequence: 1, operation: .performAction, workflowID: UUID())
            request.actionConsent = .init(reviewID: UUID(), action: .recover, reviewIdentity: String(repeating: "a", count: 64), acknowledged: true)
        }
        var object = try #require(JSONSerialization.jsonObject(with: helperJSON(request)) as? [String: Any])
        switch kind {
        case "null-id": object["actionReviewID"] = NSNull()
        case "null-action": object["action"] = NSNull()
        case "unknown-action": object["action"] = "apply"
        case "scope-null": object["workflowID"] = NSNull()
        case "consent-null": object["actionConsent"] = NSNull()
        case "preview-scope": object["previewID"] = UUID().uuidString
        case "extra": object["force"] = true
        default:
            var consent = try #require(object["actionConsent"] as? [String: Any])
            if kind == "ack-null" { consent["acknowledged"] = NSNull() }
            else if kind == "secret" { consent["password"] = "forbidden" }
            else { consent["reviewIdentity"] = "wrong" }
            object["actionConsent"] = consent
        }
        #expect(throws: Error.self) { _ = try ProvisioningExternalRequest.decode(JSONSerialization.data(withJSONObject: object)) }
    }
    @Test func cliDoesNotInferAcknowledgementOrAcceptForceAndSecrets() throws {
        let id = UUID(), reviewID = UUID(), hash = String(repeating: "a", count: 64)
        for action in ProvisioningWorkflowAction.allCases {
            #expect(try ProvisioningSetupCLI.parse(["setup", "prepare-" + action.rawValue, id.uuidString, "--review-id", reviewID.uuidString]) == .prepareAction(id, action, reviewID))
            if case .performAction(let workflow, let consent) = try ProvisioningSetupCLI.parse(["setup", action.rawValue, id.uuidString, "--review-id", reviewID.uuidString, "--review", hash]) {
                #expect(workflow == id && consent.reviewID == reviewID && consent.action == action && !consent.acknowledged)
            } else { Issue.record("Missing workflow action") }
        }
        for options in [["--ack", "--ack"], ["--force"], ["--password", "forbidden"], ["--task-trust", hash]] {
            #expect(throws: VMFailure.self) { _ = try ProvisioningSetupCLI.parse(["setup", "recover", id.uuidString, "--review-id", reviewID.uuidString, "--review", hash] + options) }
        }
        #expect(throws: VMFailure.self) { _ = try ProvisioningSetupCLI.parse(["setup", "prepare-restart", id.uuidString, "--review-id", reviewID.uuidString, "--ack"]) }
    }
}
