import Foundation
import TryOmarchyKitClient

public struct GuestConfigurationPatch: Codable, Equatable, Sendable {
    public var name: String?
    public var memoryMiB: Int?
    public var cpus: Int?
    public var diskGiB: Int?
    public var clipboard: Bool?
    public var immersive: Bool?
    public var ssh: Bool?
    public var ownerDefaults: Bool?
    public var factory: String?
    public var publicKey: String?
    public init(name: String? = nil, memoryMiB: Int? = nil, cpus: Int? = nil, diskGiB: Int? = nil,
                clipboard: Bool? = nil, immersive: Bool? = nil,
                ssh: Bool? = nil, ownerDefaults: Bool? = nil, publicKey: String? = nil, factory: String? = nil) {
        self.name = name; self.memoryMiB = memoryMiB; self.cpus = cpus; self.diskGiB = diskGiB
        self.clipboard = clipboard; self.immersive = immersive
        self.ssh = ssh; self.ownerDefaults = ownerDefaults; self.publicKey = publicKey; self.factory = factory
    }
    public static func decodeStrict(_ data: Data) throws -> Self {
        guard data.count <= 32768, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["name", "memoryMiB", "cpus", "diskGiB", "clipboard", "immersive", "ssh", "ownerDefaults", "publicKey", "factory"]),
              !object.values.contains(where: { $0 is NSNull }) else { throw commandFailure("invalid-config", "Configuration must contain only supported, non-null guest settings.") }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public enum GuestCommand: String, Codable, Sendable { case list, get, create, update, delete, start, stop, restart, pause, resume, wait, factories
    case importFactory = "factory-import"
    case deleteFactory = "factory-delete" }
public enum GuestWaitCondition: String, Codable, Sendable { case running, ssh, stopped, paused }

public struct GuestCommandRequest: Codable, Sendable {
    public var version = 1
    public var requestID = UUID()
    public var command: GuestCommand
    public var selector: String?
    public var config: GuestConfigurationPatch?
    public var start = false
    public var force = false
    public var waitFor: GuestWaitCondition?
    public var timeoutSeconds = 600
    public var details = false
    public init(command: GuestCommand, selector: String? = nil, config: GuestConfigurationPatch? = nil) {
        self.command = command; self.selector = selector; self.config = config
    }
    public func validate() throws {
        guard version == 1, (1...3600).contains(timeoutSeconds),
              selector == nil || (!selector!.isEmpty && selector!.utf8.count <= (command == .importFactory ? 1024 : 255) && !selector!.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })) else {
            throw commandFailure("invalid-request", "Unsupported command version, selector or timeout.")
        }
        guard (command == .list || command == .create || command == .factories) == (selector == nil),
              (command == .create || command == .update) == (config != nil),
              !start || command == .create, !force || command == .stop,
              command != .wait || waitFor != nil,
              waitFor == nil || [.create, .start, .stop, .restart, .wait].contains(command),
              command != .create || waitFor == nil || start,
              command != .stop || waitFor == nil || waitFor == .stopped,
              ![.start, .restart].contains(command) || waitFor != .stopped else {
            throw commandFailure("invalid-request", "Options do not apply to this command.")
        }
        if command == .deleteFactory { try FactoryCatalog.validateDeletionSelector(selector!) }
        if command == .importFactory, selector?.hasPrefix("/") != true { throw FactoryCatalog.invalid("A prepared factory bundle requires an absolute path.") }
        if command == .create, config?.name == nil { throw commandFailure("invalid-config", "A guest name is required.") }
        if command == .update, config?.factory != nil { throw commandFailure("creation-only", "Factory selection is fixed at creation.") }
        if command == .create, let factory = config?.factory, factory != "official", !VMFactorySelection.isDigest(factory) { throw FactoryCatalog.invalid("Select official or an imported manifest SHA-256.") }
        if command == .update, let config {
            guard config.name != nil || config.memoryMiB != nil || config.cpus != nil || config.diskGiB != nil || config.clipboard != nil || config.immersive != nil else { throw commandFailure("invalid-config", "Supply at least one setting to update.") }
            guard config.ssh == nil, config.ownerDefaults == nil, config.publicKey == nil, config.factory == nil else { throw commandFailure("creation-only", "SSH and owner enrollment are chosen at guest creation.") }
        }
    }
    static func decodeStrict(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "requestID", "command", "selector", "config", "start", "force", "waitFor", "timeoutSeconds", "details"]) else { throw commandFailure("invalid-request", "Unknown command fields.") }
        if let config = object["config"] { _ = try GuestConfigurationPatch.decodeStrict(JSONSerialization.data(withJSONObject: config)) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }
}

