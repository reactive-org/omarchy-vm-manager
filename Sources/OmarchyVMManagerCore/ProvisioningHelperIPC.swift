import Darwin
import DevVMProvisioningCore
import Foundation

/// Serial client. A lost/malformed reply poisons this channel; reconciliation
/// is never retried automatically. A new channel needs a new trusted bootstrap.
final class ProvisioningHelperIPCClient: ProvisioningRecoveryAuthorizing, @unchecked Sendable {
    private let socket: ProvisioningHelperSocket
    private let queue = DispatchQueue(label: "omarchy.provisioning-control-client")
    private var codec: ProvisioningHelperFrameCodec
    private var poisoned = false // Confined to queue.
    private let admission = NSLock()
    private var inFlight = false // Confined to admission; do not queue unbounded callers.
    init(socket: ProvisioningHelperSocket, credentials: ProvisioningHelperCredentials) {
        self.socket = socket; codec = .init(credentials: credentials, role: .manager)
    }
    func disconnect() { socket.stop() }
    func awaitRegistration(_ ticket: ProvisioningHelperLaunchTicket) async throws -> ProvisioningHelperRegistrationReceipt {
        try await transaction { codec, socket in
            let receipt = try ProvisioningHelperRegistrationReceipt.decode(codec.decode(socket.receive(wait: ticket.registration.delivery == nil ? nil : .seconds(30))))
            guard receipt.identity == ticket.identity, receipt.registrationDigest == (try ticket.registration.digest),
                  receipt.deliveryDigest == ticket.registration.delivery?.sha256, receipt.transportDigest == ticket.registration.transport?.sha256 else { throw ProvisioningHelperIPCFailure.authentication }
            return receipt
        }
    }
    func reconcile(_ expectation: ProvisioningRecoveryExpectation) async throws -> ProvisioningRecoveryPermit {
        try expectation.validate()
        return try await transaction { codec, socket in
            let request = ProvisioningHelperReconcileRequest(requestID: UUID(), expectation: expectation)
            try socket.send(codec.encode(helperJSON(request)))
            let response = try ProvisioningHelperReconcileResponse.decode(codec.decode(socket.receive()))
            guard response.requestID == request.requestID, response.expectation == expectation else { throw ProvisioningHelperIPCFailure.authentication }
            return ProvisioningRecoveryPermit(expectation: response.expectation, priorWorker: response.priorWorker)
        }
    }
    func dispatch(_ kind: ProvisioningHelperDispatchKind, activation: ProvisioningHelperActivation) async throws -> ProvisioningHelperWorkerSnapshot {
        try activation.validate()
        let response = try await transaction { codec, socket in
            let request = ProvisioningHelperDispatchRequest(kind: kind, requestID: UUID(), activation: activation)
            try socket.send(codec.encode(helperJSON(request)))
            let value = try ProvisioningHelperDispatchResponse.decode(codec.decode(socket.receive()))
            guard value.kind == kind, value.requestID == request.requestID, value.activation == activation else { throw ProvisioningHelperIPCFailure.authentication }
            if let status = value.status {
                guard status.activationID == activation.activationID, status.activationDigest == (try activation.digest) else { throw ProvisioningHelperIPCFailure.authentication }
            }
            return value
        }
        if let denial = response.denial { throw denial }
        guard let status = response.status else { throw ProvisioningHelperIPCFailure.protocolViolation }; return status
    }
    private func transaction<T: Sendable>(_ operation: @escaping @Sendable (inout ProvisioningHelperFrameCodec, ProvisioningHelperSocket) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            guard admission.withLock({ if inFlight { return false }; inFlight = true; return true }) else {
                continuation.resume(throwing: ProvisioningHelperIPCFailure.unavailable); return
            }
            queue.async { [self] in
                let result: Result<T, any Error> = Result {
                    do {
                        guard !poisoned else { throw ProvisioningHelperIPCFailure.unavailable }
                        return try operation(&codec, socket)
                    } catch {
                        poisoned = true; socket.stop()
                        throw ProvisioningHelperIPCFailure.authentication
                    }
                }
                admission.withLock { inFlight = false }
                continuation.resume(with: result)
            }
        }
    }
}

