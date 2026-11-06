import Darwin
import Foundation
import CDevVMProcess

public enum ProvisioningTerminalChannel: Sendable { case stdout, stderr, pty }
public struct ProvisioningTerminalFrame: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sequence: UInt64
    public let invocationID: UUID
    public let channel: ProvisioningTerminalChannel
    public let bytes: Data
    public var description: String { "ProvisioningTerminalFrame(redacted)" }
    public var debugDescription: String { description }
}
public struct ProvisioningTerminalSnapshot: Sendable {
    public let frames: [ProvisioningTerminalFrame]
    /// A renderer must show a gap/reset its terminal state; raw replay cannot
    /// reconstruct an arbitrary screen after dropped escape-sequence bytes.
    public let gap: Bool
    public let lastSequence: UInt64
    public let activeInvocationID: UUID?
    public let acceptsInput: Bool
}
public struct ProvisioningTerminalSize: Sendable, Equatable {
    public let rows: Int
    public let columns: Int
    public init(rows: Int, columns: Int) throws {
        guard (1...500).contains(rows), (1...1000).contains(columns) else { throw SequencingFailure.invalidRequest }
        self.rows = rows; self.columns = columns
    }
}
private struct TerminalInputScope: Equatable {
    let jobID: UUID
    let target: GuestBinding
    let dependencyDigest: String
    let mode: ProvisioningMode
}

