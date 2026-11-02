import DevVMProvisioningCore
import Foundation

/// One original registration, one activation, one shared sequencer. No viewer
/// owns the task; a fence is permanent even after completion or failed prepare.
actor ProvisioningHelperEngineWorker {
    let registration: ProvisioningHelperWorkerRegistration
    private let bodyAllowed: @Sendable () -> Bool
    private var activation: ProvisioningHelperActivation?
    private var task: Task<Void, Never>?
    private var driver: ProvisioningSequencer?
    private var context: ProvisioningHelperEngineContext?
    private var cancelled = false, fenced = false, retired = false
    private var phase = ProvisioningHelperWorkerPhase.preparing
    private var sequence: UInt64 = 1
    private var operation: GuestOperation?
    private var commandID: UUID?
    private var outcome: ProvisioningOutcome?
    private var failure: SequencingFailure?
    private var cleanupFailures: [SequencingFailure] = []
    private var cleanupRequired = true
    init(registration: ProvisioningHelperWorkerRegistration, bodyAllowed: @escaping @Sendable () -> Bool) {
        self.registration = registration; self.bodyAllowed = bodyAllowed
    }
    func activate(_ value: ProvisioningHelperActivation, factory: (any ProvisioningHelperEnginePreparing)?) throws -> ProvisioningHelperWorkerSnapshot {
        guard value.scope.sameWorker(as: registration.scope), value.registrationDigest == (try registration.digest) else { throw ProvisioningHelperDispatchDenial.ownership }
        if let existing = activation {
            guard existing == value else { throw ProvisioningHelperDispatchDenial.activationConflict }; return try snapshot(value)
        }
        guard !fenced else { throw ProvisioningHelperDispatchDenial.fenced }
        guard let factory else { throw ProvisioningHelperDispatchDenial.executionUnavailable }
        activation = value
        // Explicit actor hop: the task is retained before any context/body work.
        task = Task { await self.execute(factory) }
        return try snapshot(value)
    }
    func snapshot(_ expected: ProvisioningHelperActivation) throws -> ProvisioningHelperWorkerSnapshot {
        guard activation == expected else { throw ProvisioningHelperDispatchDenial.ownership }
        return .init(activationID: expected.activationID, activationDigest: try expected.digest, sequence: sequence,
            phase: phase, operation: operation, commandID: commandID, outcome: outcome, primaryFailure: failure, cleanupFailures: cleanupFailures, cleanupRequired: cleanupRequired)
    }
    func cancel(_ expected: ProvisioningHelperActivation) async throws -> ProvisioningHelperWorkerSnapshot {
        _ = try snapshot(expected); cancelled = true
        if outcome == nil { phase = .cancelling; bump() }
        await driver?.requestCancellation()
        return try snapshot(expected)
    }
    func fenceAndReconcile() async -> ProvisioningPriorWorkerState {
        fenced = true; cancelled = true; bump()
        await driver?.requestCancellation()
        await task?.value // Not a viewer task, and never cancelled to skip cleanup.
        retired = true
        let local = await context?.runner.fenceAndReconcile() ?? .stoppedAndFenced
        phase = .fenced; bump()
        return local
    }
    private func execute(_ factory: any ProvisioningHelperEnginePreparing) async {
        if fenced || cancelled || !bodyAllowed() { complete(.cancelled, failure: .cancelled, cleanup: [], required: false); return }
        do {
            let prepared = try await factory.prepare(registration)
            // Retain even a rejected context until its owned runner is fenced.
            context = prepared
            try await validate(prepared)
            guard !fenced, !cancelled, bodyAllowed() else {
                let local = await prepared.runner.fenceAndReconcile()
                complete(.cancelled, failure: .cancelled, cleanup: [], required: local != .stoppedAndFenced); return
            }
            let sequencer = ProvisioningSequencer(); driver = sequencer; phase = .running; bump()
            let adapter = HelperEngineAdapter(owner: self, underlying: prepared.adapter)
            guard let activation else { throw SequencingFailure.invalidRequest }
            let consent = ProvisioningApproval(reviewIdentity: prepared.approval.reviewIdentity,
                customTasksReviewed: prepared.approval.customTasksReviewed && activation.customTasksReviewed,
                persistentGrantAcknowledged: prepared.approval.persistentGrantAcknowledged && activation.persistentGrantAcknowledged,
                dockerRootAccessAcknowledged: prepared.approval.dockerRootAccessAcknowledged && activation.dockerRootAccessAcknowledged)
            let result = await sequencer.run(prepared.request, approval: consent,
                payloadID: registration.scope.payloadID, adapter: adapter)
            retired = true; phase = .finalizing; bump()
            let local = await prepared.runner.fenceAndReconcile()
            let risk = result.recovery != nil || local != .stoppedAndFenced
            complete(risk ? .cleanupRequired : result.outcome, failure: result.primaryFailure,
                cleanup: Array(result.cleanupFailures.prefix(32)), required: risk)
        } catch {
            retired = true
            _ = await context?.runner.fenceAndReconcile()
            // Preparation/validation failures cannot be replayed under this ID.
            complete(.cleanupRequired, failure: error as? SequencingFailure ?? .invalidRequest, cleanup: [], required: true)
        }
    }
    private func validate(_ value: ProvisioningHelperEngineContext) async throws {
        let request = value.request, scope = registration.scope
        guard request.jobID == scope.jobID, request.target.vmID == scope.vmID, request.target.sessionID == scope.sessionID,
              request.dependencyDigest == scope.dependencyDigest, request.reviewIdentity == scope.reviewDigest,
              value.approval.reviewIdentity == scope.reviewDigest, request.mode == registration.mode,
              request.plan.identity == registration.planDigest, request.plan.snapshot.identity == registration.inputDigest,
              try ProvisioningCoordinator.bindingIdentity(request.target) == scope.bindingDigest,
              try ProvisioningCoordinator.engineIdentity(request.plan) == scope.engineDigest,
              await value.runner.matches(scope) else { throw SequencingFailure.identityMismatch }
        try request.plan.verify(in: request.repository)
        try value.admitPackage()
        try await value.authority.revalidate(request.target, dependencyDigest: scope.dependencyDigest)
    }
    fileprivate func before(_ command: DevVMProvisioningCore.GuestCommand) async throws {
        guard !retired, let context,
              command.context.jobID == registration.scope.jobID, command.context.payloadID == registration.scope.payloadID,
              command.context.target == context.request.target, command.context.dependencyDigest == registration.scope.dependencyDigest,
              command.context.mode == registration.mode, command.mode == registration.mode,
              command.plan == nil || command.plan?.identity == registration.planDigest else { throw SequencingFailure.identityMismatch }
        let cleanup = command.plan == nil
        if !cleanup, cancelled || fenced || !bodyAllowed() { throw SequencingFailure.cancelled }
        if !cleanup { try context.admitPackage() }
        if cleanup, command.inputLeaseID != nil { throw SequencingFailure.protocolViolation }
        try await context.authority.revalidate(context.request.target, dependencyDigest: registration.scope.dependencyDigest)
        if !cleanup, cancelled || fenced || !bodyAllowed() { throw SequencingFailure.cancelled }
        operation = command.operation; commandID = command.id; bump()
    }
    fileprivate func after(_ command: DevVMProvisioningCore.GuestCommand) async throws {
        guard let context else { throw SequencingFailure.identityMismatch }
        try await context.authority.revalidate(context.request.target, dependencyDigest: registration.scope.dependencyDigest)
        if command.plan != nil, cancelled || fenced || !bodyAllowed() { throw SequencingFailure.cancelled }
    }
    private func complete(_ result: ProvisioningOutcome, failure: SequencingFailure?, cleanup: [SequencingFailure], required: Bool) {
        self.outcome = result; self.failure = failure; cleanupFailures = cleanup; cleanupRequired = required
        retired = true; phase = fenced ? .fenced : .completed; bump()
    }
    private func bump() { if sequence < UInt64(Int64.max) { sequence += 1 } }
}
private struct HelperEngineAdapter: ProvisioningGuestAdapter {
    let owner: ProvisioningHelperEngineWorker
    let underlying: any ProvisioningGuestAdapter
    func perform(_ command: DevVMProvisioningCore.GuestCommand) async throws -> DevVMProvisioningCore.GuestReply {
        try await owner.before(command)
        let reply = try await underlying.perform(command)
        try await owner.after(command)
        return reply
    }
    func interrupt(commandID: UUID, context: GuestJobContext) async { await underlying.interrupt(commandID: commandID, context: context) }
}