private final class ProvisioningHelperServeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool { lock.withLock { guard !used else { return false }; used = true; return true } }
}

/// Helper-side control loop. Activation requires an injected local factory;
/// there is no arbitrary registration/shell/terminal/PID command. Raw streaming
/// uses a separate bounded authenticated inherited channel.
final class ProvisioningHelperIPCServer: Sendable {
    private let socket: ProvisioningHelperSocket
    private let credentials: ProvisioningHelperCredentials
    private let registry: ProvisioningHelperOwnershipRegistry
    private let gate = ProvisioningHelperServeGate()
    private let registration: ProvisioningHelperWorkerRegistration?
    private let engineFactory: (any ProvisioningHelperEnginePreparing)?
    private let frozenInput: ProvisioningValidatedFrozenContext?
    private let terminalHub: ProvisioningTerminalHub?
    private let transport: ProvisioningValidatedTransport?
    private let sessionConnected: @Sendable () -> Bool
    init(socket: ProvisioningHelperSocket, credentials: ProvisioningHelperCredentials, registry: ProvisioningHelperOwnershipRegistry, engineFactory: (any ProvisioningHelperEnginePreparing)? = nil, frozenInput: ProvisioningValidatedFrozenContext? = nil, transport: ProvisioningValidatedTransport? = nil, terminalHub: ProvisioningTerminalHub? = nil, sessionConnected: @escaping @Sendable () -> Bool = { true }) throws {
        guard credentials.identity == registry.identity else { throw ProvisioningHelperIPCFailure.authentication }
        guard credentials.registration?.delivery == frozenInput?.receipt, credentials.registration?.transport == transport?.receipt else { throw ProvisioningHelperIPCFailure.authentication }
        self.socket = socket; self.credentials = credentials; self.registry = registry
        registration = credentials.registration; self.engineFactory = engineFactory
        self.frozenInput = frozenInput; self.transport = transport; self.terminalHub = terminalHub; self.sessionConnected = sessionConnected
    }
    func stop() { socket.stop() }
    func serve() async {
        guard gate.claim() else { return }
        let monitor = Task {
            while !Task.isCancelled {
                if socket.peerClosed || !sessionConnected() { socket.stop(); await registry.managerDisconnected(); return }
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            }
        }
        defer { monitor.cancel(); socket.stop() }
        var codec = ProvisioningHelperFrameCodec(credentials: credentials, role: .helper)
        do {
            if let registration {
                let control = socket
                try await registry.registerPrepared(registration, terminalHub: terminalHub, bodyAllowed: { !control.peerClosed && self.sessionConnected() })
                let receipt = ProvisioningHelperRegistrationReceipt(identity: credentials.identity, registrationDigest: try registration.digest, state: "registered", deliveryDigest: frozenInput?.receipt.sha256, transportDigest: transport?.receipt.sha256)
                let frame = try codec.encode(helperJSON(receipt))
                try await helperBlocking { try self.socket.send(frame) }
            }
            while true {
                let packet = try await helperBlocking { try self.socket.receive(idle: true) }
                let payload = try codec.decode(packet)
                let bytes: Data
                if case .object(let object) = try DevVMProvisioningCore.PlainDataParser.parse(payload, format: .json), object["kind"] != nil {
                    let request = try ProvisioningHelperDispatchRequest.decode(payload)
                    do {
                        let status = try await registry.dispatch(request, factory: engineFactory)
                        bytes = try helperJSON(ProvisioningHelperDispatchResponse(kind: request.kind, requestID: request.requestID, activation: request.activation, status: status, denial: nil))
                    } catch let denial as ProvisioningHelperDispatchDenial {
                        bytes = try helperJSON(ProvisioningHelperDispatchResponse(kind: request.kind, requestID: request.requestID, activation: request.activation, status: nil, denial: denial))
                    }
                } else {
                    let request = try ProvisioningHelperReconcileRequest.decode(payload)
                    let state = await registry.reconcile(request.expectation)
                    bytes = try helperJSON(ProvisioningHelperReconcileResponse(requestID: request.requestID, expectation: request.expectation, priorWorker: state))
                }
                let frame = try codec.encode(bytes)
                try await helperBlocking { try self.socket.send(frame) }
            }
        } catch {
            // Fixed typed errors only; never echo an untrusted packet/bootstrap.
            await registry.managerDisconnected()
            await registry.waitForOwnedWorkers()
        }
    }
}