/// Pull-based, memory-only terminal transport. No callbacks on the drain path:
/// slow/detached viewers cannot block the child. One explicitly granted input
/// lease is bound to one job context. This is not a terminal renderer or journal.
public final class ProvisioningTerminal: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var frames: [ProvisioningTerminalFrame] = []
    private var stored = 0
    private var sequence: UInt64 = 0
    private var owner: (id: UUID, scope: TerminalInputScope)?
    private var inputEnabled = false
    private var scope: TerminalInputScope?
    private var active: UUID?
    private var acceptsInput = false
    private var retired = Set<UUID>()
    private var inputSequence: UInt64 = 0
    private var pending = Data()
    private var size: ProvisioningTerminalSize
    private var resizePending = false

    public init(capacityBytes: Int = 256 * 1024) throws {
        guard (8192...1024 * 1024).contains(capacityBytes) else { throw SequencingFailure.invalidRequest }
        capacity = capacityBytes
        size = try ProvisioningTerminalSize(rows: 30, columns: 120)
    }
    public func grantInput(leaseID: UUID, context: GuestJobContext, size: ProvisioningTerminalSize) throws {
        try grant(leaseID, scope: TerminalInputScope(jobID: context.jobID, target: context.target,
                                                    dependencyDigest: context.dependencyDigest, mode: context.mode), size: size)
    }
    /// The caller can grant reviewed input before the sequencer creates its
    /// internal payload UUID. Approval already binds this lease to the request.
    public func grantInput(for request: ProvisioningRequest, size: ProvisioningTerminalSize) throws {
        guard let lease = request.inputLeaseID else { throw SequencingFailure.authorizationRequired }
        try grant(lease, scope: TerminalInputScope(jobID: request.jobID, target: request.target,
                                                  dependencyDigest: request.dependencyDigest, mode: request.mode), size: size)
    }
    private func grant(_ leaseID: UUID, scope: TerminalInputScope, size: ProvisioningTerminalSize, enabled: Bool = true) throws {
        try lock.withLock {
            guard owner == nil, active == nil, retired.count < 4096, !retired.contains(leaseID) else { throw SequencingFailure.alreadyUsed }
            owner = (leaseID, scope); self.size = size; inputSequence = 0
            inputEnabled = enabled
        }
    }
    /// Reserve only the reviewed scope. A later explicit live attachment must
    /// resume it; reservation cannot deliver input, including at a hidden prompt.
    public func reserveInput(for request: ProvisioningRequest) throws {
        guard let lease = request.inputLeaseID else { throw SequencingFailure.authorizationRequired }
        try grant(lease, scope: TerminalInputScope(jobID: request.jobID, target: request.target,
            dependencyDigest: request.dependencyDigest, mode: request.mode), size: ProvisioningTerminalSize(rows: 30, columns: 120), enabled: false)
    }
    /// Serialize detach with PTY writes and discard queued keystrokes/resizes.
    /// The reviewed scope survives so a new, explicit attachment can reclaim it.
    public func suspendInput(leaseID: UUID) {
        lock.withLock {
            guard owner?.id == leaseID else { return }
            inputEnabled = false; pending.removeAll(keepingCapacity: false); resizePending = false
        }
    }
    public func resumeInput(leaseID: UUID, size: ProvisioningTerminalSize) throws {
        try lock.withLock {
            guard owner?.id == leaseID, !inputEnabled else { throw SequencingFailure.authorizationRequired }
            inputEnabled = true; self.size = size; resizePending = true
        }
    }
    public func revokeInput(leaseID: UUID) {
        lock.withLock {
            guard owner?.id == leaseID else { return }
            retired.insert(leaseID); owner = nil; inputEnabled = false; pending.removeAll(keepingCapacity: false)
            // Detach/revocation does not cancel a job or close its PTY.
        }
    }
    public func sendInput(leaseID: UUID, invocationID: UUID, sequence: UInt64, bytes: Data) throws {
        try lock.withLock {
            guard acceptsInput, inputEnabled, owner?.id == leaseID, active == invocationID, sequence == inputSequence + 1,
                  !bytes.isEmpty, bytes.count <= 4096, pending.count + bytes.count <= 64 * 1024
            else { throw SequencingFailure.authorizationRequired }
            inputSequence = sequence; pending.append(bytes)
        }
    }
    public func resize(leaseID: UUID, invocationID: UUID, sequence: UInt64, size: ProvisioningTerminalSize) throws {
        try lock.withLock {
            guard acceptsInput, inputEnabled, owner?.id == leaseID, active == invocationID, sequence == inputSequence + 1 else { throw SequencingFailure.authorizationRequired }
            inputSequence = sequence; self.size = size; resizePending = true
        }
    }
    public func snapshot(after sequence: UInt64 = 0) -> ProvisioningTerminalSnapshot {
        lock.withLock {
            var bytes = 0
            let batch = frames.filter { $0.sequence > sequence }.prefix { frame in
                bytes += frame.bytes.count; return bytes <= 64 * 1024
            }
            return ProvisioningTerminalSnapshot(frames: Array(batch), gap: sequence < (frames.first?.sequence ?? (self.sequence + 1)) - 1,
                                                lastSequence: batch.last?.sequence ?? sequence,
                                                activeInvocationID: active, acceptsInput: acceptsInput && inputEnabled && owner != nil)
        }
    }
    public var tailSequence: UInt64 { lock.withLock { sequence } }
    func begin(_ invocation: ProvisioningProcessInvocation) throws -> ProvisioningTerminalSize {
        try lock.withLock {
            guard active == nil else { throw SequencingFailure.alreadyUsed }
            let scope = TerminalInputScope(jobID: invocation.context.jobID, target: invocation.context.target,
                                           dependencyDigest: invocation.context.dependencyDigest, mode: invocation.context.mode)
            guard self.scope == nil || self.scope == scope, owner == nil || owner?.scope == scope else { throw SequencingFailure.identityMismatch }
            if case .terminalLease(let lease) = invocation.input {
                guard owner?.id == lease, owner?.scope == scope else { throw SequencingFailure.authorizationRequired }
                acceptsInput = true
            } else {
                acceptsInput = false
            }
            self.scope = scope; active = invocation.id; pending.removeAll(); resizePending = false
            return size
        }
    }
    func end(_ id: UUID) {
        lock.withLock {
            guard active == id else { return }
            active = nil; acceptsInput = false; pending.removeAll(keepingCapacity: false)
        }
    }
    func flushInput(_ id: UUID, fd: Int32) -> Bool {
        lock.withLock {
            guard active == id, acceptsInput, inputEnabled, owner != nil else { return true }
            if resizePending {
                guard devvm_resize(fd, Int32(size.rows), Int32(size.columns)) == 0 else { return false }
                resizePending = false
            }
            if !pending.isEmpty {
                // Serialize revocation with the actual nonblocking write; no
                // detached buffer can deliver stale input after revocation.
                guard devvm_noecho(fd) == 0 else { return false }
                let n = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, min($0.count, 4096)) }
                if n > 0 { pending.removeFirst(n) }
                else if n < 0, errno != EAGAIN, errno != EINTR { return false }
            }
            return true
        }
    }
    func publish(_ id: UUID, channel: ProvisioningTerminalChannel, bytes: Data) {
        lock.withLock {
            sequence += 1
            frames.append(ProvisioningTerminalFrame(sequence: sequence, invocationID: id, channel: channel, bytes: bytes))
            stored += bytes.count
            while stored > capacity || frames.count > 1024, let first = frames.first { stored -= first.bytes.count; frames.removeFirst() }
        }
    }
}
