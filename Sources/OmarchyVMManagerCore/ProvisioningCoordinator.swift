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
    private let artifacts: ProvisioningJobArtifacts?
    private let recoveryAuthority: (any ProvisioningRecoveryAuthorizing)?
    private let engineDigest: String
    private let admitPackage: @Sendable () throws -> Void
    private let cleanupGrace: Duration
    private var jobs: [UUID: ProvisioningJobRecord]
    private var active: Active?
    private var helperActive: HelperActive?
    private var recovering: [UUID: Recovery] = [:]
    private var helperAuthorities: [UUID: any ProvisioningRecoveryAuthorizing] = [:]
    private var admitting = false
    private var storageFailed = false
    private var closed = false

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
                 artifacts: ProvisioningJobArtifacts?, recoveryAuthority: (any ProvisioningRecoveryAuthorizing)?,
                 engineDigest: String, cleanupGrace: Duration, admitPackage: @escaping @Sendable () throws -> Void,
                 records: [ProvisioningJobRecord]) {
        self.manager = manager; self.journal = journal; self.authority = authority
        self.artifacts = artifacts; self.recoveryAuthority = recoveryAuthority
        self.engineDigest = engineDigest; self.cleanupGrace = cleanupGrace; self.admitPackage = admitPackage
        jobs = Dictionary(uniqueKeysWithValues: records.map { ($0.jobID, $0) })
    }
    static func open(manager: VMManager, journal: any ProvisioningJobJournaling, authority: any ProvisioningSessionAuthority,
                     artifacts: ProvisioningJobArtifacts? = nil, recoveryAuthority: (any ProvisioningRecoveryAuthorizing)? = nil,
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
            artifacts: artifacts, recoveryAuthority: recoveryAuthority,
            engineDigest: engineDigest, cleanupGrace: cleanupGrace, admitPackage: admitPackage, records: records)
        try await manager.installProvisioningCoordinator(coordinator.ownerID, blocked: Set(records.filter(\.cleanupRequired).map(\.vmID)))
        return coordinator
    }

    public func status(_ jobID: UUID) -> ProvisioningJobSnapshot? { jobs[jobID]?.snapshot }
    public func statuses() -> [ProvisioningJobSnapshot] { jobs.values.map(\.snapshot).sorted { $0.jobID.uuidString < $1.jobID.uuidString } }
    /// Releases only an idle coordinator. Does not stop/rebind the VM or clear risk.
    func closeForReopen() async throws {
        guard !closed, active == nil, helperActive == nil, !admitting else { throw ProvisioningJobFailure.busy }
        admitting = true; defer { admitting = false }
        try await manager.uninstallProvisioningCoordinator(ownerID)
        journal.close(); recovering.removeAll(); helperAuthorities.removeAll(); closed = true
    }
    func frozenInputs(_ jobID: UUID) throws -> FrozenInputsArchive {
        guard !closed, let record = jobs[jobID], let artifacts else { throw ProvisioningJobFailure.artifactUnavailable }
        return try artifacts.frozenInputs(record)
    }
    /// Waiting/losing a viewer never owns or cancels the detached job task.
    public func wait(_ jobID: UUID) async throws -> ProvisioningJobSnapshot {
        guard jobs[jobID] != nil else { throw ProvisioningJobFailure.unknownJob }
        if let running = active, running.jobID == jobID { await running.task?.value }
        if let running = helperActive, running.jobID == jobID { await running.task?.value }
        return jobs[jobID]!.snapshot
    }

    @discardableResult
    func submit(_ request: ProvisioningRequest, approval: ProvisioningApproval,
                adapter: any ProvisioningGuestAdapter) async throws -> ProvisioningJobSnapshot {
        guard !closed else { throw ProvisioningJobFailure.recoveryUnavailable }
        guard approval.reviewIdentity == request.reviewIdentity else { throw ProvisioningJobFailure.approvalRequired }
        if let existing = jobs[request.jobID] {
            guard existing.reviewDigest == request.reviewIdentity else { throw ProvisioningJobFailure.jobConflict }
            return existing.snapshot
        }
        guard active == nil, helperActive == nil, !admitting, !jobs.values.contains(where: { $0.helperIdentity != nil && $0.cleanupRequired }) else { throw ProvisioningJobFailure.busy }
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
            guard let artifacts else { throw ProvisioningJobFailure.artifactUnavailable }
            let payloadID = UUID(), workerToken = UUID()
            let files = try artifacts.prepare(request, payloadID: payloadID, workerToken: workerToken, engineDigest: engineDigest)
            var record = ProvisioningJobRecord(jobID: request.jobID, vmID: request.target.vmID, sessionID: request.target.sessionID,
                reviewDigest: request.reviewIdentity, planDigest: request.plan.identity, inputDigest: request.plan.snapshot.identity,
                engineDigest: engineDigest, dependencyDigest: request.dependencyDigest, bindingDigest: try Self.bindingIdentity(request.target), mode: request.mode)
            record.payloadID = payloadID; record.workerToken = workerToken
            record.inputArchiveSHA256 = files.inputsSHA256; record.cleanupCheckpointSHA256 = files.cleanupSHA256
            record.state = .running; record.workerOutstanding = true; record.cleanupRequired = true
            try persist(record)
            let driver = ProvisioningSequencer()
            active = Active(generation: generation, jobID: request.jobID, lease: lease, target: request.target, driver: driver)
            let wrapper = JournaledProvisioningAdapter(owner: self, generation: generation, underlying: adapter)
            active?.task = Task.detached {
                let result = await driver.run(request, approval: approval, payloadID: payloadID, adapter: wrapper)
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

    /// Reserve and register one inert helper worker. This does not run the
    /// sequencer or delegate a body command; operational dispatch is separate.
    @discardableResult
    func registerHelperWorker(_ request: ProvisioningRequest, approval: ProvisioningApproval,
                              launcher: any ProvisioningHelperLaunching) async throws -> ProvisioningJobSnapshot {
        guard !closed else { throw ProvisioningJobFailure.recoveryUnavailable }
        guard approval.reviewIdentity == request.reviewIdentity else { throw ProvisioningJobFailure.approvalRequired }
        if let existing = jobs[request.jobID] {
            guard existing.reviewDigest == request.reviewIdentity else { throw ProvisioningJobFailure.jobConflict }
            return existing.snapshot
        }
        guard active == nil, helperActive == nil, !admitting, !jobs.values.contains(where: { $0.helperIdentity != nil && $0.cleanupRequired }) else { throw ProvisioningJobFailure.busy }
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
        let lease = try await reserve(request.jobID, target: request.target, generation: UUID())
        var ticket: ProvisioningHelperLaunchTicket?
        do {
            try await manager.validateProvisioning(lease, cleanup: false)
            guard let artifacts else { throw ProvisioningJobFailure.artifactUnavailable }
            let payload = UUID(), worker = UUID()
            let files = try artifacts.prepare(request, payloadID: payload, workerToken: worker, engineDigest: engineDigest)
            var record = ProvisioningJobRecord(jobID: request.jobID, vmID: request.target.vmID, sessionID: request.target.sessionID,
                reviewDigest: request.reviewIdentity, planDigest: request.plan.identity, inputDigest: request.plan.snapshot.identity,
                engineDigest: engineDigest, dependencyDigest: request.dependencyDigest, bindingDigest: try Self.bindingIdentity(request.target), mode: request.mode)
            record.payloadID = payload; record.workerToken = worker
            record.inputArchiveSHA256 = files.inputsSHA256; record.cleanupCheckpointSHA256 = files.cleanupSHA256
            let scope = ProvisioningRecoveryExpectation(challenge: UUID(), jobID: record.jobID, vmID: record.vmID, sessionID: record.sessionID,
                payloadID: payload, workerToken: worker, engineDigest: record.engineDigest, dependencyDigest: record.dependencyDigest,
                bindingDigest: record.bindingDigest, reviewDigest: record.reviewDigest, checkpointDigest: files.cleanupSHA256)
            var registration = ProvisioningHelperWorkerRegistration(scope: scope, planDigest: record.planDigest, inputDigest: record.inputDigest, mode: record.mode)
            let prepared: ProvisioningHelperLaunchTicket
            if let frozen = launcher as? any ProvisioningFrozenHelperLaunching {
                let delivery = try artifacts.prepareDelivery(request, approval: approval, inputsSHA256: files.inputsSHA256)
                registration.delivery = delivery.receipt
                prepared = try await frozen.prepare(registration, delivery: delivery)
            } else { prepared = try await launcher.prepare(registration) }
            ticket = prepared
            var expected = scope; expected.helperIdentity = prepared.identity
            try prepared.identity.validate()
            guard prepared.registration.scope == expected, prepared.registration.planDigest == record.planDigest,
                  prepared.registration.inputDigest == record.inputDigest, prepared.registration.mode == record.mode,
                  prepared.registration.delivery == registration.delivery,
                  prepared.identity.packageLockSHA256 == ProvisioningPackagePin.lockSHA256,
                  !jobs.values.contains(where: { $0.helperIdentity?.instanceID == prepared.identity.instanceID }) else { throw ProvisioningJobFailure.invalidRequest }
            do { try admitPackage() } catch { throw ProvisioningJobFailure.invalidRequest }
            do { try request.plan.verify(in: request.repository) } catch { throw ProvisioningJobFailure.sourceChanged }
            do { try await authority.revalidate(request.target, dependencyDigest: request.dependencyDigest) }
            catch { throw ProvisioningJobFailure.dependencyChanged }
            try await manager.validateProvisioning(lease, cleanup: false)
            record.helperIdentity = prepared.identity; record.helperRegistrationDigest = try prepared.registration.digest
            record.helperRegistered = false; record.cleanupRequired = true; record.helperDelivery = registration.delivery
            try persist(record) // Original owner and pending registration precede spawn.
            helperAuthorities[record.jobID] = launcher
            let receipt = try await launcher.launch(prepared)
            guard receipt.identity == prepared.identity, receipt.registrationDigest == record.helperRegistrationDigest,
                  receipt.state == "registered", receipt.deliveryDigest == record.helperDelivery?.sha256 else { throw ProvisioningJobFailure.ownershipUnverified }
            do { try admitPackage() } catch { throw ProvisioningJobFailure.invalidRequest }
            if record.helperDelivery != nil { try artifacts.verifyDelivery(record) }
            else { try request.plan.verify(in: request.repository) }
            try await authority.revalidate(request.target, dependencyDigest: request.dependencyDigest)
            try await manager.validateProvisioning(lease, cleanup: false)
            record.helperRegistered = true; try advance(&record); try persist(record)
            await manager.releaseProvisioning(lease, cleanupRequired: true)
            return record.snapshot
        } catch {
            if let ticket { await launcher.abandon(ticket) }
            if var record = jobs[request.jobID] {
                record.state = .cleanupRequired; record.cleanupRequired = true; record.workerOutstanding = false
                record.failure = storageFailed ? .journalUnavailable : .helperUnavailable
                try? advance(&record); try? persist(record)
            }
            await manager.releaseProvisioning(lease, cleanupRequired: jobs[request.jobID]?.cleanupRequired ?? storageFailed)
            throw error
        }
    }

    @discardableResult
    func recover(_ jobID: UUID, target: GuestBinding? = nil, adapter: any ProvisioningGuestAdapter) async throws -> ProvisioningJobSnapshot {
        guard !closed else { throw ProvisioningJobFailure.recoveryUnavailable }
        guard active == nil, helperActive == nil, !admitting else { throw ProvisioningJobFailure.busy }
        guard !storageFailed else { throw ProvisioningJobFailure.journalUnavailable }
        guard var record = jobs[jobID], record.cleanupRequired else { throw ProvisioningJobFailure.unknownJob }
        guard let candidate = target ?? recovering[jobID]?.target else { throw ProvisioningJobFailure.recoveryUnavailable }
        guard record.engineDigest == engineDigest, record.attempts < 1000,
              candidate.vmID == record.vmID, candidate.sessionID == record.sessionID,
              record.bindingDigest == (try Self.bindingIdentity(candidate)) else { throw ProvisioningJobFailure.invalidRequest }
        admitting = true; defer { admitting = false }
        do { try admitPackage() } catch { throw ProvisioningJobFailure.invalidRequest }
        if let token = record.workerToken, let payload = record.payloadID, let checkpoint = record.cleanupCheckpointSHA256 {
            guard let recoveryAuthority = helperAuthorities[jobID] ?? recoveryAuthority else { throw ProvisioningJobFailure.ownershipUnverified }
            let expected = ProvisioningRecoveryExpectation(challenge: UUID(), jobID: jobID, vmID: record.vmID,
                sessionID: record.sessionID, payloadID: payload, workerToken: token, engineDigest: record.engineDigest,
                dependencyDigest: record.dependencyDigest, bindingDigest: record.bindingDigest,
                reviewDigest: record.reviewDigest, checkpointDigest: checkpoint, helperIdentity: record.helperIdentity)
            do {
                let permit = try await recoveryAuthority.reconcile(expected)
                guard permit.expectation == expected, permit.priorWorker == .stoppedAndFenced else { throw ProvisioningJobFailure.ownershipUnverified }
            } catch { throw ProvisioningJobFailure.ownershipUnverified }
        } else if recovering[jobID] == nil { throw ProvisioningJobFailure.recoveryUnavailable }
        // Only an authentic in-memory ticket or an exact independently bound
        // checkpoint can authorize cleanup. Inputs/source trees are not read.
        let ticket: CleanupTicket
        if let live = recovering[jobID] { ticket = live.ticket }
        else {
            guard let artifacts else { throw ProvisioningJobFailure.artifactUnavailable }
            ticket = try artifacts.cleanupTicket(record, target: candidate)
        }
        do { try await authority.revalidate(candidate, dependencyDigest: record.dependencyDigest) }
        catch { throw ProvisioningJobFailure.dependencyChanged }
        let generation = UUID(), lease = try await reserve(jobID, target: candidate, generation: generation, recovery: true)
        do {
            try await manager.validateProvisioning(lease, cleanup: true)
            record.state = .cleaningUp; record.workerOutstanding = true; record.failure = nil; record.attempts += 1
            record.engineFailure = nil; record.cleanupFailures = []; record.outcome = nil
            try advance(&record); try persist(record)
            let driver = ProvisioningSequencer()
            active = Active(generation: generation, jobID: jobID, lease: lease, target: candidate, driver: driver)
            let wrapper = JournaledProvisioningAdapter(owner: self, generation: generation, underlying: adapter)
            active?.task = Task.detached {
                let result = await driver.recover(ticket, adapter: wrapper)
                await self.finish(result, generation: generation)
            }
            return record.snapshot
        } catch {
            await manager.releaseProvisioning(lease, cleanupRequired: true); throw error
        }
    }

    public func cancel(_ jobID: UUID) throws {
        guard !closed else { throw ProvisioningJobFailure.recoveryUnavailable }
        guard jobs[jobID] != nil else { throw ProvisioningJobFailure.unknownJob }
        if var running = helperActive, running.jobID == jobID, !running.cancelled, !running.completing {
            running.cancelled = true; helperActive = running
            if var record = jobs[jobID] { record.state = .cancelling; try? advance(&record); try? persist(record) }
            let generation = running.generation, grace = cleanupGrace
            helperActive?.timer = Task { [weak self] in
                do { try await Task.sleep(for: grace) } catch { return }
                await self?.helperCleanupTimedOut(generation)
            }
            return
        }
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
        if let running = helperActive, running.generation == generation {
            if cause == .targetChanged { helperActive?.invalidated = true }
            if cause == .targetChanged, var record = jobs[running.jobID] { record.failure = .lifecycleChanged; try? advance(&record); try? persist(record) }
            try? cancel(running.jobID); return
        }
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
            if !cleanup {
                try admitPackage()
                guard let artifacts else { throw ProvisioningJobFailure.artifactUnavailable }
                try artifacts.verifyInputs(record)
            }
            try await manager.validateProvisioning(running.lease, cleanup: cleanup)
            try await authority.revalidate(running.target, dependencyDigest: record.dependencyDigest)
            try await manager.validateProvisioning(running.lease, cleanup: cleanup)
        } catch {
            // A pending ordinary shutdown bars body admission but does not
            // invalidate the guest. Classify that boundary as cancellation so
            // the engine can still revoke against the original verified target.
            if !cleanup, error as? ProvisioningJobFailure == .targetChanged,
               (try? await manager.validateProvisioning(running.lease, cleanup: true)) != nil {
                throw SequencingFailure.cancelled
            }
            throw Self.engineFailure(error)
        }
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
        // Completion checks physical identity, not admission of another body
        // command. Cancellation can arrive before the driver's interrupt task.
        do { try await manager.validateProvisioning(running.lease, cleanup: true) }
        catch { throw Self.engineFailure(error) }
        if command.plan != nil, active?.cancelled == true { throw SequencingFailure.cancelled }
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
        if !record.cleanupRequired, let identity = record.helperIdentity {
            await (helperAuthorities[record.jobID] ?? recoveryAuthority)?.releaseAfterCleanup(jobID: record.jobID, helperIdentity: identity)
            helperAuthorities.removeValue(forKey: record.jobID)
        }
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
    static func bindingIdentity(_ target: GuestBinding) throws -> String {
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


extension ProvisioningCoordinator {
    private struct HelperActive {
        let generation: UUID
        let jobID: UUID
        let lease: ProvisioningLifecycleLease
        let target: GuestBinding
        let dispatcher: any ProvisioningHelperDispatching
        let activation: ProvisioningHelperActivation
        var task: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var last: ProvisioningHelperWorkerSnapshot?
        var cancelled = false, expired = false, completing = false, invalidated = false
    }
    @discardableResult
    func activateHelperWorker(_ request: ProvisioningRequest, approval: ProvisioningApproval,
                              dispatcher: any ProvisioningHelperDispatching) async throws -> ProvisioningJobSnapshot {
        guard !closed, var record = jobs[request.jobID], record.helperRegistered == true,
              let identity = record.helperIdentity, let registrationDigest = record.helperRegistrationDigest,
              let payload = record.payloadID, let worker = record.workerToken, let checkpoint = record.cleanupCheckpointSHA256
        else { throw ProvisioningJobFailure.invalidRequest }
        guard request.reviewIdentity == record.reviewDigest, approval.reviewIdentity == record.reviewDigest else { throw ProvisioningJobFailure.approvalRequired }
        // Accepted activation, including interrupted/uncertain activation, is
        // never silently replayed after a missing reply or coordinator restart.
        if record.helperActivationID != nil { return record.snapshot }
        guard active == nil, helperActive == nil, !admitting else { throw ProvisioningJobFailure.busy }
        guard !storageFailed else { throw ProvisioningJobFailure.journalUnavailable }
        guard record.state == .queued, request.plan.identity == record.planDigest, request.plan.snapshot.identity == record.inputDigest,
              request.mode == record.mode, request.dependencyDigest == record.dependencyDigest,
              try Self.bindingIdentity(request.target) == record.bindingDigest,
              request.selectedTasks.isEmpty || approval.customTasksReviewed,
              request.mode == .check || approval.persistentGrantAcknowledged else { throw ProvisioningJobFailure.invalidRequest }
        admitting = true; defer { admitting = false }
        try admitPackage()
        guard let artifacts else { throw ProvisioningJobFailure.artifactUnavailable }
        if record.helperDelivery != nil { try artifacts.verifyDelivery(record) }
        else { try request.plan.verify(in: request.repository) }
        try artifacts.verifyInputs(record)
        try await authority.revalidate(request.target, dependencyDigest: record.dependencyDigest)
        let generation = UUID(), lease = try await reserve(request.jobID, target: request.target, generation: generation, recovery: true)
        do {
            try await manager.validateProvisioning(lease, cleanup: false)
            let scope = ProvisioningRecoveryExpectation(challenge: UUID(), jobID: record.jobID, vmID: record.vmID, sessionID: record.sessionID,
                payloadID: payload, workerToken: worker, engineDigest: record.engineDigest, dependencyDigest: record.dependencyDigest,
                bindingDigest: record.bindingDigest, reviewDigest: record.reviewDigest, checkpointDigest: checkpoint, helperIdentity: identity)
            let activation = ProvisioningHelperActivation(activationID: UUID(), registrationDigest: registrationDigest, scope: scope,
                customTasksReviewed: approval.customTasksReviewed, persistentGrantAcknowledged: approval.persistentGrantAcknowledged,
                dockerRootAccessAcknowledged: approval.dockerRootAccessAcknowledged)
            record.helperActivationID = activation.activationID; record.helperActivationDigest = try activation.digest
            record.state = .running; record.workerOutstanding = true; record.cleanupRequired = true
            try advance(&record); try persist(record) // Before any activation RPC.
            helperAuthorities[record.jobID] = dispatcher
            helperActive = HelperActive(generation: generation, jobID: record.jobID, lease: lease, target: request.target, dispatcher: dispatcher, activation: activation)
            helperActive?.task = Task.detached { await self.driveHelper(generation) }
            return record.snapshot
        } catch {
            if var latest = jobs[record.jobID], latest.helperActivationID != nil {
                latest.workerOutstanding = false; latest.state = .cleanupRequired; latest.failure = .journalUnavailable
                jobs[record.jobID] = latest
            }
            await manager.releaseProvisioning(lease, cleanupRequired: true); throw error
        }
    }
    private func driveHelper(_ generation: UUID) async {
        guard let running = helperActive, running.generation == generation else { return }
        do {
            var status = try await running.dispatcher.dispatch(.activate, activation: running.activation)
            var cancelSent = false
            while true {
                try await observeHelper(status, generation: generation)
                if status.terminal { await finishHelper(status, generation: generation); return }
                if helperActive?.cancelled == true, !cancelSent {
                    cancelSent = true; status = try await running.dispatcher.dispatch(.cancel, activation: running.activation)
                } else {
                    try await Task.sleep(for: .milliseconds(50))
                    status = try await running.dispatcher.dispatch(.status, activation: running.activation)
                }
            }
        } catch {
            await running.dispatcher.abort(running.activation)
            guard let current = helperActive, current.generation == generation, var row = jobs[current.jobID] else { return }
            current.timer?.cancel(); row.state = .cleanupRequired; row.cleanupRequired = true; row.workerOutstanding = false
            row.failure = storageFailed ? .journalUnavailable : .helperUnavailable
            try? advance(&row); try? persist(row)
            await manager.releaseProvisioning(current.lease, cleanupRequired: true); helperActive = nil
        }
    }
    private func observeHelper(_ status: ProvisioningHelperWorkerSnapshot, generation: UUID) async throws {
        try status.validate()
        guard let running = helperActive, running.generation == generation,
              status.activationID == running.activation.activationID, status.activationDigest == (try running.activation.digest),
              status.sequence >= (running.last?.sequence ?? 0) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        if let last = running.last, status.sequence == last.sequence, status != last { throw ProvisioningHelperIPCFailure.protocolViolation }
        do {
            try await authority.revalidate(running.target, dependencyDigest: running.activation.scope.dependencyDigest)
            try await manager.validateProvisioning(running.lease, cleanup: true)
        } catch {
            helperActive?.invalidated = true
            if var row = jobs[running.jobID] { if row.failure == nil { row.failure = .lifecycleChanged }; try? advance(&row); try? persist(row) }
            try? cancel(running.jobID)
        }
        guard var current = helperActive, current.generation == generation else { throw ProvisioningHelperIPCFailure.unavailable }
        let changed = current.last != status; current.last = status; helperActive = current
        if changed, var row = jobs[running.jobID] {
            row.operation = status.operation; row.commandID = status.commandID
            if status.phase == .cancelling, !current.expired { row.state = .cancelling }
            try advance(&row); try persist(row)
        }
    }
    private func helperCleanupTimedOut(_ generation: UUID) async {
        guard var running = helperActive, running.generation == generation, !running.completing else { return }
        running.expired = true; helperActive = running
        if var row = jobs[running.jobID] {
            row.state = .cleanupRequired; row.failure = .cleanupDeadline; row.cleanupRequired = true
            try? advance(&row); try? persist(row)
        }
        await manager.abandonProvisioningForShutdown(running.lease)
    }
    private func finishHelper(_ status: ProvisioningHelperWorkerSnapshot, generation: UUID) async {
        guard var running = helperActive, running.generation == generation, let outcome = status.outcome else { return }
        running.completing = true; helperActive = running; running.timer?.cancel()
        let sealed = !status.cleanupRequired && !storageFailed && !running.expired && !running.invalidated ? await manager.sealProvisioning(running.lease) : false
        guard let latest = helperActive, latest.generation == generation, var row = jobs[latest.jobID] else { return }
        running = latest
        row.workerOutstanding = false; row.engineFailure = status.primaryFailure; row.cleanupFailures = status.cleanupFailures
        row.cleanupRequired = status.cleanupRequired || storageFailed || running.expired || !sealed
        row.outcome = row.cleanupRequired ? .cleanupRequired : outcome
        if row.cleanupRequired { row.state = .cleanupRequired }
        else {
            switch outcome {
            case .applied: row.state = .succeeded
            case .checked: row.state = .checked
            case .appliedRestartRequired: row.state = .restartRequired
            case .cancelled: row.state = .cancelled
            case .timedOut: row.state = .timedOut
            case .authorizationRequired: row.state = .authorizationRequired
            case .cleanupConfirmed: row.state = .cleanupConfirmed
            case .rejected: row.state = .rejected
            default: row.state = .failed
            }
        }
        try? advance(&row)
        do { try persist(row) } catch { row.cleanupRequired = true; row.state = .cleanupRequired; row.failure = .journalUnavailable; jobs[row.jobID] = row }
        if !row.cleanupRequired, let identity = row.helperIdentity {
            await running.dispatcher.releaseAfterCleanup(jobID: row.jobID, helperIdentity: identity); helperAuthorities.removeValue(forKey: row.jobID)
        }
        await manager.releaseProvisioning(running.lease, cleanupRequired: row.cleanupRequired); helperActive = nil
    }
}
