import Darwin
import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private func reservedWorker() throws -> (ProvisioningHelperIdentity, ProvisioningHelperWorkerRegistration) {
    let identity = ProvisioningHelperIdentity(instanceID: UUID(), executableSHA256: String(repeating: "e", count: 64), packageLockSHA256: ProvisioningPackagePin.lockSHA256)
    var scope = try helperTestExpectation(); scope.helperIdentity = identity
    return (identity, .init(scope: scope, planDigest: String(repeating: "a", count: 64), inputDigest: String(repeating: "b", count: 64), mode: .apply))
}
@Suite("Provisioning admitted registration — inert local workers only") struct ProvisioningHelperRegistrationTests {
    @Test func versionedBootstrapAdmitsOneExactReservationAndReturnsAuthenticatedReceipt() async throws {
        let (identity, registration) = try reservedWorker()
        let credentials = try ProvisioningHelperCredentials(identity: identity, registration: registration)
        let restored = try ProvisioningHelperCredentials(privateBootstrap: credentials.privateBootstrap())
        #expect(restored.registration == registration && restored.identity == identity)
        var fds = [Int32](repeating: -1, count: 2); #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let clientSocket = try ProvisioningHelperSocket(taking: fds[0]), serverSocket = try ProvisioningHelperSocket(taking: fds[1])
        let registry = try ProvisioningHelperOwnershipRegistry(identity: identity)
        let server = try ProvisioningHelperIPCServer(socket: serverSocket, credentials: restored, registry: registry)
        let serving = Task { await server.serve() }
        let client = ProvisioningHelperIPCClient(socket: clientSocket, credentials: credentials)
        let ticket = ProvisioningHelperLaunchTicket(id: UUID(), identity: identity, registration: registration)
        let receipt = try await client.awaitRegistration(ticket)
        let digest = try registration.digest
        #expect(receipt.state == "registered" && receipt.registrationDigest == digest)
        var expected = try helperChanged(registration.scope, key: "challenge", text: UUID().uuidString)
        #expect(try await client.reconcile(expected).priorWorker == .stoppedAndFenced)
        expected.helperIdentity = .init(instanceID: UUID(), executableSHA256: identity.executableSHA256, packageLockSHA256: identity.packageLockSHA256)
        #expect(try await client.reconcile(expected).priorWorker == .unknown)
        await #expect(throws: ProvisioningHelperIPCFailure.ownership) { try await registry.registerPrepared(registration) }
        client.disconnect(); await serving.value
    }
    @Test(arguments: ["field", "owner", "schema", "mode", "digest", "nested"])
    func changedOrUnknownBootstrapRegistrationCannotEnterRegistry(kind: String) throws {
        let (identity, registration) = try reservedWorker()
        let credentials = try ProvisioningHelperCredentials(identity: identity, registration: registration)
        var root = try JSONSerialization.jsonObject(with: credentials.privateBootstrap()) as! [String: Any]
        var worker = root["registration"] as! [String: Any]
        if kind == "field" { worker["command"] = "start" }
        if kind == "mode" { worker["mode"] = "execute" }
        if kind == "digest" { worker["planDigest"] = "unknown" }
        if kind == "schema" { root["version"] = 1 }
        if kind == "owner" || kind == "nested" {
            var scope = worker["scope"] as! [String: Any], owner = scope["helperIdentity"] as! [String: Any]
            if kind == "owner" { owner["instanceID"] = UUID().uuidString } else { owner["path"] = "never-admitted" }
            scope["helperIdentity"] = owner; worker["scope"] = scope
        }
        root["registration"] = worker
        #expect(throws: Error.self) { _ = try ProvisioningHelperCredentials(privateBootstrap: JSONSerialization.data(withJSONObject: root)) }
    }
    @Test(arguments: ["owner", "digest"])
    func receiptMismatchPoisonsChannelInsteadOfAcceptingAnotherReservation(kind: String) async throws {
        let (identity, registration) = try reservedWorker()
        let credentials = try ProvisioningHelperCredentials(identity: identity, registration: registration)
        var fds = [Int32](repeating: -1, count: 2); #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let clientSocket = try ProvisioningHelperSocket(taking: fds[0]), serverSocket = try ProvisioningHelperSocket(taking: fds[1])
        let registry = try ProvisioningHelperOwnershipRegistry(identity: identity)
        let server = try ProvisioningHelperIPCServer(socket: serverSocket, credentials: credentials, registry: registry)
        let serving = Task { await server.serve() }
        let client = ProvisioningHelperIPCClient(socket: clientSocket, credentials: credentials)
        var changed = registration
        if kind == "digest" { changed = .init(scope: changed.scope, planDigest: String(repeating: "f", count: 64), inputDigest: changed.inputDigest, mode: changed.mode) }
        let owner = kind == "owner" ? ProvisioningHelperIdentity(instanceID: UUID(), executableSHA256: identity.executableSHA256, packageLockSHA256: identity.packageLockSHA256) : identity
        let ticket = ProvisioningHelperLaunchTicket(id: UUID(), identity: owner, registration: changed)
        await #expect(throws: ProvisioningHelperIPCFailure.authentication) { _ = try await client.awaitRegistration(ticket) }
        await #expect(throws: ProvisioningHelperIPCFailure.authentication) { _ = try await client.reconcile(registration.scope) }
        await serving.value
    }
}
