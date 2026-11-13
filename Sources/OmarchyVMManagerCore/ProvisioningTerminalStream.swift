import DevVMProvisioningCore
import Foundation

/// This protocol travels only on the separately authenticated terminal channel.
/// It is never a control/status packet or durable journal representation.
enum ProvisioningTerminalOperation: String, Codable, Sendable {
    case attach, read, reset, claim, release, input, resize, detach, heartbeat
}
public enum ProvisioningTerminalDenial: String, Codable, Error, Sendable {
    case unavailable, busy, attachment, ownership, bounds, resetRequired
}
struct ProvisioningTerminalPacket: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let version: Int
    let jobID: UUID
    let requestID: UUID
    let operation: ProvisioningTerminalOperation
    var attachmentID: UUID? = nil
    var ownershipID: UUID? = nil
    var invocationID: UUID? = nil
    var sequence: UInt64? = nil
    var bytes: Data? = nil
    var rows: Int? = nil
    var columns: Int? = nil
    var description: String { "ProvisioningTerminalPacket(redacted)" }
    var debugDescription: String { description }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 9 * 1024, case .object(let fields) = try PlainDataParser.parse(data, format: .json) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        let value = try JSONDecoder().decode(Self.self, from: data)
        var keys: Set<String> = ["version", "jobID", "requestID", "operation"]
        if value.operation != .attach { keys.insert("attachmentID") }
        if [.release, .input, .resize].contains(value.operation) { keys.insert("ownershipID") }
        if [.input, .resize].contains(value.operation) { keys.formUnion(["invocationID", "sequence"]) }
        if [.claim, .resize].contains(value.operation) { keys.formUnion(["rows", "columns"]) }
        if value.operation == .input { keys.insert("bytes") }
        guard value.version == 1, Set(fields.keys) == keys,
              value.operation == .attach || value.attachmentID != nil,
              ![.release, .input, .resize].contains(value.operation) || value.ownershipID != nil,
              ![.input, .resize].contains(value.operation) || (value.invocationID != nil && (value.sequence ?? 0) > 0 && (value.sequence ?? .max) < UInt64(Int64.max)) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        guard value.operation != .input || value.bytes != nil,
              ![ProvisioningTerminalOperation.claim, .resize].contains(value.operation) || (value.rows != nil && value.columns != nil) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        if let rows = value.rows, let columns = value.columns { _ = try ProvisioningTerminalSize(rows: rows, columns: columns) }
        if let bytes = value.bytes { guard !bytes.isEmpty, bytes.count <= 4096 else { throw ProvisioningHelperIPCFailure.protocolViolation } }
        return value
    }
}
public struct ProvisioningTerminalBytes: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sequence: UInt64
    public let invocationID: UUID
    public let channel: String
    public let bytes: Data
    public var description: String { "ProvisioningTerminalBytes(redacted)" }
    public var debugDescription: String { description }
}
public struct ProvisioningTerminalPage: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let frames: [ProvisioningTerminalBytes]
    public let sequence: UInt64
    /// Explicitly reset the emulator and UTF-8/escape decoder, display a visible
    /// discontinuity, then request reset. Never feed an incomplete replay as a
    /// reconstruction of the old screen. Reset jumps to the live tail.
    public let resetRequired: Bool
    public let activeInvocationID: UUID?
    public let acceptsInput: Bool
    public let ownsInput: Bool
    public var description: String { "ProvisioningTerminalPage(redacted)" }
    public var debugDescription: String { description }
}
struct ProvisioningTerminalReply: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let version: Int
    let jobID: UUID
    let requestID: UUID
    let operation: ProvisioningTerminalOperation
    var attachmentID: UUID? = nil
    var ownershipID: UUID? = nil
    var page: ProvisioningTerminalPage? = nil
    var denial: ProvisioningTerminalDenial? = nil
    var description: String { "ProvisioningTerminalReply(redacted)" }
    var debugDescription: String { description }
    static func decode(_ data: Data, request: ProvisioningTerminalPacket) throws -> Self {
        guard case .object(let fields) = try PlainDataParser.parse(data, format: .json) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        let value = try JSONDecoder().decode(Self.self, from: data)
        let base: Set<String> = ["version", "jobID", "requestID", "operation"]
        var keys = base
        if value.denial != nil { keys.insert("denial") }
        else {
            keys.insert("attachmentID")
            if request.operation == .claim { keys.insert("ownershipID") }
            if [.read, .reset].contains(request.operation) { keys.insert("page") }
        }
        guard value.version == 1, value.jobID == request.jobID, value.requestID == request.requestID,
              value.operation == request.operation, Set(fields.keys) == keys,
              value.denial != nil || (!([ProvisioningTerminalOperation.read, .reset].contains(request.operation)) || value.page != nil),
              value.denial != nil || (request.operation != .claim || value.ownershipID != nil),
              value.denial != nil || (value.attachmentID != nil && (request.operation == .attach || value.attachmentID == request.attachmentID)) else { throw ProvisioningHelperIPCFailure.protocolViolation }
        if let page = value.page {
            guard case .object(let p) = fields["page"], Set(p.keys) == Set(["frames", "sequence", "resetRequired", "acceptsInput", "ownsInput"] + (page.activeInvocationID == nil ? [] : ["activeInvocationID"])),
                  page.frames.count <= 1, page.sequence < UInt64(Int64.max),
                  !page.acceptsInput || (page.activeInvocationID != nil && page.ownsInput),
                  !page.resetRequired || page.frames.isEmpty else { throw ProvisioningHelperIPCFailure.protocolViolation }
            guard case .array(let frames) = p["frames"] else { throw ProvisioningHelperIPCFailure.protocolViolation }
            for (frame, document) in zip(page.frames, frames) {
                guard case .object(let f) = document, Set(f.keys) == ["sequence", "invocationID", "channel", "bytes"],
                      frame.sequence > 0, frame.sequence == page.sequence, ["stdout", "stderr", "pty"].contains(frame.channel),
                      !frame.bytes.isEmpty, frame.bytes.count <= 8192 else { throw ProvisioningHelperIPCFailure.protocolViolation }
            }
        }
        return value
    }
}

