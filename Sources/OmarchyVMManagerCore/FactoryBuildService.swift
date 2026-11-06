import Darwin
import DevVMProvisioningCore
import Foundation

public struct FactoryBuildReview: Codable, Sendable {
    public let id: UUID
    public let plan: FactoryBuildPlan
    public let availableBytes: Int64
    public let context: String
    public init(id: UUID, plan: FactoryBuildPlan, availableBytes: Int64, context: String) { self.id = id; self.plan = plan; self.availableBytes = availableBytes; self.context = context }
}
public struct FactoryBuildJob: Codable, Sendable, Identifiable {
    public let id: UUID
    public let plan: FactoryBuildPlan
    public var stage: FactoryBuildStage
    public let createdAt: Date
    public var finishedAt: Date?
    public var failure: String?
    public var factory: FactoryIdentity?
    public var active: Bool { [.preparing, .downloading, .packages, .image, .verifying, .importing].contains(stage) }
    public var cleanupRequired: Bool { stage == .cleanupRequired }
    public init(id: UUID, plan: FactoryBuildPlan, stage: FactoryBuildStage, createdAt: Date = Date(), finishedAt: Date? = nil, failure: String? = nil, factory: FactoryIdentity? = nil) {
        self.id = id; self.plan = plan; self.stage = stage; self.createdAt = createdAt; self.finishedAt = finishedAt; self.failure = failure; self.factory = factory
    }
}
public protocol FactoryBuildControlling: Sendable {
    var enabled: Bool { get }
    func jobs() async throws -> [FactoryBuildJob]
    func review(name: String, sizeGiB: Int) async throws -> FactoryBuildReview
    func start(reviewID: UUID) async throws -> FactoryBuildJob
    func cancel(_ id: UUID) async throws
    func recover(_ id: UUID) async throws
    func output(_ id: UUID, after sequence: UInt64) async throws -> FactoryBuildOutputPage
    @discardableResult func cancelAndWait() async -> Bool
    func resumeAfterCancelledQuit() async
}
public struct FactoryBuildInspection: Sendable {
    public let admission: FactoryDockerAdmission
    public let availableBytes: Int64
    public init(admission: FactoryDockerAdmission, availableBytes: Int64) { self.admission = admission; self.availableBytes = availableBytes }
}
public protocol FactoryBuildEnvironment: Sendable {
    func inspect(root: URL) async throws -> FactoryBuildInspection
    func build(plan: FactoryBuildPlan, id: UUID, root: URL, admission: FactoryDockerAdmission, output: FactoryBuildOutput, progress: @escaping @Sendable (FactoryBuildStage) async throws -> Void) async throws -> URL
    func prepareAndImport(output: URL, plan: FactoryBuildPlan, id: UUID, root: URL) async throws -> FactoryIdentity
    func cleanup(id: UUID, admission: FactoryDockerAdmission) async throws
}

