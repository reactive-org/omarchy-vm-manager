import Darwin
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
            let receipt = try ProvisioningHelperRegistrationReceipt.decode(codec.decode(socket.receive()))
            guard receipt.identity == ticket.identity, receipt.registrationDigest == (try ticket.registration.digest) else { throw ProvisioningHelperIPCFailure.authentication }
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

/// Helper-side control loop. No register/run/apply/terminal/PID command exists.
/// Terminal byte streaming will use a separate bounded channel in milestone 4.
final class ProvisioningHelperIPCServer: Sendable {
    private let socket: ProvisioningHelperSocket
    private let credentials: ProvisioningHelperCredentials
    private let registry: ProvisioningHelperOwnershipRegistry
    private let gate = ProvisioningHelperServeGate()
    private let registration: ProvisioningHelperWorkerRegistration?
    init(socket: ProvisioningHelperSocket, credentials: ProvisioningHelperCredentials, registry: ProvisioningHelperOwnershipRegistry) throws {
        guard credentials.identity == registry.identity else { throw ProvisioningHelperIPCFailure.authentication }
        self.socket = socket; self.credentials = credentials; self.registry = registry
        registration = credentials.registration
    }
    func stop() { socket.stop() }
    func serve() async {
        guard gate.claim() else { return }
        let monitor = Task {
            while !Task.isCancelled {
                if socket.peerClosed { await registry.managerDisconnected(); return }
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            }
        }
        defer { monitor.cancel(); socket.stop() }
        var codec = ProvisioningHelperFrameCodec(credentials: credentials, role: .helper)
        do {
            if let registration {
                try await registry.registerPrepared(registration)
                let receipt = ProvisioningHelperRegistrationReceipt(identity: credentials.identity, registrationDigest: try registration.digest, state: "registered")
                let frame = try codec.encode(helperJSON(receipt))
                try await helperBlocking { try self.socket.send(frame) }
            }
            while true {
                let packet = try await helperBlocking { try self.socket.receive(idle: true) }
                let request = try ProvisioningHelperReconcileRequest.decode(codec.decode(packet))
                let state = await registry.reconcile(request.expectation)
                let reply = ProvisioningHelperReconcileResponse(requestID: request.requestID, expectation: request.expectation, priorWorker: state)
                let frame = try codec.encode(helperJSON(reply))
                try await helperBlocking { try self.socket.send(frame) }
            }
        } catch {
            // Fixed typed errors only; never echo an untrusted packet/bootstrap.
            await registry.managerDisconnected()
        }
    }
}

/// Public only for the bundled helper executable's fixed ownership-only mode.
/// No provisioning runner, VM, Keychain, journal or operational factory is made.
public enum ProvisioningHelperControl {
    public static func serveInheritedOwnershipChannel(descriptor: Int32, layout: ProvisioningPackageLayout) async throws {
        guard (3...1024).contains(descriptor) else { throw ProvisioningHelperIPCFailure.authentication }
        let socket = try ProvisioningHelperSocket(taking: descriptor)
        defer { socket.stop() }
        _ = try BundledProvisioning.inspect(layout)
        let data = try ProvisioningHelperSocket.bootstrapFromPipe(STDIN_FILENO)
        let credentials = try ProvisioningHelperCredentials(privateBootstrap: data)
        guard credentials.identity.packageLockSHA256 == ProvisioningPackagePin.lockSHA256,
              credentials.identity.executableSHA256 == (try BundledProvisioning.helperExecutableSHA256(layout)) else { throw ProvisioningHelperIPCFailure.authentication }
        _ = try BundledProvisioning.inspect(layout)
        let registry = try ProvisioningHelperOwnershipRegistry(identity: credentials.identity)
        let server = try ProvisioningHelperIPCServer(socket: socket, credentials: credentials, registry: registry)
        // A version-2 bootstrap reserves one inert worker before its receipt.
        // It still has no operational runner or engine-dispatch entry point.
        await server.serve()
    }
}
