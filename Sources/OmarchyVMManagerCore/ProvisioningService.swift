import DevVMProvisioningCore
import Foundation

/// `alreadyRun`: this plan's run has finished. A plan runs once; Run setup again
/// makes a fresh plan with a new ID from the same frozen choices (issue #14).
public enum ProvisioningServiceFailure: String, Error, Sendable { case disabled, busy, unknownWorkflow, reviewRequired, interrupted, targetChanged, timedOut, unavailable, alreadyRun }
struct ProvisioningPreparedJob: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let workflowID: UUID
    let request: ProvisioningRequest
    let transport: ProvisioningTransportAdmission
    var description: String { "ProvisioningPreparedJob(redacted)" }
    var debugDescription: String { description }
}
struct ProvisioningRestartReview: Sendable {
    let workflowID: UUID, restartID: UUID, originalSessionID: UUID
    let reviewDigest: String
    var identity: String { get throws { KitVerifier.sha256(try helperJSON([workflowID.uuidString, restartID.uuidString, originalSessionID.uuidString, reviewDigest])) } }
}
struct ProvisioningRebindReview: Sendable {
    let workflowID: UUID, restartID: UUID, newSessionID: UUID
    let requestReviewDigest: String
    var identity: String { get throws { KitVerifier.sha256(try helperJSON([workflowID.uuidString, restartID.uuidString, newSessionID.uuidString, requestReviewDigest])) } }
}
struct ProvisioningServiceEnvironment: Sendable {
    let executionEnabled: Bool // Trusted composition only; ordinary product false.
    let engineDigest: String
    let dependencies: any ProvisioningDependencyProviding
    let launcher: any ProvisioningServiceLaunching
    let transportPolicy: ProvisioningTransportPolicy
    let admitPackage: @Sendable () throws -> Void
    // Trusted composition only. Product resolves ephemeral authenticated SSH
    // evidence; fixtures may supply synthetic bindings. Execution stays gated.
    var themeResolver = ThemeResolver(http: ProvisioningThemeHTTP(), stars: ProvisioningThemeStars())
    var resolveTarget: (@Sendable (UUID, UUID) async throws -> GuestBinding)? = nil
    // Internal fixtures retain explicit injection; product selects disabled or
    // its compiled reviewed scope, never a wire/manifest/readiness switch.
    var executionAdmission: ProvisioningExecutionAdmission = .fixture
    // Inert constructor only, first used behind authenticated cleanup admission.
    var makeRecoveryAdapter: (@Sendable (ProvisioningTransportAdmission) throws -> any ProvisioningGuestAdapter)? = nil
}
actor ProvisioningAdmittedSessionAuthority: ProvisioningSessionAuthority {
    let manager: VMManager
    private var admissions: [String: ProvisioningTransportAdmission] = [:]
    init(manager: VMManager) { self.manager = manager }
    func admit(_ value: ProvisioningTransportAdmission) async throws {
        try await manager.validateProvisioningTransport(value)
        guard admissions.count < 256 || admissions[value.dependencyDigest] != nil else { throw ProvisioningJobFailure.busy }
        admissions[value.dependencyDigest] = value
    }
    func revalidate(_ binding: GuestBinding, dependencyDigest: String) async throws {
        guard let original = admissions[dependencyDigest], original.target == binding else { throw SequencingFailure.dependencyChanged }
        try await manager.validateProvisioningTransport(original, cleanup: true)
    }
}