public struct GuestCommandFailure: Codable, Equatable, Sendable {
    public let code: String; public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}
public struct GuestSSHRecord: Codable, Sendable {
    public let enabled: Bool
    public let status: String
    public let host: String?
    public let port: Int?
    public let user: String?
    public let command: String?
}
public struct GuestNetworkRecord: Codable, Sendable {
    public let mode: String
    public let guestIPs: [String]
    public let hostAddress: String
    public let addressesVerified: Bool
}
public struct GuestCommandRecord: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let protected: Bool
    public let memoryMiB: Int
    public let cpus: Int
    public let diskGiB: Int?
    public let clipboard: Bool
    public let immersive: Bool?
    public let factory: FactoryIdentity?
    public let unattended: Bool
    public let state: String
    public let active: Bool
    public let sessionID: UUID?
    public let phase: String?
    public let percent: Int?
    public let ssh: GuestSSHRecord
    public let network: GuestNetworkRecord
    public let hibernation: GuestHibernationCapability?
    public let experimentalRestoreAvailable: Bool
    public let experimentalSuspendAvailable: Bool
    public let suspension: ExperimentalSuspension.Stage?
    public let suspensionMetadataUnsafe: Bool
    public let error: GuestCommandFailure?
}
public struct GuestCommandResponse: Codable, Sendable {
    public var version = 1
    public var requestID: UUID
    public var ok: Bool
    public var guest: GuestCommandRecord?
    public var guests: [GuestCommandRecord]?
    public var factories: [FactoryIdentity]?
    public var factoryIssues: [FactoryCatalogIssue]?
    public var deletedFactory: FactoryIdentity?
    public var error: GuestCommandFailure?
    public init(requestID: UUID, ok: Bool, guest: GuestCommandRecord? = nil, guests: [GuestCommandRecord]? = nil, error: GuestCommandFailure? = nil, factories: [FactoryIdentity]? = nil, factoryIssues: [FactoryCatalogIssue]? = nil, deletedFactory: FactoryIdentity? = nil) {
        self.requestID = requestID; self.ok = ok; self.guest = guest; self.guests = guests; self.error = error; self.factories = factories; self.factoryIssues = factoryIssues; self.deletedFactory = deletedFactory
    }
}

func commandFailure(_ code: String, _ message: String) -> VMFailure { VMFailure(code: code, message: message) }