/// App/CLI share this service. Journal contains fixed typed metadata, never
/// terminal output, commands, credentials or replayable build authorization.
public actor FactoryBuildService: FactoryBuildControlling {
    private struct Record: Codable { var format = 1; var job: FactoryBuildJob; let admission: FactoryDockerAdmission }
    public nonisolated let enabled: Bool
    private let root: URL
    private let environment: any FactoryBuildEnvironment
    private var loaded = false
    private var records: [UUID: Record] = [:]
    private var outputs: [UUID: FactoryBuildOutput] = [:]
    private var pending: (FactoryBuildReview, FactoryDockerAdmission)?
    private var task: Task<Void, Never>?
    private var recovering = false
    private(set) var admissionSuspended = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var inspections: [UUID: Task<FactoryBuildInspection, any Error>] = [:]
    private var reviewGeneration = UUID()
    private var lockFD: Int32 = -1
    public init(applicationSupport: URL, environment: any FactoryBuildEnvironment) {
        enabled = AppChannel.current == .development
        root = ManagerStorage(applicationSupport: applicationSupport).directory.appendingPathComponent("FactoryBuilds")
        self.environment = environment
    }
    init(fixtureRoot: URL, environment: any FactoryBuildEnvironment) { enabled = true; root = fixtureRoot; self.environment = environment }
    deinit { if lockFD >= 0 { close(lockFD) } }
    private var jobsRoot: URL { root.appendingPathComponent("Jobs") }
    private var journal: URL { root.appendingPathComponent("Records") }
    private func load(refresh: Bool = false) throws {
        guard enabled else { throw VMFailure(code: "factory-build-disabled", message: "Factory building is available in Dev.") }
        if loaded && !refresh { return }
        try PrivateFiles.directory(root, create: true); try PrivateFiles.directory(jobsRoot, create: true); try PrivateFiles.directory(journal, create: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: journal.path)
        guard names.count <= 128 else { throw FactoryBuildFailure.invalidRequest }
        var found: [UUID: Record] = [:]
        for name in names {
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))), name == id.uuidString + ".json" else { throw FactoryBuildFailure.invalidRequest }
            let bytes = try PrivateFiles.read(journal.appendingPathComponent(name))
            let parsed = try PlainDataParser.parse(bytes, format: .json)
            var record = try JSONDecoder().decode(Record.self, from: bytes)
            guard record.format == 1, record.job.id == id, parsed == (try PlainDataParser.parse(helperJSON(record), format: .json)) else { throw FactoryBuildFailure.invalidRequest }
            _ = try FactoryBuildPlan(name: record.job.plan.name, sizeGiB: record.job.plan.sizeGiB)
            if record.job.active { record.job.stage = .cleanupRequired; record.job.failure = "interrupted" }
            found[id] = record
        }
        // A removed record cannot erase a cleanup hold or authorize new work.
        guard Set(records.keys).isSubset(of: Set(found.keys)) else { throw FactoryBuildFailure.invalidRequest }
        records = found; loaded = true
    }
    private func write(_ record: Record) throws {
        try PrivateFiles.write(helperJSON(record), name: record.job.id.uuidString + ".json", in: journal)
        records[record.job.id] = record
    }
    public func jobs() throws -> [FactoryBuildJob] { try load(); return records.values.map(\.job).sorted { $0.createdAt > $1.createdAt } }
    public func review(name: String = "Lean Omarchy", sizeGiB: Int = 20) async throws -> FactoryBuildReview {
        try load()
        guard task == nil, !recovering, !admissionSuspended else { throw FactoryBuildFailure.busy }
        try acquireLock()
        do { try load(refresh: true) } catch { releaseLock(); throw error }
        releaseLock()
        guard records.count < 128, !records.values.contains(where: { $0.job.cleanupRequired }) else { throw FactoryBuildFailure.busy }
        let plan = try FactoryBuildPlan(name: name, sizeGiB: sizeGiB)
        let generation = UUID(); reviewGeneration = generation; pending = nil
        let probe = Task { [environment, root = jobsRoot] in
            let value = try await environment.inspect(root: root)
            try Task.checkCancellation()
            return value
        }
        inspections[generation] = probe
        defer { inspections.removeValue(forKey: generation) }
        let inspection = try await withTaskCancellationHandler {
            try await probe.value
        } onCancel: { probe.cancel() }
        guard inspection.availableBytes >= plan.minimumArtifactBytes else { throw FactoryBuildFailure.insufficientSpace }
        try Task.checkCancellation()
        guard task == nil, !recovering, !admissionSuspended, reviewGeneration == generation else { throw FactoryBuildFailure.busy }
        let review = FactoryBuildReview(id: UUID(), plan: plan, availableBytes: inspection.availableBytes, context: inspection.admission.context)
        pending = (review, inspection.admission)
        return review
    }
    public func start(reviewID: UUID) async throws -> FactoryBuildJob {
        try load()
        if let existing = records[reviewID] { return existing.job }
        guard task == nil, !recovering, !admissionSuspended else { throw FactoryBuildFailure.busy }
        guard let (review, admission) = pending, review.id == reviewID else { throw VMFailure(code: "factory-build-review", message: "The build preview has changed. Check readiness again before starting.") }
        try acquireLock()
        var handedToWorker = false
        defer { if !handedToWorker { releaseLock() } }
        // Another controller can finish or acquire a cleanup hold after preview.
        // Admission must use the journal protected by this exact lock.
        try load(refresh: true)
        if let existing = records[reviewID] { return existing.job }
        guard records.count < 128, !records.values.contains(where: { $0.job.cleanupRequired }) else { throw FactoryBuildFailure.busy }
        pending = nil
        let job = FactoryBuildJob(id: review.id, plan: review.plan, stage: .preparing, createdAt: Date())
        try PrivateFiles.directory(jobsRoot.appendingPathComponent(job.id.uuidString), create: true)
        try write(Record(job: job, admission: admission))
        let output = FactoryBuildOutput(); outputs[job.id] = output
        task = Task { await self.run(job.id, output: output) }
        handedToWorker = true
        return job
    }
    private func releaseLock() { if lockFD >= 0 { close(lockFD); lockFD = -1 } }
    private func acquireLock() throws {
        let fd = open(root.appendingPathComponent("build.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FactoryBuildFailure.busy }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o7777 == 0o600, flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw FactoryBuildFailure.busy }
        lockFD = fd
    }
    private func progress(_ id: UUID, _ stage: FactoryBuildStage) throws {
        try Task.checkCancellation()
        guard var record = records[id], record.job.active else { throw FactoryBuildFailure.cancelled }
        record.job.stage = stage; try write(record)
    }
    private func run(_ id: UUID, output: FactoryBuildOutput) async {
        guard var record = records[id] else { return }
        defer { releaseLock(); task = nil }
        do {
            try Task.checkCancellation()
            let current = try await environment.inspect(root: jobsRoot)
            guard current.admission == record.admission else { throw FactoryBuildFailure.engineChanged }
            guard current.availableBytes >= record.job.plan.minimumArtifactBytes else { throw FactoryBuildFailure.insufficientSpace }
            let result = try await environment.build(plan: record.job.plan, id: id, root: jobsRoot, admission: record.admission, output: output) { stage in try await self.progress(id, stage) }
            try progress(id, .importing)
            let factory = try await environment.prepareAndImport(output: result, plan: record.job.plan, id: id, root: jobsRoot)
            record.job.factory = factory; record.job.stage = .succeeded
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? FactoryBuildFailure) == .cancelled
            record.job.stage = (error as? FactoryBuildFailure) == .cleanupRequired ? .cleanupRequired : cancelled ? .cancelled : .failed
            record.job.failure = (error as? FactoryBuildFailure)?.rawValue ?? (cancelled ? "cancelled" : "build-failed")
        }
        record.job.finishedAt = Date()
        do { try write(record) } catch { record.job.stage = .cleanupRequired; record.job.failure = "journal-unavailable"; records[id] = record }
    }
    public func cancel(_ id: UUID) throws {
        try load()
        guard records[id]?.job.active == true, let task else { throw FactoryBuildFailure.invalidRequest }
        task.cancel()
    }
    public func recover(_ id: UUID) async throws {
        try load()
        guard task == nil, !recovering else { throw FactoryBuildFailure.invalidRequest }
        guard !admissionSuspended else { throw FactoryBuildFailure.busy }
        try acquireLock(); recovering = true
        defer {
            recovering = false; releaseLock()
            let waiters = shutdownWaiters; shutdownWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        try load(refresh: true)
        guard var record = records[id], record.job.cleanupRequired else { throw FactoryBuildFailure.invalidRequest }
        // Recovery only reconciles this job's labeled Docker resources. It never
        // resumes a build or imports retained output after an interrupted caller.
        try await environment.cleanup(id: id, admission: record.admission)
        record.job.stage = .failed; record.job.failure = "interrupted-cleanup-verified"; record.job.finishedAt = Date()
        try write(record)
    }
    public func output(_ id: UUID, after sequence: UInt64) throws -> FactoryBuildOutputPage {
        try load()
        guard records[id] != nil else { throw FactoryBuildFailure.invalidRequest }
        return outputs[id]?.page(after: sequence) ?? .init(sequence: 0, bytes: Data(), reset: sequence != 0)
    }
    /// Fence new reviews/starts before awaiting any owned operation. Keep this
    /// fence until process exit, or an explicitly cancelled quit reopens it.
    @discardableResult public func cancelAndWait() async -> Bool {
        admissionSuspended = true; pending = nil; reviewGeneration = UUID()
        let probes = Array(inspections.values)
        for probe in probes { probe.cancel() }
        task?.cancel(); await task?.value
        for probe in probes { _ = try? await probe.value }
        if recovering { await withCheckedContinuation { shutdownWaiters.append($0) } }
        guard enabled else { return true }
        do {
            try load(); try acquireLock()
            defer { releaseLock() }
            try load(refresh: true)
            return !records.values.contains { $0.job.cleanupRequired }
        } catch { return false }
    }
    public func resumeAfterCancelledQuit() {
        guard task == nil, !recovering else { return }
        admissionSuspended = false
    }
}
