import Foundation
import TryOmarchyKitClient

public enum VMLaunchIntent: Sendable { case background, foreground }

public struct VMStartRequest: Sendable {
    public let profile: VMProfile
    public let storageRoot: URL
    public let sessionID: UUID
    public let startedAt: Date
    public let launchIntent: VMLaunchIntent

    public init(profile: VMProfile, storageRoot: URL, sessionID: UUID = UUID(), startedAt: Date = Date(), launchIntent: VMLaunchIntent = .background) {
        self.profile = profile
        self.storageRoot = storageRoot
        self.sessionID = sessionID; self.startedAt = startedAt
        self.launchIntent = launchIntent
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
    func pause() throws
    func resume() throws
    func shutDown()
    func terminate()
}

public struct TryOmarchyRuntime: VMRuntime {
    private let kit: TryOmarchyKit
    private let protocolTestMode: Bool
    private let pocAdmission: POCLaunchAdmission?
    private let ownerSecrets: any OwnerSecretStoring = KeychainOwnerSecretStore()
    private var managedStorage: ManagerStorage? = nil
    private var testForeground: GuestLaunchForegrounding? = nil

    public init(kit: TryOmarchyKit) {
        self.kit = kit
        protocolTestMode = false
        pocAdmission = nil
    }

    init(protocolTestKit: TryOmarchyKit, foreground: GuestLaunchForegrounding? = nil) {
        kit = protocolTestKit
        protocolTestMode = true
        pocAdmission = nil
        testForeground = foreground
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
        var factorySelection: VMFactorySelection?
        if let storage = managedStorage, let admission = pocAdmission {
            try admission.validateKit()
            let catalog = try FactoryCatalog(applicationSupport: storage.applicationSupport, kit: kit, lockData: admission.lockData)
            factorySelection = try catalog.selection(for: request.profile.factory)
            if let factory = request.profile.factory { try catalog.validateCapacity(factory, diskGiB: request.profile.diskGiB ?? 64) }
            let execution = try JSONDecoder().decode(RuntimeProvenance.self, from: admission.lockData)
            guard execution.launchIntentVersion == 1 else { throw VMFailure(code: "unproven-launch-intent-runtime", message: "Guest display activation requires the exact reviewed runtime.") }
            guard execution.manualPauseVersion == 1 else { throw VMFailure(code: "unproven-execution-runtime", message: "Manual execution control requires the exact reviewed runtime.") }
            if request.profile.ssh != nil {
                let provenance = try JSONDecoder().decode(RuntimeProvenance.self, from: admission.lockData)
                guard provenance.managedSSHVersion == 1 else { throw VMFailure(code: "unproven-ssh-runtime", message: "Managed SSH requires the exact kit with provisioning capability version 1.") }
            }
            if request.profile.ownerSetup != nil {
                let provenance = try JSONDecoder().decode(RuntimeProvenance.self, from: admission.lockData)
                guard provenance.managedSetupVersion == 1, provenance.ownerSetupReportVersion == VMOwnerSetupContract.reportVersion else { throw VMFailure(code: "unproven-owner-runtime", message: "Unattended setup requires the exact reviewed provisioning-capable runtime. This guest was not launched.") }
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
            let password = try owner.passwordForLaunch(request.profile, secrets: ownerSecrets)
            _ = try storage.prepare(request.profile, sessionID: request.sessionID, ownerPassword: password, ownerContract: try catalog.ownerSetupContract(for: request.profile.factory))
        } else { try pocAdmission?.admit(request) }
        var configuration = try Self.configuration(for: request)
        guard managedStorage != nil || request.profile.factory?.kind != .custom else { throw FactoryCatalog.invalid("Custom factories require the verified managed runtime.") }
        configuration.factory = factorySelection
        let client = VMRunClient(kit: kit)
        let foreground = testForeground ?? GuestLaunchForegrounding(intent: request.launchIntent, unavailable: {
            onEvent(.notice(VMRunNotice(code: .displayUnavailable, message: "The guest display could not be brought forward. Open its Dock entry to focus it.")))
        })
        do {
            try client.start(configuration) { event in
                if case .displayReady(let process) = event { foreground.displayReady(process); return }
                switch event {
                case .error, .stopping, .exited: foreground.cancel()
                case .executionState(let report) where report.state != .running: foreground.cancel()
                default: break
                }
                onEvent(event)
            }
        }
        catch {
            foreground.cancel()
            if request.profile.ownerSetup != nil, let storage = managedStorage { try? storage.withLock(request.profile) { try ManagedOwnerStorage(root: request.storageRoot).clearSeed() } }
            throw error
        }
        return TryOmarchyRuntimeHandle(client: client, foreground: foreground)
    }

    public static func configuration(for request: VMStartRequest, guestIcon: URL? = Bundle.main.url(forResource: "OmarchyGuest", withExtension: "icns")) throws -> VMRunConfiguration {
        guard request.storageRoot.isFileURL, request.storageRoot.path.hasPrefix("/"),
              request.storageRoot.lastPathComponent == request.profile.id.uuidString else {
            throw VMFailure(code: "invalid-storage-root", message: "A manager-owned UUID root is required.")
        }
        var bridges: [VMRunBridge] = [.battery, .timezone]
        if request.profile.clipboardEnabled { bridges.insert(.clipboard, at: 0) }
        let configuration = VMRunConfiguration(
            productName: request.profile.name, iconPath: guestIcon?.path, storageRoot: request.storageRoot.path,
            bridges: bridges, memoryMiB: request.profile.memoryMiB, cpus: request.profile.cpus, network: .shared,
            launchIntent: request.launchIntent == .foreground ? .foreground : .background
        )
        try configuration.validate()
        return configuration
    }
}

public final class TryOmarchyRuntimeHandle: VMRuntimeHandle {
    private let client: VMRunClient
    private let foreground: GuestLaunchForegrounding
    init(client: VMRunClient, foreground: GuestLaunchForegrounding) { self.client = client; self.foreground = foreground }
    public var isRunning: Bool { client.isRunning }
    public var recentStandardError: String { client.recentStandardError }
    public func pause() throws { foreground.cancel(); try client.pause() }
    public func resume() throws { try client.resume() }
    public func shutDown() { foreground.cancel(); client.shutDown() }
    public func terminate() { foreground.cancel(); client.terminate() }
}
