import Foundation
#if DEBUG
import DevVMProvisioningCore
@testable import OmarchyVMManagerCore

// Test-only executable; never staged in an app or called by a product entry point.
// It launches only the admitted ownership helper, with no VM/transport backend.
var fixtureStep = "arguments"
do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 3, ["normal", "policy", "tamper", "replace"].contains(args[2]) else { throw ProvisioningHelperIPCFailure.protocolViolation }
    let layout = ProvisioningPackageLayout(contents: URL(fileURLWithPath: args[0]))
    let root = URL(fileURLWithPath: args[1]); try PrivateFiles.directory(root)
    let launcher = try ProvisioningHelperLauncher(layout: layout, directory: root.appendingPathComponent("control"), policy: args[2] == "policy" ? .sameApplicationTeam : .adHocFixture)
    let target = try GuestBinding(vmID: UUID(), sessionID: UUID(), owner: "fixture", ownerUID: 1000, hostKeyDigest: String(repeating: "a", count: 64))
    let pin = String(repeating: "b", count: 64)
    let scope = ProvisioningRecoveryExpectation(challenge: UUID(), jobID: UUID(), vmID: target.vmID, sessionID: target.sessionID,
        payloadID: UUID(), workerToken: UUID(), engineDigest: pin, dependencyDigest: pin,
        bindingDigest: try ProvisioningCoordinator.bindingIdentity(target), reviewDigest: pin, checkpointDigest: pin)
    let registration = ProvisioningHelperWorkerRegistration(scope: scope, planDigest: pin, inputDigest: pin, mode: .apply)
    if args[2] == "policy" {
        do { _ = try await launcher.prepare(registration); throw ProvisioningJobFailure.invalidRequest }
        catch ProvisioningHelperIPCFailure.authentication { print("{\"policyRejected\":true}"); exit(0) }
    }
    fixtureStep = "prepare"
    let ticket = try await launcher.prepare(registration)
    fixtureStep = "journal"
    let journal = try ProvisioningJobJournal(directory: root.appendingPathComponent("journal")); _ = try journal.load()
    var row = ProvisioningJobRecord(jobID: scope.jobID, vmID: scope.vmID, sessionID: scope.sessionID, reviewDigest: scope.reviewDigest,
        planDigest: pin, inputDigest: pin, engineDigest: scope.engineDigest, dependencyDigest: scope.dependencyDigest, bindingDigest: scope.bindingDigest, mode: .apply)
    row.payloadID = scope.payloadID; row.workerToken = scope.workerToken; row.inputArchiveSHA256 = pin; row.cleanupCheckpointSHA256 = pin
    row.helperIdentity = ticket.identity; row.helperRegistrationDigest = try ticket.registration.digest; row.helperRegistered = false; row.cleanupRequired = true
    try journal.save([row])
    if args[2] == "tamper" || args[2] == "replace" {
        fixtureStep = args[2]
        let url = args[2] == "tamper" ? try BundledProvisioning.resourceRoot(layout).appendingPathComponent("catalogue.json") : layout.binaries.appendingPathComponent("OmarchyVMProvisioningHelper")
        let bytes = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if args[2] == "tamper" {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            defer { try? bytes.write(to: url); try? FileManager.default.setAttributes([.posixPermissions: attributes[.posixPermissions]!], ofItemAtPath: url.path) }
            try Data("{}".utf8).write(to: url)
            do { _ = try await launcher.launch(ticket); throw ProvisioningJobFailure.invalidRequest }
            catch { guard await launcher.phase(ticket) == .exited else { throw ProvisioningJobFailure.invalidRequest } }
        } else {
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: layout.binaries.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.binaries.path)
            let old = root.appendingPathComponent("original-helper")
            try FileManager.default.moveItem(at: url, to: old)
            defer {
                try? FileManager.default.removeItem(at: url); try? FileManager.default.moveItem(at: old, to: url)
                try? FileManager.default.setAttributes([.posixPermissions: directoryAttributes[.posixPermissions]!], ofItemAtPath: layout.binaries.path)
            }
            try bytes.write(to: url); try FileManager.default.setAttributes([.posixPermissions: attributes[.posixPermissions]!], ofItemAtPath: url.path)
            do { _ = try await launcher.launch(ticket); throw ProvisioningJobFailure.invalidRequest }
            catch { guard await launcher.phase(ticket) == .exited else { throw ProvisioningJobFailure.invalidRequest } }
        }
        print("{\"changedSourceRejected\":true,\"noChild\":true}"); exit(0)
    }
    fixtureStep = "launch"
    let receipt = try await launcher.launch(ticket)
    guard receipt.registrationDigest == row.helperRegistrationDigest, receipt.identity == row.helperIdentity else { throw ProvisioningJobFailure.invalidRequest }
    row.helperRegistered = true; row.sequence += 1; try journal.save([row])
    var expected = ticket.registration.scope; expected = .init(challenge: UUID(), jobID: expected.jobID, vmID: expected.vmID, sessionID: expected.sessionID,
        payloadID: expected.payloadID, workerToken: expected.workerToken, engineDigest: expected.engineDigest, dependencyDigest: expected.dependencyDigest,
        bindingDigest: expected.bindingDigest, reviewDigest: expected.reviewDigest, checkpointDigest: expected.checkpointDigest, helperIdentity: expected.helperIdentity)
    fixtureStep = "reconcile"
    guard try await launcher.reconcile(expected).priorWorker == .stoppedAndFenced else { throw ProvisioningJobFailure.invalidRequest }
    // A duplicate launch ticket must not spawn a replacement helper.
    do { _ = try await launcher.launch(ticket); throw ProvisioningJobFailure.invalidRequest }
    catch ProvisioningHelperIPCFailure.ownership {}
    fixtureStep = "exit"
    await launcher.abandon(ticket)
    let end = ContinuousClock.now + .seconds(4)
    while await launcher.phase(ticket) != .exited, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
    guard await launcher.phase(ticket) == .exited else { throw ProvisioningHelperIPCFailure.unavailable }
    guard try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("control/" + ticket.identity.instanceID.uuidString).path).isEmpty else { throw ProvisioningJobFailure.invalidRequest }
    print("{\"registered\":true,\"reconciled\":true,\"exited\":true,\"executionEnabled\":false}")
} catch {
    let code = (error as? ProvisioningHelperIPCFailure)?.rawValue ?? (error as? ProvisioningJobFailure)?.rawValue ?? "launch-fixture-failed"
    let result = try! JSONSerialization.data(withJSONObject: ["ok": false, "code": code, "step": fixtureStep], options: [.sortedKeys])
    print(String(decoding: result, as: UTF8.self)); exit(1)
}
#else
print("{\"ok\":false,\"code\":\"debug-fixture-only\"}")
exit(1)
#endif
