import Foundation
import TryOmarchyKitClient

public actor VMManager {
    private struct Session {
        let id: UUID
        let root: URL
        let events: AsyncStream<VMRuntimeEvent>.Continuation
        var handle: (any VMRuntimeHandle)?
        var shutdownRequested = false
        var forceRequested = false
        var coldStart = false
        var reachedReady = false
    }

    private let runtime: any VMRuntime
    private let applicationSupport: URL
    private var profiles: [VMProfile]
    private var states: [UUID: VMState] = [:]
    private var failures: [UUID: VMFailure] = [:]
    private var notices: [UUID: String] = [:]
    private var sessions: [UUID: Session] = [:]
    private let enforcePOCPolicy: Bool
    private let hostMemoryMiB: Int
    private let logicalCPUs: Int
    private var records: [VMLifecycleRecord] = []
    private let registry: RegistryStore?
    private let trashService: (any VMTrashService)?
    private var storageTransactions: Set<UUID> = []
    private var quitting = false
    private var interruptedDeletions: Set<UUID> = []

    public func eventLog() -> [VMLifecycleRecord] { records }
    public func observation() -> (snapshots: [VMSnapshot], records: [VMLifecycleRecord]) { (snapshots(), records) }

    private func record(_ text: String, vmID: UUID, sessionID: UUID) {
        records.append(VMLifecycleRecord(date: Date(), vmID: vmID, sessionID: sessionID, text: String(text.prefix(4096))))
        if records.count > 300 { records.removeFirst(records.count - 300) }
    }

    public init(runtime: any VMRuntime, profiles: [VMProfile], applicationSupport: URL, enforcePOCPolicy: Bool = false,
                hostMemoryMiB: Int = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
                logicalCPUs: Int = ProcessInfo.processInfo.processorCount,
                registry: RegistryStore? = nil, trashService: (any VMTrashService)? = nil) {
        self.runtime = runtime
        self.profiles = profiles
        self.applicationSupport = applicationSupport
        self.enforcePOCPolicy = enforcePOCPolicy
        self.hostMemoryMiB = hostMemoryMiB
        self.logicalCPUs = logicalCPUs
        self.registry = registry
        self.trashService = trashService
        interruptedDeletions = registry?.pendingDeletions ?? []
        for id in interruptedDeletions {
            let failure = VMFailure(code: "interrupted-deletion", message: "A previous deletion was interrupted. The disk may already be in Trash. Review Delete VM again to finish removing the profile; restore files manually before recovery.")
            states[id] = .failed(failure); failures[id] = failure
        }
    }

    public static func open(runtime: any VMRuntime, applicationSupport: URL, trashService: any VMTrashService) throws -> VMManager {
        let registry = try RegistryStore(applicationSupport: applicationSupport)
        let profiles = try registry.load()
        return VMManager(runtime: runtime, profiles: profiles, applicationSupport: applicationSupport,
                         enforcePOCPolicy: true, registry: registry, trashService: trashService)
    }

    public func create(name: String, memoryMiB: Int, cpus: Int, clipboardEnabled: Bool, immersiveMode: Bool) throws -> UUID {
        guard !quitting, let registry else { throw VMFailure(code: "registry-unavailable", message: "The registry is unavailable or the manager is quitting.") }
        let profile = VMProfile(id: UUID(), name: name, memoryMiB: memoryMiB, cpus: cpus,
                                clipboardEnabled: clipboardEnabled, immersiveMode: immersiveMode)
        try validateResources(profile)
        try registry.save(profiles + [profile])
        profiles.append(profile)
        return profile.id
    }

    public func configure(_ profile: VMProfile) throws {
        try requireEditable(profile.id)
        guard !interruptedDeletions.contains(profile.id) else { throw VMFailure(code: "interrupted-deletion", message: "Finish reviewing the interrupted deletion before configuring this profile.") }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }), let registry,
              profiles[index].createdAt == profile.createdAt else { throw VMFailure(code: "unknown-vm", message: "The VM profile changed or is missing.") }
        try validateResources(profile)
        var edited = profile
        let storage = ManagerStorage(applicationSupport: applicationSupport)
        if PrivateFiles.exists(storage.root(for: edited)) {
            try storage.validate(edited)
            edited.settingsFingerprint = try storage.settingsFingerprint(edited)
        }
        var next = profiles; next[index] = edited
        try registry.save(next)
        profiles = next
    }

    public func deletionRequest(_ id: UUID) throws -> TrashRequest? {
        try requireEditable(id)
        guard let profile = profiles.first(where: { $0.id == id }) else { throw VMFailure(code: "unknown-vm", message: "The VM profile does not exist.") }
        let storage = ManagerStorage(applicationSupport: applicationSupport)
        guard PrivateFiles.exists(storage.root(for: profile)) else { return nil }
        return try TrashRequest(profile: profile, expectedIdentity: storage.deletionIdentity(profile))
    }

    public func delete(_ id: UUID, confirmed: Bool, expectedIdentity: String?) async throws {
        guard confirmed else { throw VMFailure(code: "confirmation-required", message: "Confirm moving this VM to Trash.") }
        try requireEditable(id)
        guard let registry, let profile = profiles.first(where: { $0.id == id }) else { throw VMFailure(code: "registry-unavailable", message: "The registry is unavailable.") }
        let storage = ManagerStorage(applicationSupport: applicationSupport)
        let exists = PrivateFiles.exists(storage.root(for: profile))
        if exists, expectedIdentity == nil { throw VMFailure(code: "review-required", message: "Review the current VM storage before deleting it.") }
        try registry.markDeletion(id)
        interruptedDeletions.insert(id)
        storageTransactions.insert(id); states[id] = .deleting
        defer { storageTransactions.remove(id) }
        do {
            if exists {
                guard let trashService, let expectedIdentity else { throw VMFailure(code: "trash-unavailable", message: "The storage helper is unavailable.") }
                try await trashService.moveToTrash(TrashRequest(profile: profile, expectedIdentity: expectedIdentity))
                guard !PrivateFiles.exists(storage.root(for: profile)) else {
                    throw VMFailure(code: "trash-incomplete", message: "The helper did not move this VM. Its registry entry was retained.")
                }
            } else if expectedIdentity != nil { throw VMFailure(code: "storage-changed", message: "The VM storage changed since confirmation.") }
            else if PrivateFiles.exists(storage.root(for: profile)) { throw VMFailure(code: "storage-changed", message: "VM storage appeared since confirmation.") }
            let next = profiles.filter { $0.id != id }
            try registry.save(next)
            profiles = next; interruptedDeletions.remove(id); states[id] = nil; failures[id] = nil; notices[id] = nil
        } catch {
            if PrivateFiles.exists(storage.root(for: profile)), (try? registry.clearDeletion(id)) != nil { interruptedDeletions.remove(id) }
            let failure = Self.failure(error); states[id] = .failed(failure); failures[id] = failure
            throw failure
        }
    }

    private func requireEditable(_ id: UUID) throws {
        guard !quitting, !POCProfiles.ids.contains(id), sessions[id] == nil, !storageTransactions.contains(id),
              (states[id] ?? .stopped).canStart else {
            throw VMFailure(code: "vm-not-editable", message: "Stop the VM before changing it. Retained POC profiles are protected from configuration changes and deletion.")
        }
    }

    private func validateResources(_ profile: VMProfile) throws {
        try RegistryStore.validate(profile)
        guard profile.cpus <= logicalCPUs, profile.memoryMiB <= hostMemoryMiB - max(4096, hostMemoryMiB / 4) else {
            throw VMFailure(code: "unsupported-resources", message: "The requested CPU or memory allocation exceeds this Mac’s guest budget.")
        }
    }

    public func snapshots() -> [VMSnapshot] {
        profiles.map {
            VMSnapshot(profile: $0, state: states[$0.id] ?? .stopped,
                       sessionID: sessions[$0.id]?.id, lastFailure: failures[$0.id], notice: notices[$0.id])
        }
    }

    public var activeSessionCount: Int { sessions.count }
    public var isIdle: Bool { sessions.isEmpty && storageTransactions.isEmpty }
    public var allocatedMemoryMiB: Int {
        profiles.filter { sessions[$0.id] != nil }.reduce(0) { $0 + $1.memoryMiB }
    }

    public func start(_ vmID: UUID) throws {
        try registry?.checkRevision()
        guard !interruptedDeletions.contains(vmID) else { throw VMFailure(code: "interrupted-deletion", message: "Review the interrupted deletion before launching. Missing storage will not be recreated.") }
        guard !quitting, !storageTransactions.contains(vmID) else { throw VMFailure(code: "transaction-busy", message: "A storage transaction or application shutdown is in progress.") }
        guard let profile = profiles.first(where: { $0.id == vmID }) else {
            throw VMFailure(code: "unknown-vm", message: "The VM profile does not exist.")
        }
        guard sessions[vmID] == nil, (states[vmID] ?? .stopped).canStart else {
            throw VMFailure(code: "already-active", message: "This VM already has an active session.")
        }
        let root = POCProfiles.root(for: profile, applicationSupport: applicationSupport).resolvingSymlinksInPath()
        guard !sessions.values.contains(where: { $0.root == root }) else {
            throw VMFailure(code: "duplicate-root", message: "This storage root is already in use.")
        }
        if enforcePOCPolicy {
            guard !sessions.values.contains(where: { $0.coldStart && !$0.reachedReady }) else {
                throw VMFailure(code: "cold-start-busy", message: "Wait until the first cold start is ready before starting another VM.")
            }
            let activeProfiles = profiles.filter { sessions[$0.id] != nil } + [profile]
            try POCHostPolicy.validate(memoryMiB: activeProfiles.reduce(0) { $0 + $1.memoryMiB },
                                       cpus: activeProfiles.reduce(0) { $0 + $1.cpus },
                                       physicalMemoryMiB: hostMemoryMiB, logicalCPUs: logicalCPUs)
        }
        states[vmID] = .validating
        failures[vmID] = nil
        notices[vmID] = nil
        let sessionID = UUID()
        let (events, continuation) = AsyncStream<VMRuntimeEvent>.makeStream()
        sessions[vmID] = Session(id: sessionID, root: root, events: continuation,
                                 coldStart: !TryOmarchyStorage.hasVM(at: root))
        record("Start requested", vmID: vmID, sessionID: sessionID)
        do {
            if let error = runtime.preflight() { throw error }
            let request = VMStartRequest(profile: profile, storageRoot: root)
            let handle = try runtime.start(request) { continuation.yield($0) }
            sessions[vmID]?.handle = handle
            Task {
                for await event in events {
                    receive(event, vmID: vmID, sessionID: sessionID)
                }
            }
        } catch {
            continuation.finish()
            sessions[vmID] = nil
            let failure = Self.failure(error)
            failures[vmID] = failure
            states[vmID] = .failed(failure)
            record("Start refused: " + failure.message, vmID: vmID, sessionID: sessionID)
            throw failure
        }
    }

    public func shutDown(_ vmID: UUID) {
        guard var session = sessions[vmID], !session.shutdownRequested else { return }
        session.shutdownRequested = true
        sessions[vmID] = session
        states[vmID] = .stopping
        session.handle?.shutDown()
    }

    public func forceStop(_ vmID: UUID, confirmed: Bool) throws {
        guard confirmed else {
            throw VMFailure(code: "confirmation-required", message: "Force Stop can lose unsaved guest work.")
        }
        guard var session = sessions[vmID], !session.forceRequested else { return }
        session.forceRequested = true
        sessions[vmID] = session
        states[vmID] = .stopping
        session.handle?.terminate()
    }

    public func prepareToQuitIfIdle() -> Bool {
        guard isIdle else { return false }
        quitting = true
        return true
    }

    public func beginApplicationShutdown() -> Bool {
        quitting = true
        for vmID in Array(sessions.keys) { shutDown(vmID) }
        return isIdle
    }

    func receive(_ event: VMRuntimeEvent, vmID: UUID, sessionID: UUID) {
        guard let session = sessions[vmID], session.id == sessionID else { return }
        record(Self.describe(event), vmID: vmID, sessionID: sessionID)
        switch event {
        case .progress(let phase, let percent):
            guard states[vmID] != .stopping else { return }
            switch phase {
            case .waitingForDownload, .downloading, .reconnecting, .paused, .verifyingDownload:
                states[vmID] = .downloading(phase: phase, percent: percent)
            default:
                states[vmID] = .starting(phase: phase, percent: percent)
            }
        case .notice(let notice):
            notices[vmID] = notice.message
        case .ready:
            sessions[vmID]?.reachedReady = true
            if states[vmID] != .stopping { states[vmID] = .running }
        case .stopping:
            states[vmID] = .stopping
        case .error(let error):
            failures[vmID] = VMFailure(code: error.reportedCode, message: error.message)
        case .exited(let status):
            if failures[vmID] == nil, status != 0, !session.forceRequested {
                failures[vmID] = VMFailure(code: "helper-exit-\(status)", message: "The helper exited with status \(status).")
            }
            if let failure = failures[vmID] {
                failures[vmID] = VMFailure(code: failure.code, message: failure.message,
                                           diagnostics: session.handle?.recentStandardError ?? "")
            }
            session.events.finish()
            sessions[vmID] = nil
            if let failure = failures[vmID] { states[vmID] = .failed(failure) }
            else { states[vmID] = .stopped }
        }
    }

    private static func describe(_ event: VMRuntimeEvent) -> String {
        switch event {
        case .progress(let phase, let percent): "\(phase.rawValue)" + (percent.map { " \($0)%" } ?? "")
        case .notice(let notice): "Notice: " + notice.message
        case .ready: "Ready"
        case .stopping: "Stopping"
        case .error(let error): "Error [\(error.reportedCode)]: " + error.message
        case .exited(let status): "Exited (\(status))"
        }
    }

    private static func failure(_ error: any Error) -> VMFailure {
        if let failure = error as? VMFailure { return failure }
        if let error = error as? VMRunError { return VMFailure(code: error.reportedCode, message: error.message) }
        return VMFailure(code: "start-failed", message: error.localizedDescription)
    }
}
