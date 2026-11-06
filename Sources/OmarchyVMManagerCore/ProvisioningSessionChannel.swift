import DevVMProvisioningCore
import Foundation

/// Metadata only. The manager validates its live lease; neither endpoint can
/// discover/adopt a guest from a port, PID, file or terminal transcript.
enum ProvisioningSessionBoundary: String, Codable, Sendable { case preparation, command, invocation }
struct ProvisioningSessionRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let registrationDigest: String
    let scope: ProvisioningRecoveryExpectation
    let boundary: ProvisioningSessionBoundary
    let mode: ProvisioningMode
    let cleanup: Bool
    let commandID: UUID?
    let operation: GuestOperation?
    let invocationID: UUID?
    let purpose: ProvisioningProcessPurpose?
    func validate() throws {
        try scope.validate()
        guard scope.helperIdentity != nil, provisioningDigest(registrationDigest) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        if boundary == .preparation {
            guard !cleanup, commandID == nil, operation == nil, invocationID == nil, purpose == nil else { throw ProvisioningHelperIPCFailure.protocolViolation }
        } else {
            guard commandID != nil, let operation, (boundary == .invocation) == (invocationID != nil),
                  (boundary == .invocation) == (purpose != nil), !cleanup || Self.cleanupOperations.contains(operation),
                  mode != .check || !Self.applyOperations.contains(operation) else { throw ProvisioningHelperIPCFailure.protocolViolation }
            if let purpose { guard Self.purposes(operation).contains(purpose) else { throw ProvisioningHelperIPCFailure.protocolViolation } }
        }
    }
    static let cleanupOperations: Set<GuestOperation> = [.verifyIdentity, .quiesceOwnedWork, .revokeGrant, .clearAuthenticationCache, .verifyGrantInactive, .removePayload, .verifyOwnerDockerAccess]
    static let applyOperations: Set<GuestOperation> = [.resetGrant, .clearAuthenticationCache, .requestPersistentGrant, .verifyGrantActive, .updateSystem, .installManifestPackages, .configureDockerOwnerAccess, .revokeGrant, .verifyGrantInactive]
    static func purposes(_ operation: GuestOperation) -> Set<ProvisioningProcessPurpose> {
        switch operation {
        case .verifyIdentity: [.identity]
        case .stagePayload: [.bootstrap, .copyPayload, .preparePayload]
        case .configureFeatures: [.features]
        case .configureRepository: [.repository]
        case .installManifestPackages: [.packages]
        case .updateSystem: [.systemUpdate]
        case .quiesceOwnedWork: [.quiesce]
        case .removePayload: [.remove]
        default: [.native]
        }
    }
    static func decode(_ data: Data) throws -> Self {
        guard case .object(let fields) = try PlainDataParser.parse(data, format: .json) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        let required: Set<String> = ["requestID", "registrationDigest", "scope", "boundary", "mode", "cleanup"]
        let optional: Set<String> = ["commandID", "operation", "invocationID", "purpose"]
        guard required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(optional)) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        for key in optional where fields[key] != nil { guard case .string = fields[key] else { throw ProvisioningHelperIPCFailure.protocolViolation } }
        try validateExpectation(fields["scope"])
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
}
enum ProvisioningSessionDecision: String, Codable, Sendable { case allowed, bodyStopped, targetChanged, unavailable }
struct ProvisioningSessionResponse: Codable, Sendable {
    let request: ProvisioningSessionRequest
    let decision: ProvisioningSessionDecision
    static func decode(_ data: Data) throws -> Self {
        let fields = try helperObject(data, keys: ["request", "decision"])
        guard let request = fields["request"] else { throw ProvisioningHelperIPCFailure.protocolViolation }
        _ = try ProvisioningSessionRequest.decode(helperJSON(request))
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
typealias ProvisioningManagerSessionCheck = @Sendable (ProvisioningSessionRequest) async throws -> Void
protocol ProvisioningManagerSessionDispatching: ProvisioningHelperDispatching, ProvisioningManagerSessionLaunching {
    func bindSessionAuthority(_ activation: ProvisioningHelperActivation, check: @escaping ProvisioningManagerSessionCheck) async throws
}
protocol ProvisioningManagerSessionLaunching: ProvisioningFrozenHelperLaunching {}

/// Independent reverse-RPC reader. It never acquires the launcher's/control
/// transaction lock while awaiting the coordinator actor, avoiding status/cancel
/// deadlock. A binding is one-shot and cannot be rebound after retirement.
actor ProvisioningManagerSessionServer {
    private let socket: ProvisioningHelperSocket
    private let credentials: ProvisioningHelperCredentials
    private let registration: ProvisioningHelperWorkerRegistration
    private var activation: ProvisioningHelperActivation?
    private var check: ProvisioningManagerSessionCheck?
    private var retired = false, serving = false
    init(socket: ProvisioningHelperSocket, credentials: ProvisioningHelperCredentials) throws {
        guard let registration = credentials.registration, registration.sessionAuthorityVersion == 1 else { throw ProvisioningHelperIPCFailure.protocolViolation }
        self.socket = socket; self.credentials = credentials.sessionCredentials(); self.registration = registration
    }
    nonisolated func stop() { socket.stop() }
    func bind(_ value: ProvisioningHelperActivation, check: @escaping ProvisioningManagerSessionCheck) throws {
        try value.validate()
        guard !retired, value.scope.sameWorker(as: registration.scope), value.registrationDigest == (try registration.digest) else { throw ProvisioningHelperIPCFailure.ownership }
        if let activation { guard activation == value else { throw ProvisioningHelperIPCFailure.ownership }; return }
        activation = value; self.check = check
    }
    func serve() async {
        guard !serving, !retired else { return }; serving = true
        defer { retired = true; check = nil; socket.stop() }
        var codec = ProvisioningHelperFrameCodec(credentials: credentials, role: .manager)
        do {
            for _ in 0..<4096 {
                let data = try await helperBlocking { try self.socket.receive(idle: true) }
                let request = try ProvisioningSessionRequest.decode(codec.decode(data))
                guard request.scope.sameWorker(as: registration.scope), request.registrationDigest == (try registration.digest), request.mode == registration.mode else { throw ProvisioningHelperIPCFailure.ownership }
                var decision = ProvisioningSessionDecision.unavailable
                if activation != nil, let check {
                    do { try await check(request); decision = .allowed }
                    catch SequencingFailure.cancelled { decision = .bodyStopped }
                    catch SequencingFailure.identityMismatch { decision = .targetChanged }
                    catch SequencingFailure.dependencyChanged { decision = .targetChanged }
                    catch { decision = .unavailable }
                }
                let frame = try codec.encode(helperJSON(ProvisioningSessionResponse(request: request, decision: decision)))
                try await helperBlocking { try self.socket.send(frame) }
            }
        } catch { /* No raw request/errors or retry. Loss revokes future authority. */ }
    }
}

/// Serial, bounded helper-to-manager RPC. Successful decisions are never cached;
/// a malformed/lost reply permanently poisons this channel. A valid body-stop
/// denial still permits a later original-target cleanup query.
final class ProvisioningSessionClient: @unchecked Sendable {
    private let socket: ProvisioningHelperSocket
    private let queue = DispatchQueue(label: "omarchy.provisioning-session-client")
    private var codec: ProvisioningHelperFrameCodec
    private let admission = NSLock()
    private var inFlight = false
    private var poisoned = false
    init(socket: ProvisioningHelperSocket, credentials: ProvisioningHelperCredentials) {
        self.socket = socket; codec = .init(credentials: credentials.sessionCredentials(), role: .helper)
    }
    func stop() { socket.stop() }
    var connected: Bool { !socket.peerClosed }
    func authorize(_ request: ProvisioningSessionRequest) async throws {
        try request.validate()
        let decision: ProvisioningSessionDecision = try await withCheckedThrowingContinuation { continuation in
            guard admission.withLock({ if inFlight { return false }; inFlight = true; return true }) else { continuation.resume(throwing: ProvisioningHelperIPCFailure.unavailable); return }
            queue.async { [self] in
                let result: Result<ProvisioningSessionDecision, any Error> = Result {
                    do {
                        guard !poisoned else { throw ProvisioningHelperIPCFailure.unavailable }
                        try socket.send(codec.encode(helperJSON(request)))
                        let reply = try ProvisioningSessionResponse.decode(codec.decode(socket.receive()))
                        guard reply.request == request else { throw ProvisioningHelperIPCFailure.authentication }
                        return reply.decision
                    } catch { poisoned = true; socket.stop(); throw ProvisioningHelperIPCFailure.authentication }
                }
                admission.withLock { inFlight = false }; continuation.resume(with: result)
            }
        }
        switch decision {
        case .allowed: return
        case .bodyStopped: throw SequencingFailure.cancelled
        case .targetChanged: throw SequencingFailure.identityMismatch
        case .unavailable: throw SequencingFailure.adapterFailed
        }
    }
}

protocol ProvisioningCommandSessionAuthorizing: ProvisioningSessionAuthority {
    func begin(_ command: DevVMProvisioningCore.GuestCommand) async throws
    func end(_ commandID: UUID) async
}
protocol ProvisioningInvocationAuthorizing: Sendable {
    func authorize(_ invocation: ProvisioningProcessInvocation) async throws
}
actor ProvisioningHelperSessionAuthority: ProvisioningCommandSessionAuthorizing, ProvisioningInvocationAuthorizing {
    private let registration: ProvisioningHelperWorkerRegistration
    private let target: GuestBinding
    private let admitExecution: @Sendable () throws -> Void
    private let client: ProvisioningSessionClient
    private var command: DevVMProvisioningCore.GuestCommand?
    private var stoppedCommands = Set<UUID>()
    init(registration: ProvisioningHelperWorkerRegistration, target: GuestBinding, client: ProvisioningSessionClient, admitExecution: @escaping @Sendable () throws -> Void = {}) throws {
        try registration.validate()
        guard registration.sessionAuthorityVersion == 1, try ProvisioningCoordinator.bindingIdentity(target) == registration.scope.bindingDigest else { throw SequencingFailure.identityMismatch }
        self.registration = registration; self.target = target; self.client = client; self.admitExecution = admitExecution
    }
    func revalidate(_ binding: GuestBinding, dependencyDigest: String) async throws {
        guard binding == target, dependencyDigest == registration.scope.dependencyDigest else { throw SequencingFailure.identityMismatch }
        let commandID = command?.id
        try await query(boundary: commandID == nil ? .preparation : .command)
        guard command?.id == commandID else { throw SequencingFailure.identityMismatch }
    }
    func begin(_ value: DevVMProvisioningCore.GuestCommand) async throws {
        guard command == nil, value.context.jobID == registration.scope.jobID, value.context.payloadID == registration.scope.payloadID,
              value.context.target == target, value.context.dependencyDigest == registration.scope.dependencyDigest,
              value.mode == registration.mode, value.context.mode == registration.mode,
              value.plan == nil || value.plan?.identity == registration.planDigest else { throw SequencingFailure.identityMismatch }
        command = value
        do {
            try await query(boundary: .command)
            guard command?.id == value.id else { throw SequencingFailure.identityMismatch }
        } catch { if command?.id == value.id { command = nil }; throw error }
    }
    func matches(_ value: ProvisioningHelperWorkerRegistration) -> Bool { registration == value }
    func bodyWasStopped(_ commandID: UUID) -> Bool { stoppedCommands.contains(commandID) }
    func end(_ commandID: UUID) { if command?.id == commandID { command = nil }; stoppedCommands.remove(commandID) }
    func authorize(_ invocation: ProvisioningProcessInvocation) async throws {
        guard let command, invocation.commandID == command.id, invocation.context == command.context else { throw SequencingFailure.identityMismatch }
        try await query(boundary: .invocation, invocation: invocation)
        guard self.command?.id == command.id else { throw SequencingFailure.identityMismatch }
    }
    private func query(boundary: ProvisioningSessionBoundary, invocation: ProvisioningProcessInvocation? = nil) async throws {
        try admitExecution()
        let request = ProvisioningSessionRequest(requestID: UUID(), registrationDigest: try registration.digest, scope: registration.scope,
            boundary: boundary, mode: registration.mode, cleanup: command != nil && command?.plan == nil,
            commandID: command?.id, operation: command?.operation, invocationID: invocation?.id, purpose: invocation?.purpose)
        do { try await client.authorize(request); try admitExecution() }
        catch SequencingFailure.cancelled {
            if let command, command.plan != nil { stoppedCommands.insert(command.id) }
            throw SequencingFailure.cancelled
        }
    }
}
