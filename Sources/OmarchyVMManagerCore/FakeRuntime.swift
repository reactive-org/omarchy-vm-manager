import Foundation
import TryOmarchyKitClient

public final class FakeRuntimeHandle: VMRuntimeHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var shutdowns = 0
    private var terminations = 0
    private let onEvent: @Sendable (VMRuntimeEvent) -> Void
    public init(onEvent: @escaping @Sendable (VMRuntimeEvent) -> Void) { self.onEvent = onEvent }
    public var isRunning: Bool { lock.withLock { running } }
    public var recentStandardError: String { "" }
    public var shutdownCount: Int { lock.withLock { shutdowns } }
    public var terminationCount: Int { lock.withLock { terminations } }
    public func shutDown() { lock.withLock { shutdowns += 1 } }
    public func terminate() { lock.withLock { terminations += 1 } }
    public func emit(_ event: VMRuntimeEvent) {
        if case .exited = event { lock.withLock { running = false } }
        onEvent(event)
    }
}

public final class FakeRuntime: VMRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [FakeRuntimeHandle] = []
    private let startFailure: VMRunError?
    private let initialEvents: [VMRuntimeEvent]
    public init(startFailure: VMRunError? = nil, initialEvents: [VMRuntimeEvent] = []) {
        self.startFailure = startFailure
        self.initialEvents = initialEvents
    }
    public func preflight() -> VMRunError? { nil }
    public var startedHandles: [FakeRuntimeHandle] { lock.withLock { handles } }
    public func start(_ request: VMStartRequest,
                      onEvent: @escaping @Sendable (VMRuntimeEvent) -> Void) throws -> any VMRuntimeHandle {
        if let startFailure { throw startFailure }
        let handle = FakeRuntimeHandle(onEvent: onEvent)
        lock.withLock { handles.append(handle) }
        for event in initialEvents { handle.emit(event) }
        return handle
    }
}
