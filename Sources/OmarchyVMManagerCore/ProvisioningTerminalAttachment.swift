import DevVMProvisioningCore
import Foundation

/// UI/CLI-neutral attachment. Construction is view-only; claiming input is a
/// separate deliberate action. The attachment itself persists nothing and raw input is never recorded; only the
/// coordinator's view-only recorder saves output, to one private per-VM last-run file.
public actor ProvisioningTerminalAttachment {
    public let id: UUID
    private let client: ProvisioningTerminalClient
    private var ownership: UUID?
    private var sequence: UInt64 = 0
    private var detached = false
    private init(id: UUID, client: ProvisioningTerminalClient) { self.id = id; self.client = client }
    static func attach(client: ProvisioningTerminalClient) async throws -> ProvisioningTerminalAttachment {
        let request = ProvisioningTerminalPacket(version: 1, jobID: client.jobID, requestID: UUID(), operation: .attach)
        let response = try await client.request(request)
        if let denial = response.denial { throw denial }
        guard let id = response.attachmentID else { throw ProvisioningTerminalDenial.attachment }
        return .init(id: id, client: client)
    }
    deinit {
        if !detached {
            let client = client, id = id
            Task {
                _ = try? await client.request(.init(version: 1, jobID: client.jobID, requestID: UUID(), operation: .detach, attachmentID: id))
            }
        }
    }
    private func packet(_ operation: ProvisioningTerminalOperation) throws -> ProvisioningTerminalPacket {
        guard !detached else { throw ProvisioningTerminalDenial.attachment }
        return .init(version: 1, jobID: client.jobID, requestID: UUID(), operation: operation, attachmentID: id)
    }
    private func perform(_ packet: ProvisioningTerminalPacket) async throws -> ProvisioningTerminalReply {
        let reply = try await client.request(packet)
        if let denial = reply.denial { throw denial }
        guard !detached else { throw ProvisioningTerminalDenial.attachment }
        return reply
    }
    public func poll() async throws -> ProvisioningTerminalPage {
        guard let page = try await perform(packet(.read)).page else { throw ProvisioningTerminalDenial.unavailable }
        if !page.ownsInput { ownership = nil; sequence = 0 }
        return page
    }
    /// Caller first resets its emulator/decoder and displays the discontinuity.
    /// This explicit acknowledgement discards backlog and resumes at the tail.
    public func acknowledgeReset() async throws -> ProvisioningTerminalPage {
        guard let page = try await perform(packet(.reset)).page else { throw ProvisioningTerminalDenial.unavailable }
        ownership = nil; sequence = 0
        return page
    }
    public func heartbeat() async throws { _ = try await perform(packet(.heartbeat)) }
    func claimInput(size: ProvisioningTerminalSize) async throws {
        guard ownership == nil else { throw ProvisioningTerminalDenial.ownership }
        var request = try packet(.claim); request.rows = size.rows; request.columns = size.columns
        let response = try await perform(request)
        guard let token = response.ownershipID else { throw ProvisioningTerminalDenial.ownership }
        ownership = token; sequence = 0
    }
    public func releaseInput() async throws {
        guard let ownership else { throw ProvisioningTerminalDenial.ownership }
        var request = try packet(.release); request.ownershipID = ownership
        _ = try await perform(request); self.ownership = nil; sequence = 0
    }
    public func send(_ bytes: Data, invocationID: UUID) async throws {
        var request = try inputPacket(.input, invocationID: invocationID); request.bytes = bytes
        _ = try await perform(request); sequence += 1
    }
    func resize(_ size: ProvisioningTerminalSize, invocationID: UUID) async throws {
        var request = try inputPacket(.resize, invocationID: invocationID); request.rows = size.rows; request.columns = size.columns
        _ = try await perform(request); sequence += 1
    }
    public func claimInput(rows: Int, columns: Int) async throws {
        try await claimInput(size: .init(rows: rows, columns: columns))
    }
    public func resize(rows: Int, columns: Int, invocationID: UUID) async throws {
        try await resize(.init(rows: rows, columns: columns), invocationID: invocationID)
    }
    private func inputPacket(_ operation: ProvisioningTerminalOperation, invocationID: UUID) throws -> ProvisioningTerminalPacket {
        guard let ownership, sequence < UInt64(Int64.max) - 1 else { throw ProvisioningTerminalDenial.ownership }
        var request = try packet(operation); request.ownershipID = ownership; request.invocationID = invocationID; request.sequence = sequence + 1
        return request
    }
    public func detach() async {
        guard !detached else { return }
        let request = try? packet(.detach)
        detached = true; ownership = nil; sequence = 0
        if let request {
            let end = ContinuousClock.now + .seconds(7)
            repeat {
                do { _ = try await client.request(request); return }
                catch ProvisioningTerminalDenial.busy {
                    // Only detach is idempotently retried; input/resize/claim
                    // are never replayed after uncertain acknowledgement.
                    try? await Task.sleep(for: .milliseconds(20))
                } catch { return } // Channel loss itself revokes every lease.
            } while ContinuousClock.now < end
        }
        // An unresponsive connection still expires the helper heartbeat. Never
        // close another viewer's channel as a shortcut for one viewer detach.
    }
}
