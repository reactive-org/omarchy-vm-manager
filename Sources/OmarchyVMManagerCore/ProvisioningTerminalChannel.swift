import Foundation

/// Serial bounded transactions on a dedicated inherited socket. A stalled
/// viewer can poison only this stream, never queue unbounded work or block the
/// ownership/status/cancel channel. Viewers are leased independently of jobs.
final class ProvisioningTerminalClient: @unchecked Sendable {
    private let socket: ProvisioningHelperSocket
    private let queue = DispatchQueue(label: "omarchy.provisioning-terminal-client")
    private let lock = NSLock()
    private var busy = false
    private var codec: ProvisioningHelperFrameCodec
    private var poisoned = false // queue confined
    let jobID: UUID
    init(socket: ProvisioningHelperSocket, credentials: ProvisioningHelperCredentials, jobID: UUID) {
        self.socket = socket; self.jobID = jobID
        codec = .init(credentials: credentials.terminalCredentials(), role: .manager)
    }
    func disconnect() { socket.stop() }
    func request(_ packet: ProvisioningTerminalPacket) async throws -> ProvisioningTerminalReply {
        guard packet.jobID == jobID else { throw ProvisioningTerminalDenial.unavailable }
        _ = try ProvisioningTerminalPacket.decode(helperJSON(packet))
        return try await withCheckedThrowingContinuation { continuation in
            guard lock.withLock({ if busy { return false }; busy = true; return true }) else {
                continuation.resume(throwing: ProvisioningTerminalDenial.busy); return
            }
            queue.async { [self] in
                let result = Result<ProvisioningTerminalReply, any Error> {
                    do {
                        guard !poisoned else { throw ProvisioningTerminalDenial.unavailable }
                        try socket.send(codec.encode(helperJSON(packet)))
                        return try .decode(codec.decode(socket.receive()), request: packet)
                    } catch { poisoned = true; socket.stop(); throw ProvisioningTerminalDenial.unavailable }
                }
                lock.withLock { busy = false }
                continuation.resume(with: result)
            }
        }
    }
}

private final class TerminalServeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool { lock.withLock { guard !used else { return false }; used = true; return true } }
}
final class ProvisioningTerminalServer: Sendable {
    private let socket: ProvisioningHelperSocket
    private let credentials: ProvisioningHelperCredentials
    private let gate = TerminalServeGate()
    let hub: ProvisioningTerminalHub
    init(socket: ProvisioningHelperSocket, credentials: ProvisioningHelperCredentials, hub: ProvisioningTerminalHub) {
        self.socket = socket; self.credentials = credentials; self.hub = hub
    }
    func stop() { socket.stop() }
    func serve() async {
        guard gate.claim() else { return }
        let monitor = Task {
            while !Task.isCancelled {
                if socket.peerClosed { await hub.disconnect(); return }
                await hub.expire()
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            }
        }
        defer { monitor.cancel(); socket.stop() }
        var codec = ProvisioningHelperFrameCodec(credentials: credentials.terminalCredentials(), role: .helper)
        do {
            while !Task.isCancelled {
                let packet = try await helperBlocking { try self.socket.receive(idle: true) }
                let request = try ProvisioningTerminalPacket.decode(codec.decode(packet))
                let response = await hub.handle(request)
                let frame = try codec.encode(helperJSON(response))
                try await helperBlocking { try self.socket.send(frame) }
            }
        } catch { await hub.disconnect() }
    }
}

protocol ProvisioningTerminalLaunching: Sendable {
    func terminalClient(jobID: UUID) async throws -> ProvisioningTerminalClient
}