/// Manager-owned composition/lifecycle service. Viewers only observe; owned tasks
/// survive a cancelled waiter. Compiled Dev eligibility, review and authenticated
/// target/helper admission gate execution; ordinary Stable execution is disabled.
public actor ProvisioningService {
    public nonisolated let executionEnabled: Bool
    let manager: VMManager
    let coordinator: ProvisioningCoordinator
    private let workflows: ProvisioningWorkflowJournal
    let jobs: ProvisioningJobJournal
    private let artifacts: ProvisioningJobArtifacts
    let sourceDirectory: URL
    let planHistory: ProvisioningPlanHistory
    let environment: ProvisioningServiceEnvironment
    private let authority: ProvisioningAdmittedSessionAuthority
    var rows: [UUID: ProvisioningWorkflowRecord]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var previews: [UUID: ProvisioningPreparedJob] = [:]
    var original: [UUID: ProvisioningPreparedJob] = [:]
    private var preparations: [UUID: ProvisioningPreparationLease] = [:]
    private var restarts: [UUID: ProvisioningRestartLease] = [:]
    private var sources: [UUID: ProvisioningPrivateInputTree] = [:]
    private var cancelled = Set<UUID>()
    private var restartReviews: [UUID: ProvisioningRestartReview] = [:]
    private var rebindInFlight = Set<UUID>()
    private var unconfirmedExits = Set<UUID>()
    private var busyID: UUID?
    var drafts: [UUID: ProvisioningDraft] = [:]
    var draftCaptures = Set<UUID>()
    var creations: [UUID: ProvisioningCreationDraft] = [:]
    var applyPreparations: [UUID: Task<ProvisioningApplyReview, Error>] = [:]
    var applyReviews: [UUID: ProvisioningApplyReview] = [:]
    var retries: [UUID: ProvisioningRetryPreview] = [:]
    /// Workflows started by Run the check only. They prepare and run in one step, so
    /// they are never offered as a pending approval or an apply review.
    var checkRuns: Set<UUID> = []
    var applySubmissions: [UUID: (ProvisioningApplyConsent, Task<ProvisioningWorkflowSnapshot, Error>)] = [:]
    var reviewOperations = Set<UUID>()
    var actionPreparations: [UUID: ProvisioningActionPreparation] = [:]
    var actionContexts: [UUID: ProvisioningActionContext] = [:]
    var actionSubmissions: [UUID: (ProvisioningWorkflowActionConsent, Task<ProvisioningWorkflowSnapshot, Error>)] = [:]
    var actionWorkflowsInFlight = Set<UUID>()
    private var closed = false, failed = false

    private init(manager: VMManager, coordinator: ProvisioningCoordinator, jobs: ProvisioningJobJournal, workflows: ProvisioningWorkflowJournal,
                 artifacts: ProvisioningJobArtifacts, sourceDirectory: URL, planHistory: ProvisioningPlanHistory, environment: ProvisioningServiceEnvironment,
                 authority: ProvisioningAdmittedSessionAuthority, rows: [ProvisioningWorkflowRecord]) {
        self.manager = manager; self.coordinator = coordinator; self.jobs = jobs; self.workflows = workflows; self.artifacts = artifacts
        self.sourceDirectory = sourceDirectory; self.planHistory = planHistory; self.environment = environment; self.authority = authority; self.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        executionEnabled = environment.executionEnabled
    }
    static func open(manager: VMManager, directory: URL, environment: ProvisioningServiceEnvironment) async throws -> ProvisioningService {
        try PrivateFiles.directory(directory, create: true)
        let jobs: ProvisioningJobJournal
        do { jobs = try ProvisioningJobJournal(directory: directory.appendingPathComponent("jobs")) }
        catch { await manager.markProvisioningStorageUnknown(); throw ProvisioningJobFailure.journalUnavailable }
        let workflows: ProvisioningWorkflowJournal
        do { workflows = try ProvisioningWorkflowJournal(directory: directory.appendingPathComponent("workflows")) }
        catch { jobs.close(); await manager.markProvisioningStorageUnknown(); throw ProvisioningJobFailure.journalUnavailable }
        var records: [ProvisioningWorkflowRecord]
        do {
            records = try workflows.load()
            let prior = try jobs.load()
            await manager.seedProvisioningRisk(Set(prior.filter(\.cleanupRequired).map(\.vmID)))
            for index in records.indices {
                let childIDs = [records[index].applyJobID, records[index].checkJobID].compactMap { $0 }
                let childRisk = prior.contains { childIDs.contains($0.jobID) && $0.cleanupRequired }
                if records[index].stage.unfinished || records[index].stage == .restartRequired || childRisk {
                    records[index].cleanupRequired = records[index].cleanupRequired || childRisk || [.running, .checking].contains(records[index].stage)
                    records[index].stage = records[index].cleanupRequired ? .cleanupRequired : .interrupted; records[index].failure = .processInterrupted; records[index].sequence += 1
                }
                if records[index].cleanupRequired { await manager.setProvisioningWorkflowHold(records[index].id, vmID: records[index].vmID, required: true) }
            }
            if !records.isEmpty { try workflows.save(records) }
        } catch { await manager.markProvisioningStorageUnknown(); jobs.close(); workflows.close(); throw ProvisioningJobFailure.journalUnavailable }
        let authority = ProvisioningAdmittedSessionAuthority(manager: manager)
        let artifacts = try ProvisioningJobArtifacts(directory: directory.appendingPathComponent("artifacts"))
        let sourceDirectory = directory.appendingPathComponent("sources"); try PrivateFiles.directory(sourceDirectory, create: true)
        let coordinator = try await ProvisioningCoordinator.open(manager: manager, journal: jobs, authority: authority, artifacts: artifacts,
            recoveryAuthority: environment.launcher, engineDigest: environment.engineDigest, executionAdmission: environment.executionAdmission, admitPackage: environment.admitPackage)
        let planHistory = ProvisioningPlanHistory(directory: directory.appendingPathComponent("plans"))
        return .init(manager: manager, coordinator: coordinator, jobs: jobs, workflows: workflows, artifacts: artifacts,
            sourceDirectory: sourceDirectory, planHistory: planHistory, environment: environment, authority: authority, rows: records)
    }
    func reviewAvailable() throws { guard !closed, !failed else { throw ProvisioningServiceFailure.unavailable } }
    public func status(_ id: UUID) -> ProvisioningWorkflowSnapshot? { rows[id]?.snapshot }
    public func attachTerminal(_ id: UUID) async throws -> ProvisioningTerminalAttachment {
        guard !closed, let row = rows[id], let launcher = environment.launcher as? any ProvisioningTerminalLaunching else { throw ProvisioningTerminalDenial.unavailable }
        let jobID = row.checkJobID ?? row.applyJobID
        guard let jobID else { throw ProvisioningTerminalDenial.unavailable }
        return try await ProvisioningTerminalAttachment.attach(client: try await launcher.terminalClient(jobID: jobID))
    }
    public func setupLog(vmID: UUID) async -> Data? { try? await manager.setupLog(vmID: vmID) }
    public func jobStatus(_ id: UUID) async -> ProvisioningJobSnapshot? {
        guard let row = rows[id], let job = row.checkJobID ?? row.applyJobID else { return nil }
        return await coordinator.status(job)
    }
    public func statuses() -> [ProvisioningWorkflowSnapshot] { rows.values.map(\.snapshot).sorted { $0.id.uuidString < $1.id.uuidString } }
    public func wait(_ id: UUID) async throws -> ProvisioningWorkflowSnapshot {
        guard rows[id] != nil else { throw ProvisioningServiceFailure.unknownWorkflow }
        await tasks[id]?.value
        return rows[id]!.snapshot
    }
    func enabled() throws {
        guard !closed, !failed else { throw ProvisioningServiceFailure.unavailable }
        guard executionEnabled else { throw ProvisioningServiceFailure.disabled }
    }
    private func save(_ row: ProvisioningWorkflowRecord) throws {
        rows[row.id] = row
        do { try workflows.save(Array(rows.values)) }
        catch { failed = true; rows[row.id]?.failure = .journalUnavailable; throw ProvisioningJobFailure.journalUnavailable }
    }
    private func update(_ id: UUID, stage: ProvisioningWorkflowStage, failure: ProvisioningWorkflowFailure? = nil, risk: Bool? = nil) throws {
        guard var row = rows[id], row.sequence < UInt64(Int64.max)-1 else { throw ProvisioningJobFailure.journalUnavailable }
        row.stage = stage; row.failure = failure; if let risk { row.cleanupRequired = risk }; row.sequence += 1; try save(row)
    }
    private func current(_ id: UUID) throws {
        guard !closed, !failed, busyID == id, !cancelled.contains(id) else { throw ProvisioningServiceFailure.interrupted }
    }
    @discardableResult
    func prepare(id: UUID = UUID(), plan: SetupPlan, repository: URL, target: GuestBinding, mode: ProvisioningMode = .apply,
                 inputLeaseID: UUID? = nil, timeout: Duration = .seconds(180)) async throws -> ProvisioningWorkflowSnapshot {
        try enabled()
        guard timeout > .zero, timeout <= .seconds(300) else { throw ProvisioningServiceFailure.unavailable }
        if let row = rows[id] {
            guard row.vmID == target.vmID, row.originalSessionID == target.sessionID, row.planDigest == plan.identity, row.inputDigest == plan.snapshot.identity else { throw ProvisioningJobFailure.jobConflict }
            return row.snapshot // Never recreate a task after a lost reply/reopen.
        }
        guard busyID == nil, rows.count < 128, !rows.values.contains(where: \.cleanupRequired) else { throw ProvisioningServiceFailure.busy }
        try environment.admitPackage(); try plan.verify(in: repository)
        guard try ProvisioningCoordinator.engineIdentity(plan) == environment.engineDigest else { throw ProvisioningJobFailure.invalidRequest }
        guard let profile = await manager.snapshots().first(where: { $0.id == target.vmID })?.profile else { throw ProvisioningReviewFailure.invalid }
        try ProvisioningTrim.admit(plan, factory: profile.factory)
        // Actor reentrancy during the manager snapshot must not admit a second preparation.
        try enabled()
        guard busyID == nil, rows[id] == nil, rows.count < 128, !rows.values.contains(where: \.cleanupRequired) else { throw ProvisioningServiceFailure.busy }
        busyID = id
        do {
            let lease = try await coordinator.beginPreparation(jobID: id, target: target) { [weak self] in await self?.cancelForLifecycle(id) }
            preparations[id] = lease
            let row = ProvisioningWorkflowRecord(id: id, vmID: target.vmID, originalSessionID: target.sessionID, planDigest: plan.identity,
                inputDigest: plan.snapshot.identity, engineDigest: environment.engineDigest)
            try save(row)
            tasks[id] = Task.detached { await self.prepareOwned(id, plan: plan, repository: repository, target: target, mode: mode, inputLeaseID: inputLeaseID, timeout: timeout) }
            return row.snapshot
        } catch {
            if let lease = preparations.removeValue(forKey: id) { await coordinator.endPreparation(lease) }
            busyID = nil; throw error
        }
    }
    private func prepareOwned(_ id: UUID, plan: SetupPlan, repository: URL, target: GuestBinding, mode: ProvisioningMode, inputLeaseID: UUID?, timeout: Duration) async {
        do {
            try await waitSSH(id, target: target, timeout: timeout)
            let report = try await environment.dependencies.inspect(); try current(id)
            let admission = try await manager.admitProvisioningTransport(target: target, report: report, policy: environment.transportPolicy)
            try current(id); try plan.verify(in: repository); try environment.admitPackage()
            try await authority.admit(admission); try current(id)
            // A check on its own, like the check that finishes a run, never runs custom tasks.
            let request = mode == .check
                ? try ProvisioningRequest(jobID: id, plan: plan, repository: repository, target: target, dependencyDigest: admission.dependencyDigest,
                    mode: .check, tasks: [], includeTasksInCheck: false)
                : try ProvisioningRequest(jobID: id, plan: plan, repository: repository, target: target, dependencyDigest: admission.dependencyDigest,
                    mode: mode, inputLeaseID: mode == .apply ? inputLeaseID : nil)
            previews[id] = .init(workflowID: id, request: request, transport: admission)
            var row = rows[id]!; row.reviewDigest = request.reviewIdentity; row.stage = .readyForReview; row.sequence += 1; try save(row)
        } catch { await fail(id, error: error) }
    }
    private func waitSSH(_ id: UUID, target: GuestBinding, timeout: Duration) async throws {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            try current(id)
            if case .ready = try await manager.provisioningSSHAdmission(target) { try current(id); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ProvisioningServiceFailure.timedOut
    }
    func prepared(_ id: UUID) async throws -> ProvisioningPreparedJob {
        _ = try await wait(id)
        guard let value = previews[id], [.readyForReview, .readyForCheck].contains(rows[id]?.stage) else { throw ProvisioningServiceFailure.reviewRequired }
        return value
    }
    @discardableResult
    func approve(_ id: UUID, approval: ProvisioningApproval) async throws -> ProvisioningWorkflowSnapshot {
        try enabled()
        guard var row = rows[id], row.reviewDigest == approval.reviewIdentity else { throw ProvisioningServiceFailure.reviewRequired }
        if row.applyJobID != nil {
            // A repeat while the run is in progress (a double-click) observes it.
            // A finished run is never returned as if this approval started it.
            guard row.stage.inProgress else { throw ProvisioningServiceFailure.alreadyRun }
            return row.snapshot
        }
        guard let value = previews[id] else { throw ProvisioningServiceFailure.reviewRequired }
        guard rows[id]?.stage == .readyForReview else { throw ProvisioningServiceFailure.reviewRequired }
        try current(id)
        row.applyJobID = value.request.jobID; row.stage = .running; row.cleanupRequired = true; row.sequence += 1
        // Publish acceptance before the first await; duplicate approvals can
        // only observe this marker, never schedule another registration task.
        do { try save(row) }
        catch {
            await manager.setProvisioningWorkflowHold(id, vmID: row.vmID, required: true)
            await fail(id, error: error)
            throw error
        }
        await manager.setProvisioningWorkflowHold(id, vmID: row.vmID, required: true)
        original[id] = value
        tasks[id] = Task.detached { await self.runOwned(id, prepared: value, approval: approval, check: false) }
        return row.snapshot
    }
    private func runOwned(_ id: UUID, prepared: ProvisioningPreparedJob, approval: ProvisioningApproval, check: Bool) async {
        var inertRetirementAttempted = false
        do {
            try current(id)
            try await coordinator.registerHelperWorker(prepared.request, approval: approval, launcher: environment.launcher, transport: prepared.transport)
            if cancelled.contains(id) {
                inertRetirementAttempted = true
                _ = try await coordinator.abandonPreparedWorker(prepared.request.jobID)
                try update(id, stage: .cancelled, risk: false)
                await manager.setProvisioningWorkflowHold(id, vmID: prepared.request.target.vmID, required: false)
                busyID = nil; return
            }
            try current(id)
            preparations.removeValue(forKey: id) // Consumed by exact coordinator lease.
            try await coordinator.activateHelperWorker(prepared.request, approval: approval, dispatcher: environment.launcher)
            if cancelled.contains(id) { try await coordinator.cancel(prepared.request.jobID) }
            let result = try await coordinator.wait(prepared.request.jobID)
            if result.cleanupRequired {
                try update(id, stage: .cleanupRequired, failure: workflowFailure(result), risk: true)
            } else {
                unconfirmedExits.insert(id)
                guard let record = try jobs.load().first(where: { $0.jobID == prepared.request.jobID }), let helper = record.helperIdentity,
                      await environment.launcher.waitForExit(jobID: record.jobID, identity: helper, timeout: .seconds(5)) else { throw ProvisioningServiceFailure.unavailable }
                unconfirmedExits.remove(id)
                let stage: ProvisioningWorkflowStage
                switch result.state {
                case .succeeded: stage = .succeeded
                case .checked: stage = check ? .succeeded : .checked
                case .restartRequired: stage = .restartRequired
                case .cancelled: stage = .cancelled
                default: stage = .failed
                }
                try update(id, stage: stage, failure: stage == .failed ? workflowFailure(result) : nil, risk: false)
                await manager.setProvisioningWorkflowHold(id, vmID: result.vmID, required: false)
            }
            if rows[id]?.stage != .restartRequired { busyID = nil }
        } catch {
            // Shutdown can also win between registration's lease release and
            // activation. Only a never-activated original worker may be retired;
            // any lost acknowledgement/exit or accepted activation retains risk.
            if !inertRetirementAttempted { _ = try? await coordinator.abandonPreparedWorker(prepared.request.jobID) }
            await fail(id, error: error)
        }
    }
    private func workflowFailure(_ result: ProvisioningJobSnapshot) -> ProvisioningWorkflowFailure {
        if result.engineFailure == .systemUpdateFailed { return .systemUpdateFailed }
        if result.failure == .helperUnavailable { return .helperUnavailable }
        return .childFailed
    }
    func restartReview(_ id: UUID) throws -> ProvisioningRestartReview {
        guard let row = rows[id], row.stage == .restartRequired, let review = row.reviewDigest, !row.cleanupRequired else { throw ProvisioningServiceFailure.reviewRequired }
        if let existing = restartReviews[id] { return existing }
        let value = ProvisioningRestartReview(workflowID: id, restartID: row.restartID ?? UUID(), originalSessionID: row.originalSessionID, reviewDigest: review)
        restartReviews[id] = value; return value
    }
    @discardableResult
    func approveRestart(_ review: ProvisioningRestartReview, identity: String, timeout: Duration = .seconds(180)) async throws -> ProvisioningWorkflowSnapshot {
        try enabled()
        guard identity == (try review.identity), var row = rows[review.workflowID], row.reviewDigest == review.reviewDigest,
              row.originalSessionID == review.originalSessionID, timeout > .zero, timeout <= .seconds(300), !row.cleanupRequired else { throw ProvisioningServiceFailure.reviewRequired }
        if let previous = row.restartID { guard previous == review.restartID, row.restartReviewDigest == identity else { throw ProvisioningJobFailure.jobConflict }; return row.snapshot }
        try current(review.workflowID)
        guard let prepared = original[row.id], let jobID = row.applyJobID, row.stage == .restartRequired else { throw ProvisioningServiceFailure.reviewRequired }
        row.restartID = review.restartID; row.restartReviewDigest = identity; row.stage = .waitingForExit; row.sequence += 1; try save(row)
        do {
            let id = row.id
            let lease = try await coordinator.beginRestart(jobID: jobID, workflowID: id, target: prepared.request.target) { [weak self] in await self?.cancelForLifecycle(id) }
            restarts[id] = lease
            tasks[id] = Task.detached { await self.restartOwned(id, lease: lease, timeout: timeout) }
            return row.snapshot
        } catch { await fail(row.id, error: error); throw error }
    }
    private func restartOwned(_ id: UUID, lease: ProvisioningRestartLease, timeout: Duration) async {
        let end = ContinuousClock.now + timeout
        do {
            while ContinuousClock.now < end {
                try current(id)
                if let sessionID = try await coordinator.continueRestart(lease) {
                    try current(id)
                    var row = rows[id]!; row.newSessionID = sessionID; row.stage = .waitingForRebind; row.sequence += 1; try save(row); return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw ProvisioningServiceFailure.timedOut
        } catch { await fail(id, error: error) }
    }
    func prepareRebind(_ id: UUID, target: GuestBinding, timeout: Duration = .seconds(180)) async throws -> ProvisioningPreparedJob {
        try enabled(); try current(id)
        if rows[id]?.stage == .readyForCheck, let prepared = previews[id], prepared.request.target == target { return prepared }
        guard let row = rows[id], row.stage == .waitingForRebind, row.newSessionID == target.sessionID, !rebindInFlight.contains(id),
              let old = original[id], target.vmID == old.request.target.vmID, target.owner == old.request.target.owner,
              target.ownerUID == old.request.target.ownerUID, target.hostKeyDigest == old.request.target.hostKeyDigest,
              timeout > .zero, timeout <= .seconds(300) else { throw ProvisioningServiceFailure.reviewRequired }
        rebindInFlight.insert(id)
        let task = Task.detached { await self.prepareRebindOwned(id, target: target, timeout: timeout) }
        tasks[id] = task; await task.value
        guard rows[id]?.stage == .readyForCheck, let value = previews[id] else { throw ProvisioningServiceFailure.interrupted }
        return value
    }
    private func prepareRebindOwned(_ id: UUID, target: GuestBinding, timeout: Duration) async {
        defer { rebindInFlight.remove(id) }
        do {
            guard let row = rows[id], row.stage == .waitingForRebind, let old = original[id] else { throw ProvisioningServiceFailure.interrupted }
            try await waitSSH(id, target: target, timeout: timeout)
            let report = try await environment.dependencies.inspect(); try current(id)
            let admission = try await manager.admitProvisioningTransport(target: target, report: report, policy: environment.transportPolicy)
            try current(id); try await authority.admit(admission); try current(id)
            let archive = try coordinatorArchive(old.request)
            try ProvisioningSourceRetention.admit(archive, into: sourceDirectory)
            let storage = try ProvisioningPrivateInputTree(archive: archive, parent: sourceDirectory)
            let plan = try SetupPlanner.plan(repository: storage.directory, manifest: old.request.plan.manifestPath)
            guard plan.identity == row.planDigest, plan.snapshot.identity == row.inputDigest else { throw ProvisioningServiceFailure.reviewRequired }
            let request = try ProvisioningRequest(jobID: row.checkJobID ?? UUID(), plan: plan, repository: storage.directory, target: target,
                dependencyDigest: admission.dependencyDigest, mode: .check, tasks: [], includeTasksInCheck: false)
            try current(id)
            sources[id] = storage
            let value = ProvisioningPreparedJob(workflowID: id, request: request, transport: admission); previews[id] = value
            var latest = rows[id]!; latest.checkJobID = request.jobID; latest.checkReviewDigest = request.reviewIdentity; latest.stage = .readyForCheck; latest.sequence += 1; try save(latest)
            return
        } catch { await fail(id, error: error) }
    }
    private func coordinatorArchive(_ request: ProvisioningRequest) throws -> FrozenInputsArchive {
        try .init(privateArchive: request.plan.snapshot.privateArchive(), expectedIdentity: request.plan.snapshot.identity)
    }
    func rebindReview(_ id: UUID) throws -> ProvisioningRebindReview {
        guard let row = rows[id], row.stage == .readyForCheck, let restartID = row.restartID, let sessionID = row.newSessionID, let review = row.checkReviewDigest else { throw ProvisioningServiceFailure.reviewRequired }
        return .init(workflowID: id, restartID: restartID, newSessionID: sessionID, requestReviewDigest: review)
    }
    @discardableResult
    func approveRebind(_ review: ProvisioningRebindReview, identity: String) async throws -> ProvisioningWorkflowSnapshot {
        try enabled()
        guard identity == (try review.identity), let row = rows[review.workflowID], row.restartID == review.restartID, row.newSessionID == review.newSessionID,
              row.checkReviewDigest == review.requestReviewDigest else { throw ProvisioningServiceFailure.reviewRequired }
        if row.checkActivationID != nil { return row.snapshot }
        try current(review.workflowID)
        guard let value = previews[row.id], value.request.reviewIdentity == review.requestReviewDigest, let lease = restarts[row.id] else { throw ProvisioningServiceFailure.reviewRequired }
        guard row.stage == .readyForCheck else { throw ProvisioningServiceFailure.reviewRequired }
        var accepted = rows[row.id]!
        accepted.checkActivationID = UUID(); accepted.stage = .checking; accepted.cleanupRequired = true; accepted.sequence += 1
        do {
            try save(accepted)
            await manager.setProvisioningWorkflowHold(row.id, vmID: row.vmID, required: true)
            try await coordinator.authorizeRestartCheck(lease, jobID: value.request.jobID, sessionID: review.newSessionID)
            try current(row.id)
            tasks[row.id] = Task.detached { await self.runOwned(row.id, prepared: value, approval: .init(reviewIdentity: value.request.reviewIdentity), check: true) }
            return rows[row.id]!.snapshot
        } catch {
            await fail(row.id, error: error)
            throw error
        }
    }
    public func cancel(_ id: UUID) async throws {
        guard let row = rows[id] else { throw ProvisioningServiceFailure.unknownWorkflow }
        guard row.stage.unfinished || row.stage == .restartRequired else { return }
        cancelled.insert(id)
        if [.running, .checking].contains(rows[id]?.stage) {
            if let child = rows[id]?.stage == .checking ? rows[id]?.checkJobID : rows[id]?.applyJobID { try? await coordinator.cancel(child) }
            return // The owned registration/execution task resolves cleanup.
        }
        tasks[id]?.cancel()
        await fail(id, error: ProvisioningServiceFailure.interrupted)
    }
    private func cancelForLifecycle(_ id: UUID) async { try? await cancel(id) }
    private func fail(_ id: UUID, error: any Error) async {
        guard let row = rows[id] else { return }
        let childID = row.stage == .checking ? row.checkJobID : row.applyJobID
        let childRisk = if let childID { await coordinator.status(childID)?.cleanupRequired ?? false } else { false }
        let risk = childRisk || unconfirmedExits.contains(id) || (failed && row.cleanupRequired)
        let failure: ProvisioningWorkflowFailure = error as? ProvisioningServiceFailure == .timedOut ? (row.restartID == nil ? .sshTimeout : .restartTimeout) :
            cancelled.contains(id) ? .cancelled : error as? ProvisioningJobFailure == .sourceChanged ? .sourceChanged :
            error as? ProvisioningJobFailure == .helperUnavailable ? .helperUnavailable : .childFailed
        try? update(id, stage: risk ? .cleanupRequired : cancelled.contains(id) ? .cancelled : .failed, failure: failure, risk: risk)
        if let lease = preparations.removeValue(forKey: id) { await coordinator.endPreparation(lease) }
        if let lease = restarts.removeValue(forKey: id) { await coordinator.cancelRestart(lease) }
        await manager.setProvisioningWorkflowHold(id, vmID: row.vmID, required: risk)
        if busyID == id { busyID = nil }
    }
    func closeForReopen() async throws {
        guard actionWorkflowsInFlight.isEmpty, reviewOperations.isEmpty, draftCaptures.isEmpty, rebindInFlight.isEmpty, tasks.keys.allSatisfy({ id in ![.running, .checking, .waitingForSSH, .waitingForExit].contains(rows[id]?.stage) }) else { throw ProvisioningServiceFailure.busy }
        let pendingPreparations = preparations; preparations.removeAll()
        for lease in pendingPreparations.values { await coordinator.endPreparation(lease) }
        let pendingRestarts = restarts; restarts.removeAll()
        for lease in pendingRestarts.values { await coordinator.cancelRestart(lease) }
        try await coordinator.closeForReopen(); workflows.close(); closed = true; actionPreparations.removeAll(); actionContexts.removeAll(); actionSubmissions.removeAll(); drafts.removeAll(); retries.removeAll(); creations.removeAll(); applyPreparations.removeAll(); applyReviews.removeAll(); applySubmissions.removeAll(); previews.removeAll(); original.removeAll(); sources.removeAll(); tasks.removeAll()
    }
    /// Explicit recovery requires live original resource admission and an injected
    /// adapter. A fresh process with an empty launcher still cannot prove the
    /// original worker stopped/fenced; no disk row can replace that authority.
    func recover(_ id: UUID, admission: ProvisioningTransportAdmission, adapter: any ProvisioningGuestAdapter) async throws -> ProvisioningWorkflowSnapshot {
        try enabled()
        guard busyID == nil, let row = rows[id], row.cleanupRequired else { throw ProvisioningServiceFailure.reviewRequired }
        busyID = id; defer { busyID = nil }
        let candidates = [row.checkJobID, row.applyJobID].compactMap { $0 }
        var childID: UUID?
        for candidate in candidates where await coordinator.status(candidate)?.cleanupRequired == true { childID = candidate; break }
        guard let childID else { throw ProvisioningServiceFailure.unavailable }
        try await authority.admit(admission)
        try await coordinator.recover(childID, target: admission.target, adapter: adapter)
        let result = try await coordinator.wait(childID)
        guard !result.cleanupRequired else { return rows[id]!.snapshot }
        guard let record = try jobs.load().first(where: { $0.jobID == childID }), let identity = record.helperIdentity,
              await environment.launcher.waitForExit(jobID: childID, identity: identity, timeout: .seconds(5)) else { throw ProvisioningServiceFailure.unavailable }
        try update(id, stage: .interrupted, failure: .processInterrupted, risk: false)
        await manager.setProvisioningWorkflowHold(id, vmID: row.vmID, required: false)
        return rows[id]!.snapshot
    }
    /// Issue #24, after an acknowledged review: release a stopped guest's cleanup
    /// hold. Jobs are saved first, then every cleanup-bound row for the VM, then
    /// the in-memory holds clear. A failed write leaves the hold in place.
    func releaseCleanupHold(_ id: UUID) async throws -> ProvisioningWorkflowSnapshot {
        try enabled()
        guard busyID == nil, let row = rows[id], row.cleanupRequired else { throw ProvisioningServiceFailure.reviewRequired }
        let vmID = row.vmID
        try await manager.requireProvisioningHoldReleasable(vmID)
        try enabled()
        guard busyID == nil, rows[id]?.cleanupRequired == true else { throw ProvisioningServiceFailure.reviewRequired }
        busyID = id; defer { busyID = nil }
        _ = try await coordinator.releaseUnverifiedCleanup(vmID: vmID)
        var updated = rows
        for (key, var value) in rows where value.vmID == vmID && value.cleanupRequired {
            guard value.sequence < UInt64(Int64.max) - 1 else { throw ProvisioningJobFailure.journalUnavailable }
            value.cleanupRequired = false; value.cleanupRelease = .unverified; value.sequence += 1
            if ![.interrupted, .failed, .cancelled].contains(value.stage) { value.stage = .interrupted; value.failure = value.failure ?? .processInterrupted }
            updated[key] = value
        }
        do { try workflows.save(Array(updated.values)) }
        catch { failed = true; throw ProvisioningJobFailure.journalUnavailable }
        rows = updated
        try await manager.releaseProvisioningHold(vmID)
        return rows[id]!.snapshot
    }
    func retention() throws -> ProvisioningRetentionReport { try artifacts.retentionReport(records: jobs.load()) }
}
