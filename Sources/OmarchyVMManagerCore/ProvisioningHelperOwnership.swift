import DevVMProvisioningCore
import Foundation

/// The backend must register before spawn and honor task cancellation before
/// launch. A true cleanup receipt covers only its exact retained invocation.
protocol ProvisioningLocalCleanupReconciling: Sendable {
    func reconcileLocalCleanup(invocationID: UUID) async -> Bool
}
extension LocalProvisioningProcessRunner: ProvisioningLocalCleanupReconciling {}

/// One original worker's permanent launch gate, owning every delegated local
/// process task. Local exit proves no guest cleanup; the sequencer still does that.
actor ProvisioningFencedProcessRunner: ProvisioningProcessRunner {
    private let backend: any ProvisioningProcessRunner
    private let scope: ProvisioningRecoveryExpectation
    private let target: GuestBinding
    private let mode: ProvisioningMode
    private var fenced = false
    private var active: [UUID: Task<ProvisioningProcessResult, Never>] = [:]
    private var uncertain = Set<UUID>()
    private var seen = Set<UUID>()
    init(backend: any ProvisioningProcessRunner, scope: ProvisioningRecoveryExpectation, target: GuestBinding, mode: ProvisioningMode) throws {
        try scope.validate()
        guard target.vmID == scope.vmID, target.sessionID == scope.sessionID,
              try ProvisioningCoordinator.bindingIdentity(target) == scope.bindingDigest else { throw ProvisioningHelperIPCFailure.ownership }
        self.backend = backend; self.scope = scope; self.target = target; self.mode = mode
    }
    func matches(_ expectation: ProvisioningRecoveryExpectation) -> Bool { scope.sameWorker(as: expectation) }
    func run(_ invocation: ProvisioningProcessInvocation) async -> ProvisioningProcessResult {
        guard !fenced, active.isEmpty, uncertain.isEmpty, seen.count < 4096, !seen.contains(invocation.id),
              invocation.context.jobID == scope.jobID, invocation.context.payloadID == scope.payloadID,
              invocation.context.target == target, invocation.context.dependencyDigest == scope.dependencyDigest,
              invocation.context.mode == mode else { return .init(invocationID: invocation.id, termination: .notStarted) }
        seen.insert(invocation.id)
        // The explicit actor hop cannot run until its ownership entry is stored.
        let task = Task { await self.launch(invocation) }
        active[invocation.id] = task
        let result = await task.value
        settle(result, expected: invocation.id)
        return result.invocationID == invocation.id ? result : .init(invocationID: invocation.id, termination: .cleanupUnconfirmed)
    }
    private func launch(_ invocation: ProvisioningProcessInvocation) async -> ProvisioningProcessResult {
        guard !fenced, !Task.isCancelled else { return .init(invocationID: invocation.id, termination: .notStarted) }
        return await backend.run(invocation)
    }
    func interrupt(invocationID: UUID) async {
        guard let task = active[invocationID] else { return }
        task.cancel(); await backend.interrupt(invocationID: invocationID)
    }
    func fenceAndReconcile() async -> ProvisioningPriorWorkerState {
        fenced = true // Permanent, before any await, including a queued launch.
        let pending = active
        for (id, task) in pending { task.cancel(); await backend.interrupt(invocationID: id) }
        for (id, task) in pending { settle(await task.value, expected: id) }
        if let reconciler = backend as? any ProvisioningLocalCleanupReconciling {
            for id in uncertain {
                if await reconciler.reconcileLocalCleanup(invocationID: id) { uncertain.remove(id) }
            }
        }
        return active.isEmpty && uncertain.isEmpty ? .stoppedAndFenced : .unknown
    }
    private func settle(_ result: ProvisioningProcessResult, expected id: UUID) {
        // A late second observer cannot erase uncertainty installed by the first.
        guard active.removeValue(forKey: id) != nil else { return }
        guard result.invocationID == id else { uncertain.insert(id); return }
        switch result.termination {
        case .exited, .notStarted: break
        case .cleanupUnconfirmed: uncertain.insert(id)
        }
    }
}

/// Records come only from the trusted local job owner, never from IPC or disk.
/// An empty/new helper cannot infer that a prior helper's worker has stopped.
actor ProvisioningHelperOwnershipRegistry {
    let identity: ProvisioningHelperIdentity
    private struct Record {
        let scope: ProvisioningRecoveryExpectation
        let runner: ProvisioningFencedProcessRunner
        var reconciliation: Attempt?
        var proven = false
    }
    private struct Attempt: Sendable { let id = UUID(); let task: Task<ProvisioningPriorWorkerState, Never> }
    private var records: [UUID: Record] = [:]
    private var disconnected = false
    init(identity: ProvisioningHelperIdentity) throws { try identity.validate(); self.identity = identity }
    func register(_ scope: ProvisioningRecoveryExpectation, runner: ProvisioningFencedProcessRunner) async throws {
        try scope.validate()
        guard !disconnected, records.count < 128, records[scope.workerToken] == nil, await runner.matches(scope) else { throw ProvisioningHelperIPCFailure.ownership }
        // Recheck after the runner actor hop; disconnect/duplicate may have won.
        guard !disconnected, records.count < 128, records[scope.workerToken] == nil else { throw ProvisioningHelperIPCFailure.ownership }
        records[scope.workerToken] = Record(scope: scope, runner: runner)
    }
    func reconcile(_ scope: ProvisioningRecoveryExpectation) async -> ProvisioningPriorWorkerState {
        guard var record = records[scope.workerToken], record.scope.sameWorker(as: scope) else { return .unknown }
        if record.proven { return .stoppedAndFenced }
        let attempt: Attempt
        if let current = record.reconciliation { attempt = current }
        else {
            let runner = record.runner
            attempt = Attempt(task: Task.detached { await runner.fenceAndReconcile() })
            record.reconciliation = attempt; records[scope.workerToken] = record
        }
        let state = await attempt.task.value
        if records[scope.workerToken]?.reconciliation?.id == attempt.id {
            records[scope.workerToken]?.proven = state == .stoppedAndFenced
            records[scope.workerToken]?.reconciliation = nil
        }
        return state
    }
    func managerDisconnected() {
        guard !disconnected else { return }
        disconnected = true
        for (token, var record) in records where !record.proven && record.reconciliation == nil {
            let runner = record.runner
            record.reconciliation = Attempt(task: Task.detached { await runner.fenceAndReconcile() })
            records[token] = record
        }
    }
}