public actor GuestCommandService {
    private let manager: VMManager
    private let support: URL
    private let connections: any GuestConnectionChecking
    private var cachedConnections: [UUID: VerifiedGuestConnection] = [:]
    public init(manager: VMManager, applicationSupport: URL, connections: any GuestConnectionChecking = SSHGuestConnectionProbe()) {
        self.manager = manager; support = applicationSupport; self.connections = connections
    }
    public func execute(_ request: GuestCommandRequest) async -> GuestCommandResponse {
        var target: UUID?
        do {
            try Task.checkCancellation()
            try request.validate()
            let deadline = ContinuousClock.now.advanced(by: .seconds(request.timeoutSeconds))
            if request.command == .factories {
                let listing = try await manager.factoryListing()
                return GuestCommandResponse(requestID: request.requestID, ok: true, factories: listing.factories, factoryIssues: listing.issues.isEmpty ? nil : listing.issues)
            }
            if request.command == .importFactory {
                let url = URL(fileURLWithPath: request.selector!)
                return GuestCommandResponse(requestID: request.requestID, ok: true, factories: [try await manager.importFactory(url)])
            }
            if request.command == .deleteFactory {
                let identity = try await manager.deleteFactory(request.selector!)
                return GuestCommandResponse(requestID: request.requestID, ok: true, deletedFactory: identity)
            }
            if request.command == .list {
                let records = await manager.snapshots().map { record($0) }
                return GuestCommandResponse(requestID: request.requestID, ok: true, guests: records)
            }
            if request.command == .create {
                let c = request.config!
                target = try await manager.create(name: c.name!, memoryMiB: c.memoryMiB ?? 4096, cpus: c.cpus ?? 4,
                    diskGiB: c.diskGiB ?? 64,
                    clipboardEnabled: c.clipboard ?? true, immersiveMode: c.immersive ?? false, sshEnabled: c.ssh ?? true,
                    publicKey: c.publicKey, useOwnerDefaults: c.ownerDefaults, factory: c.factory ?? "official")
                if request.start { try await manager.start(target!, launchIntent: .background) }
            } else {
                target = try await resolve(request.selector!)
                switch request.command {
                case .get, .wait: break
                case .update: try await manager.update(target!, configuration: request.config!)
                case .delete:
                    let review = try await manager.deletionRequest(target!)
                    try await manager.delete(target!, confirmed: true, expectedIdentity: review?.expectedIdentity)
                    cachedConnections[target!] = nil
                    return GuestCommandResponse(requestID: request.requestID, ok: true)
                case .pause:
                    cachedConnections[target!] = nil
                    try await manager.pause(target!, timeout: .seconds(min(10, request.timeoutSeconds)))
                case .resume:
                    cachedConnections[target!] = nil
                    try await manager.resume(target!, timeout: .seconds(min(10, request.timeoutSeconds)))
                case .start: try await manager.start(target!, launchIntent: .background)
                case .stop:
                    if request.force { try await manager.forceStop(target!, confirmed: true) }
                    else { await manager.shutDown(target!) }
                case .restart:
                    await manager.shutDown(target!)
                    try await wait(target!, condition: .stopped, deadline: deadline)
                    try await manager.start(target!, launchIntent: .background)
                default: break
                }
            }
            if let condition = request.waitFor { try await wait(target!, condition: condition, deadline: deadline) }
            if request.details || request.waitFor == .ssh { try await refreshConnection(target!) }
            let snapshot = try await snapshot(target!)
            return GuestCommandResponse(requestID: request.requestID, ok: true, guest: record(snapshot))
        } catch {
            let failure = error as? VMFailure ?? commandFailure("command-failed", "The command could not finish.")
            let current: GuestCommandRecord?
            if let target, let snapshot = try? await snapshot(target) { current = record(snapshot) } else { current = nil }
            return GuestCommandResponse(requestID: request.requestID, ok: false, guest: current, error: GuestCommandFailure(code: failure.code, message: failure.message))
        }
    }
    private func resolve(_ selector: String) async throws -> UUID {
        let all = await manager.snapshots()
        if let id = UUID(uuidString: selector), all.contains(where: { $0.id == id }) { return id }
        let matches = all.filter { $0.profile.name == selector }
        guard matches.count == 1 else {
            throw commandFailure(matches.isEmpty ? "unknown-vm" : "ambiguous-vm", matches.isEmpty ? "No guest matches this UUID or exact name." : "Several guests have that name. Use a full UUID.")
        }
        return matches[0].id
    }
    private func snapshot(_ id: UUID) async throws -> VMSnapshot {
        guard let value = await manager.snapshots().first(where: { $0.id == id }) else { throw commandFailure("unknown-vm", "The guest no longer exists.") }
        return value
    }
    private func wait(_ id: UUID, condition: GuestWaitCondition, deadline: ContinuousClock.Instant) async throws {
        let initial = try await snapshot(id)
        let session = initial.sessionID
        if condition != .stopped, session == nil { throw commandFailure("not-running", "Start this guest before waiting for readiness.") }
        if condition == .ssh, initial.profile.ssh == nil { throw commandFailure("ssh-disabled", "SSH is disabled for this guest.") }
        while true {
            try Task.checkCancellation()
            let value = try await snapshot(id)
            if condition == .stopped, value.sessionID == nil { return }
            guard value.sessionID == session else { throw commandFailure("session-changed", "The guest session changed before this wait completed.") }
            if condition != .stopped {
                guard value.state != .stopping else { throw commandFailure("guest-stopping", "The guest is stopping; wait for its exit before starting it again.") }
                if let failure = value.lastFailure { throw failure }
                if condition == .running, value.state == .running { return }
                if condition == .paused, value.state == .paused { return }
                if condition == .ssh {
                    guard value.state != .paused, value.state != .hostSleeping, value.state != .pausing, value.state != .resuming, value.state != .executionUnknown else { throw commandFailure("guest-paused", "Resume the guest before waiting for SSH.") }
                    if case .ready = value.sshReadiness { return }
                    if case .failed(let message) = value.sshReadiness { throw commandFailure("ssh-unavailable", message) }
                }
            }
            guard ContinuousClock.now < deadline else { throw commandFailure("wait-timeout", "The wait timed out. The guest was left in its current state; retry get or wait using its UUID.") }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
    private func refreshConnection(_ id: UUID) async throws {
        let value = try await snapshot(id)
        guard let session = value.sessionID, value.state == .running, case .ready(let user, _) = value.sshReadiness else { cachedConnections[id] = nil; return }
        let request = VMStartRequest(profile: value.profile, storageRoot: ManagerStorage(applicationSupport: support).root(for: value.profile), sessionID: session)
        cachedConnections[id] = nil
        let info = try await connections.check(request, user: user)
        guard info.vmID == id, info.sessionID == session, info.user == user, info.addresses.count <= 64, info.addresses.allSatisfy(SSHGuestConnectionProbe.validAddress),
              try await snapshot(id).sessionID == session, try await snapshot(id).state == .running else { throw commandFailure("session-changed", "The guest session changed while checking its connection.") }
        cachedConnections[id] = info
    }
    private func record(_ value: VMSnapshot) -> GuestCommandRecord {
        let ready: Bool
        if case .ready = value.sshReadiness { ready = value.state == .running } else { ready = false }
        if !ready { cachedConnections[value.id] = nil }
        let connection = ready ? cachedConnections[value.id].flatMap { $0.sessionID == value.sessionID ? $0 : nil } : nil
        let state: String
        var phase: String?, percent: Int?
        switch value.state {
        case .stopped: state = "stopped"
        case .validating: state = "validating"
        case .downloading(let p, let n): state = "downloading"; phase = p.rawValue; percent = n
        case .starting(let p, let n): state = "starting"; phase = p.rawValue; percent = n
        case .running: state = "running"
        case .pausing: state = "pausing"
        case .paused: state = "paused"
        case .resuming: state = "resuming"
        case .hostSleeping: state = "host-sleeping"
        case .executionUnknown: state = "execution-unknown"
        case .stopping: state = "stopping"
        case .deleting: state = "deleting"
        case .failed: state = "failed"
        }
        let sshState: String
        var user: String?, command: String?
        switch value.sshReadiness {
        case .disabled: sshState = "disabled"
        case .stopped: sshState = "stopped"
        case .paused: sshState = "paused"
        case .provisioning: sshState = "provisioning"
        case .waitingForOwner: sshState = "waiting-owner"
        case .connecting: sshState = "connecting"
        case .ready(let owner, let line): sshState = "ready"; user = owner; command = line
        case .failed: sshState = "failed"
        }
        return GuestCommandRecord(id: value.id, name: value.profile.name, protected: value.profile.isRetainedPOC,
            memoryMiB: value.profile.memoryMiB, cpus: value.profile.cpus, diskGiB: value.profile.diskGiB,
            clipboard: value.profile.clipboardEnabled,
            immersive: value.profile.immersiveMode, factory: value.profile.factory, unattended: value.profile.ownerSetup != nil, state: state, active: value.sessionID != nil,
            sessionID: value.sessionID, phase: phase, percent: percent,
            ssh: GuestSSHRecord(enabled: value.profile.ssh != nil, status: sshState, host: value.profile.ssh == nil ? nil : "127.0.0.1", port: value.profile.ssh?.hostPort, user: user, command: command),
            network: GuestNetworkRecord(mode: "nat", guestIPs: connection?.addresses ?? [], hostAddress: "127.0.0.1", addressesVerified: connection != nil),
            hibernation: value.hibernation, experimentalRestoreAvailable: value.canRestoreExperimentalSuspension, experimentalSuspendAvailable: value.canAttemptExperimentalSuspend,
            suspension: value.suspension?.stage, suspensionMetadataUnsafe: value.suspensionMetadataUnsafe,
            error: value.lastFailure.map { GuestCommandFailure(code: $0.code, message: $0.message) })
    }
}
