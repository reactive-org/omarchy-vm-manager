import Darwin
@testable import DevVMProvisioningCore
import Foundation
import Testing
@testable import OmarchyVMManagerCore

/// Only test code observes pins to simulate a reviewed approval. Product code
/// must use the ORIGINAL approved identity values, never recapture replacements.
private func fixtureApprovedRoot(_ profile: VMProfile, support: URL, channel: AppChannel = .current) throws -> ProvisioningApprovedDisposableRoot {
    let storage = ManagerStorage(applicationSupport: support, channel: channel), root = storage.root(for: profile)
    try PrivateFiles.directory(storage.directory, create: true); try PrivateFiles.directory(storage.vms, create: true)
    try PrivateFiles.directory(root, create: true)
    let marker = root.appendingPathComponent(".omarchy-vm-manager.json")
    if !PrivateFiles.exists(marker) {
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "id": profile.id.uuidString]), name: marker.lastPathComponent, in: root, exclusively: true)
        try PrivateFiles.write(Data("omarchy-qemu-storage-root-v1\n".utf8), name: ".omarchy-qemu-storage", in: root, exclusively: true)
    }
    var info = stat(); guard lstat(root.path, &info) == 0 else { throw ProvisioningJobFailure.targetChanged }
    return .init(vmID: profile.id, root: root, device: Int64(info.st_dev), inode: UInt64(info.st_ino), markerSHA256: KitVerifier.sha256(try PrivateFiles.read(marker)))
}
private func disposableFixtureAdmission(_ profile: VMProfile, _ support: URL) throws -> ProvisioningExecutionAdmission {
    .disposable(try .init(approvalID: UUID(), roots: [fixtureApprovedRoot(profile, support: support)]))
}
private func unrelatedFixtureAdmission(_ profile: VMProfile, _ support: URL) throws -> ProvisioningExecutionAdmission {
    try disposableFixtureAdmission(VMProfile(id: UUID(), name: "Unrelated synthetic disposable"), support)
}
private final class DisposableFixture: Sendable {
    let support: URL, profile: VMProfile, approved: ProvisioningApprovedDisposableRoot, admission: ProvisioningDisposableAdmission
    var root: URL { approved.root }
    init(id: UUID = UUID()) throws {
        support = URL(fileURLWithPath: "/private/tmp/disposable-admission-" + UUID().uuidString)
        try PrivateFiles.directory(support, create: true)
        profile = VMProfile(id: id, name: "Synthetic disposable approval")
        approved = try fixtureApprovedRoot(profile, support: support)
        admission = try .init(approvalID: UUID(), roots: [approved])
    }
    deinit { try? FileManager.default.removeItem(at: support) } // Synthetic files only; no disk image/runtime.
}

