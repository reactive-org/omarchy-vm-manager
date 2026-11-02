import Foundation

/// Single-use adapter driver. This owns sequencing only, never VM lifecycle or
/// a concrete transport. Manager admission/journaling/terminal ownership follow
/// in later milestones. Production CLI execution remains unavailable.
public actor ProvisioningSequencer {
    public private(set) var phase: ProvisioningPhase = .idle
    private var used = false
    private var cancelled = false
    private var cleaning = false
    private var unsafeIdentity = false
    private var adapter: (any ProvisioningGuestAdapter)?
    private var active: GuestCommand?
    private var context: GuestJobContext?
    private var request: ProvisioningRequest?
    private var grantRisk = false
    private var payloadRisk = false
    private var workRisk = false
    private var primary: SequencingFailure?
    private var cleanupFailures: [SequencingFailure] = []
    private var events: [SequencingEvent] = []

    public init() {}

    /// Interrupt only the exact local command; a separate remote quiescence
    /// proof is still required. Cancellation never interrupts cleanup itself.
    public func requestCancellation() async {
        cancelled = true
        if !cleaning, let active, let adapter {
            await adapter.interrupt(commandID: active.id, context: active.context)
        }
    }

    public func run(_ request: ProvisioningRequest, approval: ProvisioningApproval,
                    adapter: any ProvisioningGuestAdapter) async -> SequencingResult {
        guard !used else { return rejection(.alreadyUsed) }
        used = true; self.request = request; self.adapter = adapter
        context = GuestJobContext(jobID: request.jobID, payloadID: UUID(), target: request.target,
                                  dependencyDigest: request.dependencyDigest, mode: request.mode)
        defer { self.adapter = nil; active = nil }
        return await withTaskCancellationHandler {
            await execute(request, approval: approval)
        } onCancel: {
            Task { await self.requestCancellation() }
        }
    }

    /// Cleanup only: no stage, grant, apply, check, restart or input prompt.
    /// A new driver is required; this does not silently retry an earlier setup.
    public func recover(_ ticket: CleanupTicket, adapter: any ProvisioningGuestAdapter) async -> SequencingResult {
        guard !used else { return rejection(.alreadyUsed) }
        used = true; cleaning = true; self.adapter = adapter; context = ticket.context
        grantRisk = ticket.grantMayBeActive; payloadRisk = ticket.payloadMayExist; workRisk = ticket.workMayBeActive
        defer { self.adapter = nil; active = nil }
        // Recovery must survive cancellation of its viewer/calling task too.
        await Task.detached { await self.cleanup(verifyOwner: false) }.value
        transition(.finished)
        return result(pending ? .cleanupRequired : .cleanupConfirmed)
    }

    private func execute(_ request: ProvisioningRequest, approval: ProvisioningApproval) async -> SequencingResult {
        transition(.validating)
        do {
            try checkpoint()
            guard approval.reviewIdentity == request.reviewIdentity else { throw SequencingFailure.approvalRequired }
            guard request.selectedTasks.isEmpty || approval.customTasksReviewed else { throw SequencingFailure.taskTrustRequired }
            if request.mode == .apply {
                guard approval.persistentGrantAcknowledged else { throw SequencingFailure.authorizationConsentRequired }
                guard !request.dockerOptIn || approval.dockerRootAccessAcknowledged else { throw SequencingFailure.dockerConsentRequired }
                guard request.inputLeaseID != nil else {
                    transition(.awaitingAuthorization); throw SequencingFailure.authorizationRequired
                }
            }
            try verifyPlan()
            transition(.staging)
            try await checked(.stagePayload)
            if request.mode == .apply {
                transition(.authorizing)
                try await checked(.resetGrant)
                try await checked(.clearAuthenticationCache)
                try await checked(.requestPersistentGrant)
                try await checked(.verifyGrantActive)
                transition(.applying)
                if !(request.plan.document.object?["vm"]?.object?["packages"]?.array ?? []).isEmpty {
                    try await checked(.installManifestPackages)
                }
            } else { transition(.checking) }
            if !(request.plan.document.object?["features"]?.object?["features"]?.array ?? []).isEmpty {
                try await checked(.configureFeatures)
            }
            if request.dockerOptIn { try await checked(.configureDockerOwnerAccess) }
            try await checked(.configureRepository)
            try checkpoint()
        } catch { primary = failure(error) }

        cleaning = true
        // This is an independent cancellation scope. Adapter deadlines must be
        // enforced by the concrete transport, including waiting for local exit.
        await Task.detached { await self.cleanup(verifyOwner: self.primary == nil && request.dockerOptIn) }.value
        if primary == nil {
            do { try checkpoint(); try verifyPlan() } catch { primary = failure(error) }
        }
        transition(.finished)
        if pending { return result(.cleanupRequired) }
        if let primary {
            switch primary {
            case .cancelled: return result(.cancelled)
            case .timedOut: return result(.timedOut)
            case .authorizationRequired: return result(.authorizationRequired)
            case .invalidRequest, .approvalRequired, .taskTrustRequired, .authorizationConsentRequired, .dockerConsentRequired:
                return result(.rejected)
            default: return result(.failed)
            }
        }
        return result(request.mode == .check ? .checked : (request.dockerOptIn ? .appliedRestartRequired : .applied))
    }

    private func cleanup(verifyOwner: Bool) async {
        guard pending else { return }
        if unsafeIdentity {
            cleanupFailures.append(primary ?? .identityMismatch)
            return
        }
        if workRisk { await quiesce() }
        if grantRisk {
            transition(.revoking)
            _ = await cleanupStep(.revokeGrant)
            _ = await cleanupStep(.clearAuthenticationCache)
            // An observed proof can reconcile a lost revoke/cache-clear reply.
            // If owned work is still active it could regrant: keep that risk.
            if await cleanupStep(.verifyGrantInactive), !workRisk { grantRisk = false }
        }
        if verifyOwner, !cancelled, !grantRisk, !workRisk, !unsafeIdentity {
            transition(.verifyingOwnerAccess)
            do { try await checked(.verifyOwnerDockerAccess, cleanup: true) }
            catch { primary = failure(error) }
            // A local check's return/exit is not a remote descendant proof.
            if workRisk { await quiesce() }
        }
        if payloadRisk, !workRisk, !unsafeIdentity {
            transition(.removingPayload)
            if await cleanupStep(.removePayload) { payloadRisk = false }
        }
    }

    private func quiesce() async {
        transition(.quiescing)
        if await cleanupStep(.quiesceOwnedWork) { workRisk = false }
    }
    private func cleanupStep(_ operation: GuestOperation) async -> Bool {
        do { try await checked(operation, cleanup: true); return true }
        catch { cleanupFailures.append(failure(error)); return false }
    }
    private func checked(_ operation: GuestOperation, cleanup: Bool = false) async throws {
        guard !unsafeIdentity else { throw SequencingFailure.identityMismatch }
        if !cleanup { try checkpoint() }
        try await call(.verifyIdentity, cleanup: cleanup)
        if !cleanup { try checkpoint(); try verifyPlan() }
        // Coverage starts before invoking anything that may take effect even if
        // its acknowledgement is lost (including initial staging/reset).
        switch operation {
        case .stagePayload: payloadRisk = true; workRisk = true
        case .resetGrant, .requestPersistentGrant: grantRisk = true; workRisk = true
        case .installManifestPackages, .configureFeatures, .configureDockerOwnerAccess,
             .configureRepository, .verifyOwnerDockerAccess: workRisk = true
        default: break
        }
        try await call(operation, cleanup: cleanup)
    }
    private func call(_ operation: GuestOperation, cleanup: Bool) async throws {
        guard let adapter, let context else { throw SequencingFailure.invalidRequest }
        let command = GuestCommand(id: UUID(), context: context, operation: operation, mode: context.mode,
            inputLeaseID: operation.interactive && !cleanup ? request?.inputLeaseID : nil,
            timeoutSeconds: cleanup ? 30 : operation.bodyTimeoutSeconds,
            plan: cleanup ? nil : request?.plan, tasks: cleanup ? [] : (request?.selectedTasks ?? []),
            conflictPolicy: request?.conflictPolicy ?? .fail)
        active = command
        event(.started, commandID: command.id, operation: operation)
        defer { if active?.id == command.id { active = nil } }
        do {
            let reply = try await adapter.perform(command)
            guard reply.target == context.target else { unsafeIdentity = true; throw SequencingFailure.identityMismatch }
            guard reply.dependencyDigest == context.dependencyDigest else { unsafeIdentity = true; throw SequencingFailure.dependencyChanged }
            guard reply.protocolVersion == GuestCommand.protocolVersion, reply.commandID == command.id,
                  reply.jobID == context.jobID, reply.proof == operation.expectedProof else {
                unsafeIdentity = true; throw SequencingFailure.protocolViolation
            }
            event(.completed, commandID: command.id, operation: operation)
        } catch {
            let code = failure(error)
            if [.identityMismatch, .dependencyChanged, .protocolViolation].contains(code) { unsafeIdentity = true }
            event(.failed, commandID: command.id, operation: operation, failure: code)
            throw code
        }
    }
    private func checkpoint() throws {
        if cancelled || Task.isCancelled { throw SequencingFailure.cancelled }
    }
    private func verifyPlan() throws {
        guard let request else { throw SequencingFailure.invalidRequest }
        do { try request.plan.verify(in: request.repository) } catch { throw SequencingFailure.sourceChanged }
    }
    private func failure(_ error: any Error) -> SequencingFailure {
        if error is CancellationError { return .cancelled }
        return error as? SequencingFailure ?? .adapterFailed
    }
    private var pending: Bool { grantRisk || payloadRisk || workRisk }
    private func transition(_ phase: ProvisioningPhase) {
        self.phase = phase; event(.phaseChanged)
    }
    private func event(_ kind: SequencingEventKind, commandID: UUID? = nil, operation: GuestOperation? = nil,
                       failure: SequencingFailure? = nil) {
        guard let context else { return }
        events.append(SequencingEvent(jobID: context.jobID, vmID: context.target.vmID, sessionID: context.target.sessionID,
                                     commandID: commandID, kind: kind, phase: phase, operation: operation, failure: failure))
    }
    private func result(_ outcome: ProvisioningOutcome) -> SequencingResult {
        let ticket = pending ? context.map { CleanupTicket(context: $0, grantMayBeActive: grantRisk,
                                                           payloadMayExist: payloadRisk, workMayBeActive: workRisk) } : nil
        return SequencingResult(outcome: outcome, primaryFailure: primary, cleanupFailures: cleanupFailures,
                                events: events, recovery: ticket)
    }
    private func rejection(_ failure: SequencingFailure) -> SequencingResult {
        SequencingResult(outcome: .rejected, primaryFailure: failure, cleanupFailures: [], events: [], recovery: nil)
    }
}