/// Bounded, memory-only viewer registry. Polling never runs on the child drain
/// queue. All capabilities die with this helper; none can be adopted from disk.
actor ProvisioningTerminalHub {
    private struct Viewer { var touched: ContinuousClock.Instant; var cursor: UInt64 = 0; var resetRequired = false }
    let terminal: ProvisioningTerminal
    let jobID: UUID
    private let leaseID: UUID?
    private let admitInput: @Sendable () throws -> Void
    private let lifetime: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var viewers: [UUID: Viewer] = [:]
    private var owner: (viewer: UUID, token: UUID, sequence: UInt64)?
    private var terminalSequence: UInt64 = 0
    private var stopped = false, finished = false
    init(terminal: ProvisioningTerminal, request: ProvisioningRequest, lifetime: Duration = .seconds(15), now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, admitInput: @escaping @Sendable () throws -> Void = {}) throws {
        guard lifetime > .zero, lifetime <= .seconds(30) else { throw ProvisioningTerminalDenial.bounds }
        self.terminal = terminal; jobID = request.jobID; leaseID = request.inputLeaseID; self.lifetime = lifetime; self.now = now; self.admitInput = admitInput
        if request.inputLeaseID != nil { try terminal.reserveInput(for: request) }
    }
    func expire() {
        let instant = now()
        for (id, viewer) in viewers where instant - viewer.touched >= lifetime { remove(id) }
    }
    func disconnect() {
        if let leaseID { terminal.suspendInput(leaseID: leaseID) }
        viewers.removeAll(); owner = nil; stopped = true
    }
    func finish() {
        finished = true; owner = nil
        if let leaseID { terminal.revokeInput(leaseID: leaseID) }
    }
    private func releaseOwner(_ id: UUID) {
        if owner?.viewer == id { if let leaseID { terminal.suspendInput(leaseID: leaseID) }; owner = nil }
    }
    private func remove(_ id: UUID) { releaseOwner(id); viewers.removeValue(forKey: id) }
    func handle(_ request: ProvisioningTerminalPacket) -> ProvisioningTerminalReply {
        var reply = ProvisioningTerminalReply(version: 1, jobID: request.jobID, requestID: request.requestID, operation: request.operation)
        do {
            expire()
            guard !stopped, request.jobID == jobID else { throw ProvisioningTerminalDenial.unavailable }
            if request.operation == .attach {
                guard viewers.count < 8 else { throw ProvisioningTerminalDenial.bounds }
                let id = UUID(); viewers[id] = Viewer(touched: now()); reply.attachmentID = id; return reply
            }
            guard let id = request.attachmentID, var viewer = viewers[id] else { throw ProvisioningTerminalDenial.attachment }
            viewer.touched = now(); viewers[id] = viewer; reply.attachmentID = id
            if [.claim, .input, .resize].contains(request.operation), viewer.resetRequired || terminal.snapshot(after: viewer.cursor).gap {
                viewer.resetRequired = true; viewers[id] = viewer
                releaseOwner(id)
                throw ProvisioningTerminalDenial.resetRequired
            }
            if [.claim, .input, .resize].contains(request.operation) {
                do { try admitInput() }
                catch { if let current = owner { releaseOwner(current.viewer) }; throw ProvisioningTerminalDenial.unavailable }
            }
            switch request.operation {
            case .attach: break
            case .detach: remove(id)
            case .heartbeat: break
            case .claim:
                guard !finished, owner == nil, let leaseID else { throw ProvisioningTerminalDenial.ownership }
                try terminal.resumeInput(leaseID: leaseID, size: ProvisioningTerminalSize(rows: request.rows!, columns: request.columns!))
                let token = UUID(); owner = (id, token, 0); reply.ownershipID = token
            case .release:
                guard owner?.viewer == id, owner?.token == request.ownershipID else { throw ProvisioningTerminalDenial.ownership }
                if let leaseID { terminal.suspendInput(leaseID: leaseID) }; owner = nil
            case .input, .resize:
                guard let leaseID, let current = owner, current.viewer == id, current.token == request.ownershipID,
                      current.sequence < UInt64(Int64.max) - 1, request.sequence == current.sequence + 1,
                      terminalSequence < UInt64(Int64.max) - 1 else { throw ProvisioningTerminalDenial.ownership }
                if request.operation == .input {
                    try terminal.sendInput(leaseID: leaseID, invocationID: request.invocationID!, sequence: terminalSequence + 1, bytes: request.bytes!)
                } else {
                    try terminal.resize(leaseID: leaseID, invocationID: request.invocationID!, sequence: terminalSequence + 1, size: ProvisioningTerminalSize(rows: request.rows!, columns: request.columns!))
                }
                terminalSequence += 1; owner?.sequence += 1
            case .read, .reset:
                if request.operation == .reset {
                    // Explicit discontinuity acknowledgement starts at the tail,
                    // without claiming old terminal state was reconstructed.
                    releaseOwner(id)
                    viewer.cursor = terminal.tailSequence; viewer.resetRequired = false
                }
                let snapshot = terminal.snapshot(after: viewer.cursor)
                viewer.resetRequired = viewer.resetRequired || snapshot.gap
                if viewer.resetRequired { releaseOwner(id) }
                let frames: [ProvisioningTerminalBytes]
                if viewer.resetRequired { frames = [] }
                else if let frame = snapshot.frames.first {
                    guard frame.bytes.count <= 8192 else { throw ProvisioningTerminalDenial.bounds }
                    let channel: String = switch frame.channel { case .stdout: "stdout"; case .stderr: "stderr"; case .pty: "pty" }
                    frames = [.init(sequence: frame.sequence, invocationID: frame.invocationID, channel: channel, bytes: frame.bytes)]
                    viewer.cursor = frame.sequence
                } else { frames = [] }
                viewers[id] = viewer
                reply.page = .init(frames: frames, sequence: viewer.cursor, resetRequired: viewer.resetRequired,
                    activeInvocationID: snapshot.activeInvocationID, acceptsInput: snapshot.acceptsInput && owner?.viewer == id,
                    ownsInput: owner?.viewer == id)
            }
        } catch {
            reply.attachmentID = nil; reply.ownershipID = nil; reply.page = nil
            reply.denial = error as? ProvisioningTerminalDenial ?? .ownership
        }
        return reply
    }
}