/// Dev builds admit verified Dev roots through inherited ownership/frozen
/// transport. Stable remains disabled; private overlays retain exact scope.
/// No public argument or received packet can install an execution policy.
public enum ProvisioningHelperControl {
    public static func serveInheritedOwnershipChannel(descriptor: Int32, layout: ProvisioningPackageLayout) async throws {
        if ProvisioningProductExecution.enabled {
            try await serveInherited(descriptor: descriptor, layout: layout, engineFactory: nil,
                streamRunnerFactory: { input, terminal in try ProvisioningOperationalBackends.worker(input: input, terminal: terminal, layout: layout) }, executionAdmission: ProvisioningProductExecution.admission)
        } else {
            try await serveInherited(descriptor: descriptor, layout: layout, engineFactory: nil, executionAdmission: ProvisioningProductExecution.admission)
        }
    }
    static func serveInherited(descriptor: Int32, layout: ProvisioningPackageLayout, engineFactory: (any ProvisioningHelperEnginePreparing)?, deliveredBackend: (any ProvisioningDeliveredBackendPreparing)? = nil, transportProvider: (any ProvisioningHelperTransportProviding)? = nil, transportPolicy: ProvisioningTransportPolicy = .host, processRunnerFactory: (@Sendable (ProvisioningValidatedFrozenContext) throws -> any ProvisioningProcessRunner)? = nil, streamRunnerFactory: (@Sendable (ProvisioningValidatedFrozenContext, ProvisioningTerminal) throws -> any ProvisioningProcessRunner)? = nil, executionAdmission: ProvisioningExecutionAdmission = .fixture) async throws {
        guard (3...1024).contains(descriptor) else { throw ProvisioningHelperIPCFailure.authentication }
        let socket = try ProvisioningHelperSocket(taking: descriptor)
        defer { socket.stop() }
        _ = try BundledProvisioning.inspect(layout)
        let data = try ProvisioningHelperSocket.bootstrapFromPipe(STDIN_FILENO)
        let credentials = try ProvisioningHelperCredentials(privateBootstrap: data)
        guard credentials.identity.packageLockSHA256 == ProvisioningPackagePin.lockSHA256,
              credentials.identity.executableSHA256 == (try BundledProvisioning.helperExecutableSHA256(layout)) else { throw ProvisioningHelperIPCFailure.authentication }
        _ = try BundledProvisioning.inspect(layout)
        var sessionClient: ProvisioningSessionClient?
        if credentials.registration?.sessionAuthorityVersion == 1 {
            guard descriptor != 5 else { throw ProvisioningHelperIPCFailure.protocolViolation }
            sessionClient = ProvisioningSessionClient(socket: try ProvisioningHelperSocket(taking: 5), credentials: credentials)
        }
        defer { sessionClient?.stop() }
        var terminalServer: ProvisioningTerminalServer?
        var terminalTask: Task<Void, Never>?
        var terminalHub: ProvisioningTerminalHub?
        var streamTerminal: ProvisioningTerminal?
        defer { terminalServer?.stop(); terminalTask?.cancel() }
        var input: ProvisioningValidatedFrozenContext?
        var validatedTransport: ProvisioningValidatedTransport?
        var factory = engineFactory
        if let registration = credentials.registration, let receipt = registration.delivery {
            guard descriptor != 4 else { throw ProvisioningHelperIPCFailure.protocolViolation }
            let channel = try ProvisioningHelperSocket(taking: 4)
            defer { channel.stop() }
            let bytes = try ProvisioningFrozenChannel.receive(receipt, over: channel)
            let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let validated = try ProvisioningValidatedFrozenContext.load(bytes, registration: registration, parent: parent)
            input = validated
            if let transportReceipt = registration.transport {
                guard descriptor != 6, let sessionClient else { throw ProvisioningHelperIPCFailure.protocolViolation }
                let channel = try ProvisioningHelperSocket(taking: 6); defer { channel.stop() }
                let bytes = try ProvisioningFrozenChannel.receive(byteCount: transportReceipt.byteCount, sha256: transportReceipt.sha256, maximumBytes: ProvisioningTransportHandoff.maximumBytes, over: channel)
                let admitted = try ProvisioningValidatedTransport.load(bytes, registration: registration, input: validated, policy: transportPolicy)
                validatedTransport = admitted
                let admitExecution = try executionAdmission.helperCheck(input: validated, transport: admitted)
                if registration.terminalVersion == 1 {
                    guard descriptor != 7, registration.transport != nil else { throw ProvisioningHelperIPCFailure.protocolViolation }
                    let terminal = try ProvisioningTerminal()
                    let hub = try ProvisioningTerminalHub(terminal: terminal, request: validated.request, admitInput: admitExecution)
                    let server = ProvisioningTerminalServer(socket: try ProvisioningHelperSocket(taking: 7), credentials: credentials, hub: hub)
                    streamTerminal = terminal; terminalHub = hub; terminalServer = server
                }
                if let streamRunnerFactory, let streamTerminal, let terminalHub {
                    let provider = ProvisioningDeliveredTransportProvider(transport: admitted, makeProcessRunner: { try streamRunnerFactory(validated, streamTerminal) })
                    let backend = ProvisioningHelperTransportBackend(provider: provider, client: sessionClient, admitPackage: { _ = try BundledProvisioning.inspect(layout) }, terminalHub: terminalHub, executionAdmission: executionAdmission)
                    factory = ProvisioningDeliveredEngineFactory(input: validated, backend: backend)
                } else if registration.terminalVersion == nil, let processRunnerFactory {
                    let provider = ProvisioningDeliveredTransportProvider(transport: admitted, makeProcessRunner: { try processRunnerFactory(validated) })
                    let backend = ProvisioningHelperTransportBackend(provider: provider, client: sessionClient, admitPackage: { _ = try BundledProvisioning.inspect(layout) }, executionAdmission: executionAdmission)
                    factory = ProvisioningDeliveredEngineFactory(input: validated, backend: backend)
                } else { factory = nil }
            } else if let sessionClient {
                if let transportProvider {
                    let backend = ProvisioningHelperTransportBackend(provider: transportProvider, client: sessionClient,
                        admitPackage: { _ = try BundledProvisioning.inspect(layout) }, executionAdmission: executionAdmission)
                    factory = ProvisioningDeliveredEngineFactory(input: validated, backend: backend)
                } else { factory = nil } // No downgrade to a helper-local authority.
            } else { factory = deliveredBackend.map { ProvisioningDeliveredEngineFactory(input: validated, backend: $0) } }
        }
        // No terminal transaction is accepted before frozen input and original
        // transport admission have both succeeded.
        if let terminalServer { terminalTask = Task { await terminalServer.serve() } }
        let registry = try ProvisioningHelperOwnershipRegistry(identity: credentials.identity)
        let peer = sessionClient
        let server = try ProvisioningHelperIPCServer(socket: socket, credentials: credentials, registry: registry, engineFactory: factory, frozenInput: input, transport: validatedTransport, terminalHub: terminalHub, sessionConnected: { peer?.connected ?? true })
        // Bootstrap reserves the original worker before its receipt. The public
        // product entry point supplies no context factory and rejects activation.
        await server.serve()
        await terminalHub?.finish()
    }
}