@Suite("Milestone 6 disposable admission — fake runtimes/local fixtures") struct ProvisioningDisposableAdmissionTests {
    @Test func compiledChannelPolicyAndExactPrivateApprovalStayIndependent() throws {
        let f = try DisposableFixture()
        try f.admission.verify(vmID: f.profile.id, root: f.root)
        #expect(ProvisioningProductExecution.enabled == (AppChannel.current == .development))
        #expect(ProvisioningProductExecution.disposableApproval == nil)
        if AppChannel.current == .development {
            try ProvisioningProductExecution.admission(applicationSupport: f.support).verify(vmID: f.profile.id, root: f.root)
        } else {
            #expect(throws: ProvisioningServiceFailure.disabled) { try ProvisioningProductExecution.admission.verify(vmID: f.profile.id, root: f.root) }
        }
        #expect(throws: Error.self) { try f.admission.verify(vmID: UUID(), root: f.root) }
        #expect(throws: Error.self) { try f.admission.verify(vmID: f.profile.id, root: f.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)) }
        #expect(!String(reflecting: f.admission).contains(f.root.path))
        #expect(!String(reflecting: f.admission).contains(f.profile.id.uuidString))
    }
    @Test(arguments: ["empty", "duplicate", "device", "inode", "hash", "retained", "foreign-root", "other-channel"])
    func invalidApprovalRecordsCannotEnableAnything(kind: String) throws {
        let f = try DisposableFixture(), a = f.approved
        var entries = [a]
        if kind == "empty" { entries = [] }
        if kind == "duplicate" { entries = [a, a] }
        if kind == "device" { entries = [.init(vmID: a.vmID, root: a.root, device: a.device + 1, inode: a.inode, markerSHA256: a.markerSHA256)] }
        if kind == "inode" { entries = [.init(vmID: a.vmID, root: a.root, device: a.device, inode: a.inode + 1, markerSHA256: a.markerSHA256)] }
        if kind == "hash" { entries = [.init(vmID: a.vmID, root: a.root, device: a.device, inode: a.inode, markerSHA256: String(repeating: "0", count: 64))] }
        if kind == "retained" { entries = [.init(vmID: POCProfiles.ids.first!, root: a.root, device: a.device, inode: a.inode, markerSHA256: a.markerSHA256)] }
        if kind == "foreign-root" { entries = [.init(vmID: a.vmID, root: f.support, device: a.device, inode: a.inode, markerSHA256: a.markerSHA256)] }
        if kind == "other-channel" {
            entries = [try fixtureApprovedRoot(f.profile, support: f.support, channel: AppChannel.current == .stable ? .development : .stable)]
        }
        #expect(throws: Error.self) { _ = try ProvisioningDisposableAdmission(approvalID: UUID(), roots: entries) }
    }
    @Test(arguments: ["replacement", "symlink", "ancestor-symlink", "mode", "parent-mode", "marker", "storage-marker", "marker-link"])
    func changedApprovedStorageIsRefusedWithoutRecapturing(kind: String) throws {
        let f = try DisposableFixture()
        switch kind {
        case "replacement", "symlink":
            let old = f.root.deletingLastPathComponent().appendingPathComponent("old-fixture")
            try FileManager.default.moveItem(at: f.root, to: old)
            if kind == "symlink" { try FileManager.default.createSymbolicLink(at: f.root, withDestinationURL: old) }
            else {
                try PrivateFiles.directory(f.root, create: true)
                for name in [".omarchy-vm-manager.json", ".omarchy-qemu-storage"] { try FileManager.default.copyItem(at: old.appendingPathComponent(name), to: f.root.appendingPathComponent(name)) }
            }
        case "ancestor-symlink":
            let parent = f.root.deletingLastPathComponent(), old = parent.deletingLastPathComponent().appendingPathComponent("old-VMs")
            try FileManager.default.moveItem(at: parent, to: old); try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: old)
        case "mode": chmod(f.root.path, 0o755)
        case "parent-mode": chmod(f.root.deletingLastPathComponent().path, 0o755)
        case "marker": try Data("{}".utf8).write(to: f.root.appendingPathComponent(".omarchy-vm-manager.json"))
        case "storage-marker": try Data("different".utf8).write(to: f.root.appendingPathComponent(".omarchy-qemu-storage"))
        default: #expect(link(f.root.appendingPathComponent(".omarchy-vm-manager.json").path, f.root.appendingPathComponent("linked-marker").path) == 0)
        }
        #expect(throws: Error.self) { try f.admission.verify(vmID: f.profile.id, root: f.root) }
    }
    @Test func managerRejectsAnUnlistedGuestBeforeDependencyInspectionAndHelperLaunch() async throws {
        let f = try await WorkflowFixture(admission: unrelatedFixtureAdmission)
        await #expect(throws: Error.self) { _ = try await f.preview() }
        #expect(await f.dependencies.inspections == 0); #expect(await f.launcher.launches == 0)
        await #expect(throws: Error.self) { try await f.manager.start(UUID()) }
        #expect(f.runtime.startRequests.count == 1 && f.runtime.startedHandles[0].shutdownCount == 0)
        await f.close()
    }
    @Test func approvedManagerAndHelperCompleteWithFakeRunnerOnly() async throws {
        let f = try await WorkflowFixture(admission: disposableFixtureAdmission)
        let expected = ManagerStorage(applicationSupport: f.root).root(for: f.profile)
        #expect(ManagerStorage(applicationSupport: f.root).matchesRoot(f.runtime.startRequests[0].storageRoot, profile: f.profile))
        let policy = await f.service.environment.executionAdmission
        try policy.verify(vmID: f.profile.id, root: expected)
        _ = try await f.manager.provisioningSSHAdmission(f.target)
        let id = try await f.apply(), runner = try #require(await f.launcher.runner(id))
        #expect(await f.service.status(id)?.stage == .succeeded)
        #expect(await runner.invocations.contains { $0.purpose == .features })
        #expect(f.runtime.startRequests.count == 1)
        await f.close()
    }
    @Test func helperIndependentlyRejectsAnUnlistedGuestDespiteManagerApproval() async throws {
        let f = try await WorkflowFixture(admission: disposableFixtureAdmission, helperAdmission: unrelatedFixtureAdmission)
        let id = try await f.apply(), runner = try #require(await f.launcher.runner(id))
        #expect(await f.service.status(id)?.stage != .succeeded)
        #expect(await runner.invocations.isEmpty && f.provider.builds == 0)
        await f.close()
    }
    @Test func helperRechecksApprovalAfterManagerRPCBeforeStartingNextInvocation() async throws {
        // A permissive TEST manager deliberately allows the response. Only the
        // independently installed helper approval must refuse the changed marker.
        let f = try await WorkflowFixture(helperAdmission: disposableFixtureAdmission)
        let marker = ManagerStorage(applicationSupport: f.root).root(for: f.profile).appendingPathComponent(".omarchy-vm-manager.json")
        await f.launcher.interceptFeatures { try? Data("{}".utf8).write(to: marker) }
        let id = try await f.apply(), runner = try #require(await f.launcher.runner(id))
        #expect(await runner.invocations.contains { $0.purpose == .identity })
        #expect(await runner.invocations.allSatisfy { $0.purpose != .features })
        #expect(await f.service.status(id)?.cleanupRequired == true)
        await f.close()
    }
    @Test func scopeChangeBeforeRestartCannotStopOrLaunchAnyGuest() async throws {
        let f = try await WorkflowFixture(docker: true, admission: disposableFixtureAdmission)
        let id = try await f.apply(), review = try await f.service.restartReview(id)
        let marker = ManagerStorage(applicationSupport: f.root).root(for: f.profile).appendingPathComponent(".omarchy-vm-manager.json")
        try Data("{}".utf8).write(to: marker)
        await #expect(throws: Error.self) { _ = try await f.service.approveRestart(review, identity: review.identity) }
        #expect(f.runtime.startRequests.count == 1 && f.runtime.startedHandles[0].shutdownCount == 0)
        await f.close()
    }
    @Test func stoppedApprovedRootIsRecheckedBeforeReplacementStart() async throws {
        let f = try await WorkflowFixture(docker: true, admission: disposableFixtureAdmission)
        let id = try await f.apply(), review = try await f.service.restartReview(id)
        try await f.service.approveRestart(review, identity: review.identity, timeout: .seconds(2))
        #expect(await eventually { f.runtime.startedHandles[0].shutdownCount == 1 })
        let marker = ManagerStorage(applicationSupport: f.root).root(for: f.profile).appendingPathComponent(".omarchy-vm-manager.json")
        try Data("{}".utf8).write(to: marker)
        f.runtime.startedHandles[0].emit(.exited(status: 0))
        _ = try await f.service.wait(id)
        #expect(f.runtime.startRequests.count == 1)
        await f.close()
    }
    @Test func identicalUUIDInAnotherManagerNamespaceDoesNotMatchTheCurrentSession() async throws {
        let f = try await WorkflowFixture(admission: { profile, support in
            let other = support.appendingPathComponent("other-manager-support")
            try PrivateFiles.directory(other, create: true)
            return try disposableFixtureAdmission(profile, other)
        })
        await #expect(throws: Error.self) { _ = try await f.preview() }
        #expect(await f.dependencies.inspections == 0); #expect(await f.launcher.launches == 0)
        await f.close()
    }
    @Test func recoveryCannotConstructOrInvokeAnAdapterOutsideApprovedStorage() async throws {
        let f = try await WorkflowFixture(admission: disposableFixtureAdmission), prepared = try await f.preview()
        let authority = ProvisioningAdmittedSessionAuthority(manager: f.manager)
        try await authority.admit(prepared.transport)
        let wrong = try unrelatedFixtureAdmission(f.profile, f.root), provider = f.provider
        #expect(throws: Error.self) {
            _ = try ProvisioningOperationalBackends.recovery(admission: prepared.transport, authority: authority, admitPackage: {},
                makeRunner: { provider.makeAdmittedRunner() }, executionAdmission: wrong)
        }
        #expect(provider.builds == 0)
        let policy = await f.service.environment.executionAdmission
        let adapter = try ProvisioningOperationalBackends.recovery(admission: prepared.transport, authority: authority, admitPackage: {},
            makeRunner: { provider.makeAdmittedRunner() }, executionAdmission: policy)
        let context = GuestJobContext(jobID: prepared.request.jobID, payloadID: UUID(), target: f.target, dependencyDigest: prepared.transport.dependencyDigest, mode: .apply)
        _ = try await adapter.perform(.init(id: UUID(), context: context, operation: .verifyIdentity, mode: .apply, inputLeaseID: nil, timeoutSeconds: 10, plan: nil, tasks: [], conflictPolicy: .fail))
        let count = await provider.runner.invocations.count
        #expect(count == 1)
        try Data("{}".utf8).write(to: ManagerStorage(applicationSupport: f.root).root(for: f.profile).appendingPathComponent(".omarchy-vm-manager.json"))
        await #expect(throws: Error.self) {
            _ = try await adapter.perform(.init(id: UUID(), context: context, operation: .quiesceOwnedWork, mode: .apply, inputLeaseID: nil, timeoutSeconds: 10, plan: nil, tasks: [], conflictPolicy: .fail))
        }
        #expect(await provider.runner.invocations.count == count)
        await f.close()
    }
    @Test func terminalApprovalLossRevokesInputButRetainsReadOnlyOutput() async throws {
        let t = try TerminalFixture(), f = try DisposableFixture(id: t.request.target.vmID)
        let hub = try ProvisioningTerminalHub(terminal: try ProvisioningTerminal(), request: t.request, admitInput: { try f.admission.verify(vmID: f.profile.id, root: f.root) })
        let attached = await hub.handle(t.packet(.attach)), viewer = try #require(attached.attachmentID)
        let claim = await hub.handle(t.packet(.claim, id: viewer, rows: 24, columns: 80)), token = try #require(claim.ownershipID)
        let marker = f.root.appendingPathComponent(".omarchy-vm-manager.json"), original = try PrivateFiles.read(marker)
        try Data("{}".utf8).write(to: marker)
        let other = try #require(await hub.handle(t.packet(.attach)).attachmentID)
        #expect(await hub.handle(t.packet(.claim, id: other, rows: 24, columns: 80)).denial == .unavailable)
        #expect(await hub.handle(t.packet(.read, id: viewer)).page?.ownsInput == false)
        let refused = await hub.handle(t.packet(.resize, id: viewer, token: token, invocation: UUID(), sequence: 1, rows: 24, columns: 80))
        #expect(refused.denial == .unavailable)
        try original.write(to: marker)
        let stale = await hub.handle(t.packet(.input, id: viewer, token: token, invocation: UUID(), sequence: 1, bytes: Data("synthetic".utf8)))
        #expect(stale.denial == .ownership)
        #expect(await hub.handle(t.packet(.read, id: viewer)).denial == nil)
    }
    @Test func compiledProvisioningExecutionPolicy() throws {
        #expect(ProvisioningProductExecution.enabled == (AppChannel.current == .development))
        #expect(BundledProvisioning.executionEnabled == (AppChannel.current == .development))
        #expect(ProvisioningProductExecution.disposableApproval == nil)
        let missing = URL(fileURLWithPath: "/private/tmp/missing-development-policy-" + UUID().uuidString)
        _ = ProvisioningProductExecution.admission(applicationSupport: missing)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
    @Test(arguments: ["stable-root", "wrong-id", "marker", "storage-marker", "mode", "symlink", "retained", "foreign-base", "duplicate-marker"])
    func normalDevAdmissionRejectsUnownedOrDamagedRoots(kind: String) throws {
        let f = try DisposableFixture()
        let policy = ProvisioningDevelopmentAdmission(applicationSupport: f.support)
        #expect(!String(reflecting: policy).contains(f.support.path))
        guard AppChannel.current == .development else {
            #expect(throws: ProvisioningServiceFailure.disabled) { try policy.verify(vmID: f.profile.id, root: f.root) }
            return
        }
        try policy.verify(vmID: f.profile.id, root: f.root)
        var root = f.root, id = f.profile.id
        if kind == "stable-root" { root = try fixtureApprovedRoot(f.profile, support: f.support, channel: .stable).root }
        if kind == "wrong-id" { id = UUID() }
        if kind == "marker" { try Data("{}".utf8).write(to: root.appendingPathComponent(".omarchy-vm-manager.json")) }
        if kind == "duplicate-marker" { try Data(("{\"schemaVersion\":1,\"schemaVersion\":1,\"id\":\"" + id.uuidString + "\"}").utf8).write(to: root.appendingPathComponent(".omarchy-vm-manager.json")) }
        if kind == "storage-marker" { try Data("foreign".utf8).write(to: root.appendingPathComponent(".omarchy-qemu-storage")) }
        if kind == "mode" { #expect(chmod(root.path, 0o755) == 0) }
        if kind == "symlink" {
            let held = root.appendingPathExtension("held")
            try FileManager.default.moveItem(at: root, to: held)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: held)
        }
        if kind == "retained" { id = POCProfiles.ids.first! }
        if kind == "foreign-base" {
            #expect(throws: Error.self) { try ProvisioningDevelopmentAdmission(applicationSupport: f.support.appendingPathComponent("other")).verify(vmID: id, root: root) }
        } else { #expect(throws: Error.self) { try policy.verify(vmID: id, root: root) } }
    }
    @Test func normalDevPolicyRunsOnlyReviewedFakeWorkAndHelperChecksItsOwnRoot() async throws {
        guard AppChannel.current == .development else { return }
        let policy: @Sendable (VMProfile, URL) throws -> ProvisioningExecutionAdmission = { profile, support in
            _ = try fixtureApprovedRoot(profile, support: support)
            return .development(.init(applicationSupport: support))
        }
        let f = try await WorkflowFixture(admission: policy)
        let id = try await f.apply(), runner = try #require(await f.launcher.runner(id))
        #expect(await f.service.status(id)?.stage == .succeeded)
        #expect(await runner.invocations.contains { $0.purpose == .features })
        #expect(await f.service.status(id)?.cleanupRequired == false)
        await f.close()
        let wrong = try await WorkflowFixture(admission: policy, helperAdmission: { _, support in .development(.init(applicationSupport: support.appendingPathComponent("foreign"))) })
        let rejected = try await wrong.apply(), unused = try #require(await wrong.launcher.runner(rejected))
        #expect(await wrong.service.status(rejected)?.stage != .succeeded)
        #expect(await unused.invocations.isEmpty && wrong.provider.builds == 0)
        await wrong.close()
    }

}
