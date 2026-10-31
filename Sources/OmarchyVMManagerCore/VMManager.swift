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
    }

    private let runtime: any VMRuntime
    private let applicationSupport: URL
    private var profiles: [VMProfile]
    private var states: [UUID: VMState] = [:]
    private var failures: [UUID: VMFailure] = [:]
    private var notices: [UUID: String] = [:]
    private var sessions: [UUID: Session] = [:]

    public init(runtime: any VMRuntime, profiles: [VMProfile], applicationSupport: URL) {
        self.runtime = runtime
        self.profiles = profiles
        self.applicationSupport = applicationSupport
    }

    public func snapshots() -> [VMSnapshot] {
        profiles.map {
            VMSnapshot(profile: $0, state: states[$0.id] ?? .stopped,
                       sessionID: sessions[$0.id]?.id, lastFailure: failures[$0.id], notice: notices[$0.id])
        }
    }

    public var activeSessionCount: Int { sessions.count }
    public var allocatedMemoryMiB: Int {
        profiles.filter { sessions[$0.id] != nil }.reduce(0) { $0 + $1.memoryMiB }
    }

    public func start(_ vmID: UUID) throws {
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
        states[vmID] = .validating
        failures[vmID] = nil
        notices[vmID] = nil
        let sessionID = UUID()
        let (events, continuation) = AsyncStream<VMRuntimeEvent>.makeStream()
        sessions[vmID] = Session(id: sessionID, root: root, events: continuation)
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

    public func beginApplicationShutdown() -> Bool {
        for vmID in Array(sessions.keys) { shutDown(vmID) }
        return sessions.isEmpty
    }

    func receive(_ event: VMRuntimeEvent, vmID: UUID, sessionID: UUID) {
        guard let session = sessions[vmID], session.id == sessionID else { return }
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
            if states[vmID] != .stopping { states[vmID] = .running }
        case .stopping:
            states[vmID] = .stopping
        case .error(let error):
            failures[vmID] = VMFailure(code: error.reportedCode, message: error.message)
        case .exited(let status):
            if failures[vmID] == nil, status != 0 {
                failures[vmID] = VMFailure(code: "helper-exit-\(status)", message: "The helper exited with status \(status).")
            }
            session.events.finish()
            sessions[vmID] = nil
            if let failure = failures[vmID] { states[vmID] = .failed(failure) }
            else { states[vmID] = .stopped }
        }
    }

    private static func failure(_ error: any Error) -> VMFailure {
        if let failure = error as? VMFailure { return failure }
        if let error = error as? VMRunError { return VMFailure(code: error.reportedCode, message: error.message) }
        return VMFailure(code: "start-failed", message: error.localizedDescription)
    }
}
