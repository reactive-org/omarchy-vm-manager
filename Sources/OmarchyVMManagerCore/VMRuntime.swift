import Foundation
import TryOmarchyKitClient

public struct VMStartRequest: Sendable {
    public let profile: VMProfile
    public let storageRoot: URL
    public let sessionID: UUID
    public let startedAt: Date

    public init(profile: VMProfile, storageRoot: URL, sessionID: UUID = UUID(), startedAt: Date = Date()) {
        self.profile = profile
        self.storageRoot = storageRoot
        self.sessionID = sessionID; self.startedAt = startedAt
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
    private let pocAdmission: POCLaunchAdmission?
    private let ownerSecrets: any OwnerSecretStoring = KeychainOwnerSecretStore()
    private var managedStorage: ManagerStorage? = nil

    public init(kit: TryOmarchyKit) {
        self.kit = kit
        protocolTestMode = false
        pocAdmission = nil
    }

    init(protocolTestKit: TryOmarchyKit) {
        kit = protocolTestKit
        protocolTestMode = true
        pocAdmission = nil
    }
    public init(approvedPOCKit: TryOmarchyKit, lockData: Data, applicationSupport: URL) {
        kit = approvedPOCKit
        protocolTestMode = false
        pocAdmission = POCLaunchAdmission(kit: approvedPOCKit, lockData: lockData, applicationSupport: applicationSupport)
    }

    public init(managedKit: TryOmarchyKit, lockData: Data, applicationSupport: URL) {
        kit = managedKit
        protocolTestMode = false
        pocAdmission = POCLaunchAdmission(kit: managedKit, lockData: lockData, applicationSupport: applicationSupport)
        managedStorage = ManagerStorage(applicationSupport: applicationSupport)
    }

    public func preflight() -> VMRunError? { VMRunClient.preflight() }

    public func start(_ request: VMStartRequest,
                      onEvent: @escaping @Sendable (VMRuntimeEvent) -> Void) throws -> any VMRuntimeHandle {
        guard protocolTestMode || pocAdmission != nil else {
            throw VMFailure(code: "poc-approval-required",
                            message: "Launch the private manager with --poc-approved after approval for its disposable VM run.")
        }
        if let storage = managedStorage, let admission = pocAdmission {
            try admission.validateKit()
            if request.profile.ssh != nil {
                let provenance = try JSONDecoder().decode(RuntimeProvenance.self, from: admission.lockData)
                guard provenance.managedSSHVersion == 1 else { throw VMFailure(code: "unproven-ssh-runtime", message: "Managed SSH requires the exact kit with provisioning capability version 1.") }
            }
            if request.profile.ownerSetup != nil {
                let provenance = try JSONDecoder().decode(RuntimeProvenance.self, from: admission.lockData)
                guard provenance.managedSetupVersion == 1 else { throw VMFailure(code: "unproven-owner-runtime", message: "Unattended setup requires the exact reviewed provisioning-capable runtime. This guest was not launched.") }
            }
            guard storage.matchesRoot(request.storageRoot, profile: request.profile) else {
                throw VMFailure(code: "invalid-storage-root", message: "Only this profile’s manager-owned root may launch.")
            }
            try RegistryStore.validate(request.profile)
            guard request.profile.cpus <= ProcessInfo.processInfo.processorCount else {
                throw VMFailure(code: "unsupported-resources", message: "Reduce the VM’s CPU count to fit this Mac.")
            }
            let required = TryOmarchyStorage.requiredFreeBytes(at: request.storageRoot) + 2_147_483_648
            guard let free = TryOmarchyStorage.freeBytes(at: request.storageRoot), free >= required else {
                throw VMFailure(code: "not-enough-space", message: "Free at least \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) before starting this VM.")
            }
            let owner = ManagedOwnerStorage(root: request.storageRoot)
            let password: Data?
            if let setup = request.profile.ownerSetup, try !owner.completed(request.profile) {
                password = try ownerSecrets.read(reference: setup.credentialReference)
            } else { password = nil }
            _ = try storage.prepare(request.profile, sessionID: request.sessionID, ownerPassword: password)
        } else { try pocAdmission?.admit(request) }
        let configuration = try Self.configuration(for: request)
        let client = VMRunClient(kit: kit)
        do { try client.start(configuration, onEvent: onEvent) }
        catch {
            if request.profile.ownerSetup != nil, let storage = managedStorage { try? storage.withLock(request.profile) { try ManagedOwnerStorage(root: request.storageRoot).clearSeed() } }
            throw error
        }
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
