import DevVMProvisioningCore
import Foundation

struct ProvisioningLifecycleLease: Equatable, Sendable {
    let token: UUID
    let jobID: UUID
    let vmID: UUID
    let sessionID: UUID
}
enum ProvisioningLifecycleInterruption: Sendable { case shutdown, targetChanged }

/// Foundation behind explicitly injected adapters. No public constructor or
/// app/helper/CLI entry point enables real provisioning in this milestone.
public actor ProvisioningCoordinator {
    private let ownerID = UUID()
    private let manager: VMManager
    private let journal: any ProvisioningJobJournaling
    private let authority: any ProvisioningSessionAuthority
    private let engineDigest: String
    private let admitPackage: @Sendable () throws -> Void
    private let cleanupGrace: Duration
    private var jobs: [UUID: ProvisioningJobRecord]
    private var active: Active?
    private var recovering: [UUID: Recovery] = [:]
    private var admitting = false
    private var storageFailed = false

    private struct Active {
        let generation: UUID
        let jobID: UUID
        let lease: ProvisioningLifecycleLease
        let target: GuestBinding
        let driver: ProvisioningSequencer
        var task: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var cancelled = false
        var expired = false
        var completing = false
    }
    private struct Recovery: Sendable { let ticket: CleanupTicket; let target: GuestBinding }
    private struct Binding: Encodable {
        let vm: UUID, session: UUID
        let owner: String
        let uid: UInt32
        let key: String
    }
    private init(manager: VMManager, journal: any ProvisioningJobJournaling, authority: any ProvisioningSessionAuthority,
                 engineDigest: String, cleanupGrace: Duration, admitPackage: @escaping @Sendable () throws -> Void,
                 records: [ProvisioningJobRecord]) {
        self.manager = manager; self.journal = journal; self.authority = authority
        self.engineDigest = engineDigest; self.cleanupGrace = cleanupGrace; self.admitPackage = admitPackage
        jobs = Dictionary(uniqueKeysWithValues: records.map { ($0.jobID, $0) })
    }
    static func open(manager: VMManager, journal: any ProvisioningJobJournaling, authority: any ProvisioningSessionAuthority,
                     engineDigest: String, cleanupGrace: Duration = .seconds(240),
                     admitPackage: @escaping @Sendable () throws -> Void) async throws -> ProvisioningCoordinator {
        guard provisioningDigest(engineDigest), cleanupGrace > .zero, cleanupGrace <= .seconds(300) else { throw ProvisioningJobFailure.invalidRequest }
        var records = try journal.load(), changed = false
        for index in records.indices where records[index].state.unfinished || records[index].workerOutstanding {
            guard records[index].sequence < UInt64.max else { throw ProvisioningJobFailure.journalUnavailable }
            records[index].sequence += 1
            records[index].state = records[index].cleanupRequired ? .cleanupRequired : .interrupted
            records[index].failure = .managerRestarted; records[index].workerOutstanding = false; changed = true
        }
        if changed { try journal.save(records) }
        let coordinator = ProvisioningCoordinator(manager: manager, journal: journal, authority: authority,
            engineDigest: engineDigest, cleanupGrace: cleanupGrace, admitPackage: admitPackage, records: records)
        try await manager.installProvisioningCoordinator(coordinator.ownerID, blocked: Set(records.filter(\.cleanupRequired).map(\.vmID)))
        return coordinator
    }

    public func status(_ jobID: UUID) -> ProvisioningJobSnapshot? { jobs[jobID]?.snapshot }
    public func statuses() -> [ProvisioningJobSnapshot] { jobs.values.map(\.snapshot).sorted { $0.jobID.uuidString < $1.jobID.uuidString } }
    /// Waiting/losing a viewer never owns or cancels the detached job task.
    public func wait(_ jobID: UUID) async throws -> ProvisioningJobSnapshot {
        guard jobs[jobID] != nil else { throw ProvisioningJobFailure.unknownJob }
        if let running = active, running.jobID == jobID { await running.task?.value }
        return jobs[jobID]!.snapshot
    }

    @discardableResult
    func submit(_ request: ProvisioningRequest, approval: ProvisioningApproval,
                adapter: any ProvisioningGuestAdapter) async throws -> ProvisioningJobSnapshot {
        guard approval.reviewIdentity == request.reviewIdentity else { throw ProvisioningJobFailure.approvalRequired }
        if let existing = jobs[request.jobID] {
            guard existing.reviewDigest == request.reviewIdentity else { throw ProvisioningJobFailure.jobConflict }
            return existing.snapshot
        }
        guard active == nil, !admitting else { throw ProvisioningJobFailure.busy }
        guard !storageFailed, jobs.count < ProvisioningJobJournal.maximumJobs else { throw ProvisioningJobFailure.journalUnavailable }
        guard !jobs.values.contains(where: { $0.vmID == request.target.vmID && $0.cleanupRequired }) else { throw ProvisioningJobFailure.cleanupRequired }
        admitting = true; defer { admitting = false }
        guard request.selectedTasks.isEmpty || approval.customTasksReviewed,
              request.mode == .check || approval.persistentGrantAcknowledged else { throw ProvisioningJobFailure.approvalRequired }
        do { try admitPackage() } catch { throw ProvisioningJobFailure.invalidRequest }
        do { try request.plan.verify(in: request.repository) } catch { throw ProvisioningJobFailure.sourceChanged }
        guard try Self.engineIdentity(request.plan) == engineDigest else { throw ProvisioningJobFailure.invalidRequest }
        do { try await authority.revalidate(request.target, dependencyDigest: request.dependencyDigest) }
        catch { throw ProvisioningJobFailure.dependencyChanged }
        let generation = UUID()
        let lease = try await reserve(request.jobID, target: request.target, generation: generation)
        do {
            try await manager.validateProvisioning(lease, cleanup: false)
            var record = ProvisioningJobRecord(jobID: request.jobID, vmID: request.target.vmID, sessionID: request.target.sessionID,
                reviewDigest: request.reviewIdentity, planDigest: request.plan.identity, inputDigest: request.plan.snapshot.identity,
                engineDigest: engineDigest, dependencyDigest: request.dependencyDigest, bindingDigest: try Self.bindingIdentity(request.target), mode: request.mode)
            record.state = .running; record.workerOutstanding = true; record.cleanupRequired = true
            try persist(record)
            let driver = ProvisioningSequencer()
            active = Active(generation: generation, jobID: request.jobID, lease: lease, target: request.target, driver: driver)
            let wrapper = JournaledProvisioningAdapter(owner: self, generation: generation, underlying: adapter)
            active?.task = Task.detached {
                let result = await driver.run(request, approval: approval, adapter: wrapper)
                await self.finish(result, generation: generation)
            }
            return record.snapshot
        } catch {
            if var record = jobs[request.jobID] {
                record.state = .cleanupRequired; record.cleanupRequired = true; record.workerOutstanding = false
                record.failure = .journalUnavailable; jobs[request.jobID] = record
            }
            await manager.releaseProvisioning(lease, cleanupRequired: storageFailed)
            throw error
        }
    }

    func recover(_ jobID: UUID, adapter: any ProvisioningGuestAdapter) async throws -> ProvisioningJobSnapshot {
        guard active == nil, !admitting else { throw ProvisioningJobFailure.busy }
        guard !storageFailed else { throw ProvisioningJobFailure.journalUnavailable }
        guard var record = jobs[jobID], record.cleanupRequired else { throw ProvisioningJobFailure.unknownJob }
        // The pinned engine deliberately does not serialize its private ticket.
        // Reopen never synthesizes one or reconnects a helper from a stored PID.
        guard let recovery = recovering[jobID] else { throw ProvisioningJobFailure.recoveryUnavailable }
        guard record.engineDigest == engineDigest, record.attempts < 1000,
              record.bindingDigest == (try Self.bindingIdentity(recovery.target)) else { throw ProvisioningJobFailure.invalidRequest }
        admitting = true; defer { admitting = false }
        do { try admitPackage() } catch { throw ProvisioningJobFailure.invalidRequest }
        do { try await authority.revalidate(recovery.target, dependencyDigest: record.dependencyDigest) }
        catch { throw ProvisioningJobFailure.dependencyChanged }
        let generation = UUID(), lease = try await reserve(jobID, target: recovery.target, generation: generation, recovery: true)
        do {
            try await manager.validateProvisioning(lease, cleanup: true)
            record.state = .cleaningUp; record.workerOutstanding = true; record.failure = nil; record.attempts += 1
            record.engineFailure = nil; record.cleanupFailures = []; record.outcome = nil
            try advance(&record); try persist(record)
            let driver = ProvisioningSequencer()
            active = Active(generation: generation, jobID: jobID, lease: lease, target: recovery.target, driver: driver)
            let wrapper = JournaledProvisioningAdapter(owner: self, generation: generation, underlying: adapter)
            active?.task = Task.detached {
                let result = await driver.recover(recovery.ticket, adapter: wrapper)
                await self.finish(result, generation: generation)
            }
            return record.snapshot
        } catch {
            await manager.releaseProvisioning(lease, cleanupRequired: true); throw error
        }
    }

    public func cancel(_ jobID: UUID) throws {
        guard jobs[jobID] != nil else { throw ProvisioningJobFailure.unknownJob }
        guard var running = active, running.jobID == jobID, !running.cancelled, !running.completing else { return }
        running.cancelled = true; active = running
        if var record = jobs[jobID] {
            record.state = .cancelling; try? advance(&record); try? persist(record)
        }
        let driver = running.driver, generation = running.generation, grace = cleanupGrace
        Task { await driver.requestCancellation() }
        active?.timer = Task { [weak self] in
            do { try await Task.sleep(for: grace) } catch { return }
            await self?.cleanupTimedOut(generation)
        }
    }
    private func reserve(_ id: UUID, target: GuestBinding, generation: UUID, recovery: Bool = false) async throws -> ProvisioningLifecycleLease {
        try await manager.reserveProvisioning(owner: ownerID, jobID: id, target: target, recovery: recovery) { [weak self] cause in
            await self?.lifecycleInterrupted(generation, cause: cause)
        }
    }
    private func lifecycleInterrupted(_ generation: UUID, cause: ProvisioningLifecycleInterruption) {
        guard let running = active, running.generation == generation else { return }
        if cause == .targetChanged, var record = jobs[running.jobID] {
            record.failure = .lifecycleChanged; try? advance(&record); try? persist(record)
        }
        try? cancel(running.jobID)
    }
    private func cleanupTimedOut(_ generation: UUID) async {
        guard var running = active, running.generation == generation, !running.completing else { return }
        running.expired = true; active = running
        if var record = jobs[running.jobID] {
            record.state = .cleanupRequired; record.failure = .cleanupDeadline; record.cleanupRequired = true
            try? advance(&record); try? persist(record)
        }
        // Keep the task/lease. VM handles remain until matching VM .exited;
        // bounded Quit may proceed only after recording the unresolved job.
        await manager.abandonProvisioningForShutdown(running.lease)
    }

    fileprivate func before(_ command: DevVMProvisioningCore.GuestCommand, generation: UUID) async throws {
        guard let running = active, running.generation == generation, !running.expired,
              var record = jobs[running.jobID], command.context.jobID == record.jobID,
              command.context.target == running.target, command.context.dependencyDigest == record.dependencyDigest,
              command.context.mode == record.mode, command.mode == record.mode,
              record.payloadID == nil || record.payloadID == command.context.payloadID,
              command.plan == nil || command.plan?.identity == record.planDigest else { throw SequencingFailure.identityMismatch }
        let cleanup = command.plan == nil
        if !cleanup, running.cancelled { throw SequencingFailure.cancelled }
        if !cleanup, storageFailed { throw SequencingFailure.adapterFailed }
        if cleanup, command.inputLeaseID != nil { throw SequencingFailure.protocolViolation }
        do {
            if !cleanup { try admitPackage() }
            try await manager.validateProvisioning(running.lease, cleanup: cleanup)
            try await authority.revalidate(running.target, dependencyDigest: record.dependencyDigest)
            try await manager.validateProvisioning(running.lease, cleanup: cleanup)
        } catch { throw Self.engineFailure(error) }
        // Cancellation may have arrived during either admission await.
        guard let current = active, current.generation == generation, !current.expired else { throw SequencingFailure.cancelled }
        if !cleanup, current.cancelled { throw SequencingFailure.cancelled }
        record.payloadID = command.context.payloadID; record.commandID = command.id; record.operation = command.operation
        if cleanup { record.state = .cleaningUp }
        else if command.operation == .requestPersistentGrant { record.state = .awaitingAuthorization }
        else if command.operation != .verifyIdentity { record.state = .running }
        try advance(&record)
        do { try persist(record) }
        catch {
            // A failed disk must stop body work, not prevent grant revocation.
            if !cleanup { throw SequencingFailure.adapterFailed }
        }
    }
    fileprivate func after(_ command: DevVMProvisioningCore.GuestCommand, generation: UUID) async throws {
        guard let running = active, running.generation == generation, !running.expired else { throw SequencingFailure.cancelled }
        do { try await manager.validateProvisioning(running.lease, cleanup: command.plan == nil) }
        catch { throw Self.engineFailure(error) }
    }
    fileprivate func interruptAllowed(_ commandID: UUID, context: GuestJobContext, generation: UUID) -> Bool {
        guard let running = active, running.generation == generation, let record = jobs[running.jobID] else { return false }
        return context.jobID == record.jobID && context.target == running.target && record.commandID == commandID
    }
    private func finish(_ result: SequencingResult, generation: UUID) async {
        guard var running = active, running.generation == generation else { return }
        running.completing = true; active = running
        running.timer?.cancel()
        let currentTarget = result.recovery == nil && !storageFailed && !running.expired
            ? await manager.sealProvisioning(running.lease) : false
        guard let latest = active, latest.generation == generation, var record = jobs[latest.jobID] else { return }
        running = latest
        record.workerOutstanding = false; record.engineFailure = result.primaryFailure
        record.cleanupFailures = Array(result.cleanupFailures.prefix(32))
        record.outcome = result.outcome
        record.cleanupRequired = result.recovery != nil || storageFailed || running.expired || !currentTarget
        if result.recovery == nil, !currentTarget, !storageFailed, !running.expired { record.failure = .lifecycleChanged }
        if record.cleanupRequired { record.state = .cleanupRequired; record.outcome = .cleanupRequired }
        else {
            switch result.outcome {
            case .applied: record.state = .succeeded
            case .appliedRestartRequired: record.state = .restartRequired
            case .checked: record.state = .checked
            case .cancelled: record.state = .cancelled
            case .timedOut: record.state = .timedOut
            case .authorizationRequired: record.state = .authorizationRequired
            case .rejected: record.state = .rejected
            case .cleanupConfirmed: record.state = .cleanupConfirmed
            default: record.state = .failed
            }
            if record.state == .failed, record.failure == nil { record.failure = .driverFailed }
        }
        if let ticket = result.recovery { recovering[running.jobID] = Recovery(ticket: ticket, target: running.target) }
        else { recovering.removeValue(forKey: running.jobID) }
        try? advance(&record)
        do { try persist(record) }
        catch { record.state = .cleanupRequired; record.cleanupRequired = true; record.failure = .journalUnavailable; jobs[record.jobID] = record }
        // active stays installed across actor hops so another job cannot race
        // lifecycle release or hijack an old completion.
        await manager.releaseProvisioning(running.lease, cleanupRequired: record.cleanupRequired)
        active = nil
    }
    private func persist(_ record: ProvisioningJobRecord) throws {
        jobs[record.jobID] = record
        do { try journal.save(Array(jobs.values)) }
        catch {
            storageFailed = true
            jobs[record.jobID]?.failure = .journalUnavailable
            throw ProvisioningJobFailure.journalUnavailable
        }
    }
    private func advance(_ record: inout ProvisioningJobRecord) throws {
        guard record.sequence < UInt64.max else { throw ProvisioningJobFailure.journalUnavailable }
        record.sequence += 1
    }
    static func engineIdentity(_ plan: SetupPlan) throws -> String {
        guard case .object(let fields) = plan.document, let engine = fields["engine"] else { throw ProvisioningJobFailure.invalidRequest }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return KitVerifier.sha256(try encoder.encode(engine))
    }
    private static func bindingIdentity(_ target: GuestBinding) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return KitVerifier.sha256(try encoder.encode(Binding(vm: target.vmID, session: target.sessionID, owner: target.owner, uid: target.ownerUID, key: target.hostKeyDigest)))
    }
    private static func engineFailure(_ error: any Error) -> SequencingFailure {
        if error is CancellationError { return .cancelled }
        if let error = error as? SequencingFailure { return error }
        if let error = error as? ProvisioningJobFailure, [.targetChanged, .lifecycleChanged].contains(error) { return .identityMismatch }
        return .adapterFailed
    }
}

private struct JournaledProvisioningAdapter: ProvisioningGuestAdapter {
    let owner: ProvisioningCoordinator
    let generation: UUID
    let underlying: any ProvisioningGuestAdapter
    func perform(_ command: DevVMProvisioningCore.GuestCommand) async throws -> DevVMProvisioningCore.GuestReply {
        try await owner.before(command, generation: generation)
        let result = try await underlying.perform(command)
        try await owner.after(command, generation: generation)
        return result
    }
    func interrupt(commandID: UUID, context: GuestJobContext) async {
        guard await owner.interruptAllowed(commandID, context: context, generation: generation) else { return }
        await underlying.interrupt(commandID: commandID, context: context)
    }
}
