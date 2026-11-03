import Foundation
#if DEBUG
import DevVMProvisioningCore
@testable import OmarchyVMManagerCore

// Test-only executable; never staged in an app or called by a product entry point.
// It launches only the admitted ownership helper, with no VM/transport backend.
var fixtureStep = "arguments"
do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.count == 2, args[0] == "--ownership-channel-fd", let descriptor = Int32(args[1]), let executable = Bundle.main.executableURL {
        let layout = ProvisioningPackageLayout(contents: executable.deletingLastPathComponent().deletingLastPathComponent())
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("fixture-inputs")
        try await ProvisioningHelperControl.serveInherited(descriptor: descriptor, layout: layout, engineFactory: DispatchFixtureEngineFactory(root: root, layout: layout), deliveredBackend: DispatchFixtureDeliveredBackend(layout: layout))
        exit(0)
    }
    guard args.count == 3, ["normal", "policy", "tamper", "replace", "dispatch", "dispatch-cancel", "dispatch-denied", "delivery", "delivery-cancel", "delivery-denied", "delivery-tamper"].contains(args[2]) else { throw ProvisioningHelperIPCFailure.protocolViolation }
    let layout = ProvisioningPackageLayout(contents: URL(fileURLWithPath: args[0]))
    let root = URL(fileURLWithPath: args[1]); try PrivateFiles.directory(root)
    let launcher = try ProvisioningHelperLauncher(layout: layout, directory: root.appendingPathComponent("control"), policy: args[2] == "policy" ? .sameApplicationTeam : .adHocFixture)
    let target = try GuestBinding(vmID: UUID(), sessionID: UUID(), owner: "fixture", ownerUID: 1000, hostKeyDigest: String(repeating: "a", count: 64))
    let pin = String(repeating: "b", count: 64)
    var scope = ProvisioningRecoveryExpectation(challenge: UUID(), jobID: UUID(), vmID: target.vmID, sessionID: target.sessionID,
        payloadID: UUID(), workerToken: UUID(), engineDigest: pin, dependencyDigest: pin,
        bindingDigest: try ProvisioningCoordinator.bindingIdentity(target), reviewDigest: pin, checkpointDigest: pin)
    var registration = ProvisioningHelperWorkerRegistration(scope: scope, planDigest: pin, inputDigest: pin, mode: .apply)
    var deliverySource: ProvisioningFrozenDeliverySource?
    if args[2].hasPrefix("dispatch") || args[2].hasPrefix("delivery") {
        let request = try DispatchFixtureBlueprint.request(root: root.appendingPathComponent("fixture-inputs"), scope: scope, mode: .apply, delivered: args[2].hasPrefix("delivery"))
        scope = .init(challenge: scope.challenge, jobID: scope.jobID, vmID: scope.vmID, sessionID: scope.sessionID, payloadID: scope.payloadID, workerToken: scope.workerToken,
            engineDigest: try ProvisioningCoordinator.engineIdentity(request.plan), dependencyDigest: scope.dependencyDigest,
            bindingDigest: scope.bindingDigest, reviewDigest: request.reviewIdentity, checkpointDigest: scope.checkpointDigest)
        registration = .init(scope: scope, planDigest: request.plan.identity, inputDigest: request.plan.snapshot.identity, mode: request.mode)
        if args[2].hasPrefix("delivery") {
            let delivery = try ProvisioningFrozenDelivery(request: request, approval: .init(reviewIdentity: request.reviewIdentity, persistentGrantAcknowledged: true), archive: request.plan.snapshot.privateArchive())
            registration.delivery = delivery.receipt
            try PrivateFiles.write(delivery.bytes, name: "fixture.delivery", in: root, exclusively: true)
            deliverySource = try ProvisioningFrozenDeliverySource(url: root.appendingPathComponent("fixture.delivery"), receipt: delivery.receipt)
        }
    }
    if args[2] == "policy" {
        do { _ = try await launcher.prepare(registration); throw ProvisioningJobFailure.invalidRequest }
        catch ProvisioningHelperIPCFailure.authentication { print("{\"policyRejected\":true}"); exit(0) }
    }
    fixtureStep = "prepare"
    let ticket: ProvisioningHelperLaunchTicket
    if let deliverySource { ticket = try await launcher.prepare(registration, delivery: deliverySource) }
    else { ticket = try await launcher.prepare(registration) }
    fixtureStep = "journal"
    let journal = try ProvisioningJobJournal(directory: root.appendingPathComponent("journal")); _ = try journal.load()
    var row = ProvisioningJobRecord(jobID: scope.jobID, vmID: scope.vmID, sessionID: scope.sessionID, reviewDigest: scope.reviewDigest,
        planDigest: registration.planDigest, inputDigest: registration.inputDigest, engineDigest: scope.engineDigest, dependencyDigest: scope.dependencyDigest, bindingDigest: scope.bindingDigest, mode: .apply)
    row.payloadID = scope.payloadID; row.workerToken = scope.workerToken; row.inputArchiveSHA256 = pin; row.cleanupCheckpointSHA256 = pin
    row.helperDelivery = registration.delivery
    if let delivery = registration.delivery { row.inputArchiveSHA256 = delivery.archiveSHA256 }
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
    if args[2] == "delivery-tamper" {
        try Data("changed".utf8).write(to: root.appendingPathComponent("fixture.delivery"))
        do { _ = try await launcher.launch(ticket); throw ProvisioningJobFailure.invalidRequest }
        catch ProvisioningJobFailure.artifactUnavailable {}
        await launcher.abandon(ticket)
        let end = ContinuousClock.now + .seconds(4)
        while await launcher.phase(ticket) != .exited, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        guard await launcher.phase(ticket) == .exited else { throw ProvisioningHelperIPCFailure.unavailable }
        print("{\"changedDeliveryRejected\":true,\"exited\":true}"); exit(0)
    }
    fixtureStep = "launch"
    let receipt = try await launcher.launch(ticket)
    guard receipt.registrationDigest == row.helperRegistrationDigest, receipt.identity == row.helperIdentity, receipt.deliveryDigest == registration.delivery?.sha256 else { throw ProvisioningJobFailure.invalidRequest }
    row.helperRegistered = true; row.sequence += 1; try journal.save([row])
    var expected = ticket.registration.scope; expected = .init(challenge: UUID(), jobID: expected.jobID, vmID: expected.vmID, sessionID: expected.sessionID,
        payloadID: expected.payloadID, workerToken: expected.workerToken, engineDigest: expected.engineDigest, dependencyDigest: expected.dependencyDigest,
        bindingDigest: expected.bindingDigest, reviewDigest: expected.reviewDigest, checkpointDigest: expected.checkpointDigest, helperIdentity: expected.helperIdentity)
    if args[2].hasPrefix("delivery") {
        // Remove the parent checkout before any activation. Child uses only its
        // validated private tree; this is disposable test metadata, never a VM.
        try FileManager.default.removeItem(at: root.appendingPathComponent("fixture-inputs"))
    }
    if args[2].hasPrefix("dispatch") || args[2].hasPrefix("delivery") {
        fixtureStep = "dispatch"
        let activation = ProvisioningHelperActivation(activationID: UUID(), registrationDigest: try ticket.registration.digest, scope: expected,
            customTasksReviewed: true, persistentGrantAcknowledged: true, dockerRootAccessAcknowledged: true)
        row.helperActivationID = activation.activationID; row.helperActivationDigest = try activation.digest
        row.state = .running; row.workerOutstanding = true; row.sequence += 1; try journal.save([row])
        if args[2] == "dispatch-denied" || args[2] == "delivery-denied" {
            do { _ = try await launcher.dispatch(.activate, activation: activation); throw ProvisioningJobFailure.invalidRequest }
            catch ProvisioningHelperDispatchDenial.executionUnavailable {}
        } else {
            var status = try await launcher.dispatch(.activate, activation: activation)
            _ = try await launcher.dispatch(.activate, activation: activation) // Idempotent receipt, never a second task.
            var cancellationSent = false
            let deadline = ContinuousClock.now + .seconds(6)
            while !status.terminal, ContinuousClock.now < deadline {
                if args[2].hasSuffix("-cancel"), status.operation == .configureFeatures, !cancellationSent {
                    cancellationSent = true; status = try await launcher.dispatch(.cancel, activation: activation)
                } else {
                    try await Task.sleep(for: .milliseconds(20)); status = try await launcher.dispatch(.status, activation: activation)
                }
            }
            guard status.terminal, !status.cleanupRequired,
                  status.outcome == (args[2].hasSuffix("-cancel") ? .cancelled : .applied) else { throw ProvisioningJobFailure.invalidRequest }
        }
    }
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
    let controlEntries = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("control/" + ticket.identity.instanceID.uuidString).path)
    guard args[2].hasPrefix("dispatch") || args[2].hasPrefix("delivery") || controlEntries.isEmpty else { throw ProvisioningJobFailure.invalidRequest }
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
