import Foundation
import TryOmarchyKitClient

public struct VMStartRequest: Sendable {
    public let profile: VMProfile
    public let storageRoot: URL

    public init(profile: VMProfile, storageRoot: URL) {
        self.profile = profile
        self.storageRoot = storageRoot
    }
}

public typealias VMRuntimeEvent = VMRunEvent

public protocol VMRuntime: Sendable {
    func preflight() -> VMRunError?
    func start(_ request: VMStartRequest,
               onEvent: @escaping @Sendable (VMRuntimeEvent) -> Void) throws -> any VMRuntimeHandle
}

public protocol VMRuntimeHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    var recentStandardError: String { get }
    func shutDown()
    func terminate()
}

public struct TryOmarchyRuntime: VMRuntime {
    private let kit: TryOmarchyKit
    private let protocolTestMode: Bool

    public init(kit: TryOmarchyKit) {
        self.kit = kit
        protocolTestMode = false
    }

    init(protocolTestKit: TryOmarchyKit) {
        kit = protocolTestKit
        protocolTestMode = true
    }
    public func preflight() -> VMRunError? { VMRunClient.preflight() }

    public func start(_ request: VMStartRequest,
                      onEvent: @escaping @Sendable (VMRuntimeEvent) -> Void) throws -> any VMRuntimeHandle {
        guard protocolTestMode else {
            throw VMFailure(code: "poc-approval-required",
                            message: "Real VM launch is disabled in Phase 0/0A. Approve the two-VM POC before enabling launch.")
        }
        let configuration = try Self.configuration(for: request)
        let client = VMRunClient(kit: kit)
        try client.start(configuration, onEvent: onEvent)
        return TryOmarchyRuntimeHandle(client: client)
    }

    public static func configuration(for request: VMStartRequest) throws -> VMRunConfiguration {
        guard request.storageRoot.isFileURL, request.storageRoot.path.hasPrefix("/"),
              request.storageRoot.lastPathComponent == request.profile.id.uuidString else {
            throw VMFailure(code: "invalid-storage-root", message: "A manager-owned UUID root is required.")
        }
        var bridges: [VMRunBridge] = [.battery, .timezone]
        if request.profile.clipboardEnabled { bridges.insert(.clipboard, at: 0) }
        let configuration = VMRunConfiguration(
            productName: request.profile.name, storageRoot: request.storageRoot.path,
            bridges: bridges, memoryMiB: request.profile.memoryMiB, cpus: request.profile.cpus, network: .shared
        )
        try configuration.validate()
        return configuration
    }
}

public final class TryOmarchyRuntimeHandle: VMRuntimeHandle {
    private let client: VMRunClient
    public init(client: VMRunClient) { self.client = client }
    public var isRunning: Bool { client.isRunning }
    public var recentStandardError: String { client.recentStandardError }
    public func shutDown() { client.shutDown() }
    public func terminate() { client.terminate() }
}
