import Foundation
import TryOmarchyKitClient

public actor VMManager {
    private struct Session {
        let id: UUID
        let root: URL
        let events: AsyncStream<VMRuntimeEvent>.Continuation
        var handle: (any VMRuntimeHandle)?
        var shutdownRequested = false
        var forceRequested = false
        var coldStart = false
        var reachedReady = false
        var sshTask: Task<Void, Never>?
        var ownerTask: Task<Void, Never>?
        var sshProbeID = UUID()
        var powerProbeTask: Task<Void, Never>?
        var powerOperationTask: Task<Void, Never>?
        var powerBusy = false
        var restoreVerificationTimeout: Duration = .seconds(180)
        var executionCommand: VMRunCommand?
        var executionCompletion: CheckedContinuation<Void, any Error>?
        var executionTimeout: Task<Void, Never>?
    }

    private let factoryTrashService: any FactoryTrashService
    private let runtime: any VMRuntime
    private let applicationSupport: URL
    private var profiles: [VMProfile]
    private var states: [UUID: VMState] = [:]
    private var failures: [UUID: VMFailure] = [:]
    private var notices: [UUID: String] = [:]
    private var sessions: [UUID: Session] = [:]
    private let enforcePOCPolicy: Bool
    private let hostMemoryMiB: Int
    private let logicalCPUs: Int
    private var records: [VMLifecycleRecord] = []
    private let registry: RegistryStore?
    private let trashService: (any VMTrashService)?
    private let sshProbe: (any SSHReadinessChecking)?
    private let hibernation: (any GuestHibernating)?
    private var powerCapabilities: [UUID: GuestHibernationCapability] = [:]
    private var suspensions: [UUID: ExperimentalSuspension] = [:]
    private var unsafeSuspensions: Set<UUID> = []
    private let portProbe: any HostPortProbing
    private let ownerDefaults: OwnerDefaultsStore?
    private var ownerStates: [UUID: OwnerSetupReadiness] = [:]
    private var sshStates: [UUID: SSHReadiness] = [:]
    private var storageTransactions: Set<UUID> = []
    private var quitting = false
    private var interruptedDeletions: Set<UUID> = []

    public private(set) var factoryLibraryRevision = UUID()

    public func eventLog() -> [VMLifecycleRecord] { records }
    public func observation() -> (snapshots: [VMSnapshot], records: [VMLifecycleRecord], factoryRevision: UUID) { (snapshots(), records, factoryLibraryRevision) }

    private func record(_ text: String, vmID: UUID, sessionID: UUID) {
        records.append(VMLifecycleRecord(date: Date(), vmID: vmID, sessionID: sessionID, text: String(text.prefix(4096))))
        if records.count > 300 { records.removeFirst(records.count - 300) }
    }

    public init(runtime: any VMRuntime, profiles: [VMProfile], applicationSupport: URL, enforcePOCPolicy: Bool = false,
                hostMemoryMiB: Int = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
                logicalCPUs: Int = ProcessInfo.processInfo.processorCount,
                registry: RegistryStore? = nil, trashService: (any VMTrashService)? = nil,
                sshProbe: (any SSHReadinessChecking)? = nil, portProbe: any HostPortProbing = LoopbackPortProbe(), ownerDefaults: OwnerDefaultsStore? = nil, hibernation: (any GuestHibernating)? = nil, factoryTrashService: any FactoryTrashService = SystemFactoryTrashService()) {
        self.factoryTrashService = factoryTrashService
        self.runtime = runtime
        self.profiles = profiles
        self.applicationSupport = applicationSupport
        self.enforcePOCPolicy = enforcePOCPolicy
        self.hostMemoryMiB = hostMemoryMiB
        self.logicalCPUs = logicalCPUs
        self.registry = registry
        self.trashService = trashService
        self.hibernation = hibernation
        self.sshProbe = sshProbe; self.portProbe = portProbe; self.ownerDefaults = ownerDefaults
        for profile in profiles {
            do { suspensions[profile.id] = try ExperimentalSuspendStore(root: ManagerStorage(applicationSupport: applicationSupport).root(for: profile)).load(vmID: profile.id) }
            catch { unsafeSuspensions.insert(profile.id) }
        }
        interruptedDeletions = registry?.pendingDeletions ?? []
        for id in interruptedDeletions {
            let failure = VMFailure(code: "interrupted-deletion", message: "A previous deletion was interrupted. The disk may already be in Trash. Review Delete VM again to finish removing the profile; restore files manually before recovery.")
            states[id] = .failed(failure); failures[id] = failure
        }
    }

    public static func open(runtime: any VMRuntime, applicationSupport: URL, trashService: any VMTrashService) throws -> VMManager {
        let registry = try RegistryStore(applicationSupport: applicationSupport)
        let profiles = try registry.load()
        let storage = ManagerStorage(applicationSupport: applicationSupport)
        for profile in profiles where profile.ownerSetup != nil && PrivateFiles.exists(storage.root(for: profile)) {
            try storage.validate(profile)
            try storage.withLock(profile) { try ManagedOwnerStorage(root: storage.root(for: profile)).clearSeed() }
        }
        return VMManager(runtime: runtime, profiles: profiles, applicationSupport: applicationSupport,
                         enforcePOCPolicy: true, registry: registry, trashService: trashService, sshProbe: ManagedSSHProbe(), ownerDefaults: OwnerDefaultsStore(applicationSupport: applicationSupport), hibernation: SSHGuestHibernation())
    }

    private var factoryCatalog: FactoryCatalog? = nil

    public func installFactoryCatalog(_ catalog: FactoryCatalog) { factoryCatalog = catalog }
    private struct FactoryImportOperation {
        let id: UUID
        let task: Task<FactoryIdentity, any Error>
    }
    private var factoryImportOperation: FactoryImportOperation?
    private struct FactoryDeletionOperation {
        let id: UUID
        let selector: String
        let task: Task<FactoryIdentity, any Error>
    }
    private var factoryDeletionOperation: FactoryDeletionOperation?
    private var pendingFactoryCreations: [String: Int] = [:]

    public func deleteFactory(_ selector: String) async throws -> FactoryIdentity {
        try Task.checkCancellation()
        try FactoryCatalog.validateDeletionSelector(selector)
        guard !quitting, let registry, let factoryCatalog else { throw FactoryCatalog.invalid("The verified factory catalog is unavailable.") }
        try registry.checkRevision()
        guard factoryDeletionOperation == nil, factoryImportOperation == nil else {
            throw VMFailure(code: "factory-busy", message: "Wait for the active factory import or deletion to finish.")
        }
        try FactoryReferencePolicy.requireUnused(selector, profiles: profiles, pendingCreations: pendingFactoryCreations[selector, default: 0])
        let id = UUID()
        let operation = Task { try await performFactoryDeletion(selector, id: id, catalog: factoryCatalog, registry: registry) }
        factoryDeletionOperation = FactoryDeletionOperation(id: id, selector: selector, task: operation)
        return try await operation.value
    }
    private func performFactoryDeletion(_ selector: String, id: UUID, catalog: FactoryCatalog, registry: RegistryStore) async throws -> FactoryIdentity {
        defer {
            if factoryDeletionOperation?.id == id { factoryDeletionOperation = nil; factoryLibraryRevision = UUID() }
        }
        let review = try await Task.detached(priority: .utility) { try catalog.deletionReview(selector) }.value
        try registry.checkRevision()
        try FactoryReferencePolicy.requireUnused(selector, profiles: profiles, pendingCreations: pendingFactoryCreations[selector, default: 0])
        let service = factoryTrashService
        return try await Task.detached(priority: .utility) {
            try await catalog.trash(review, service: service, beforeTrash: { try registry.checkRevision() })
        }.value
    }
    public func waitForFactoryDeletion() async {
        guard let operation = factoryDeletionOperation else { return }
        _ = try? await operation.task.value
    }
    public var isImportingFactory: Bool { factoryImportOperation != nil }
    public func factoryListing() async throws -> FactoryCatalogListing {
        guard let factoryCatalog else { return FactoryCatalogListing(factories: [.official], issues: []) }
        return try await Task.detached(priority: .utility) { try factoryCatalog.listing() }.value
    }
    public func factories() async throws -> [FactoryIdentity] { try await factoryListing().factories }
    public func importFactory(_ source: URL, onProgress: @escaping @Sendable (FactoryImportProgress) -> Void = { _ in }) async throws -> FactoryIdentity {
        try Task.checkCancellation()
        guard !quitting, registry != nil, let factoryCatalog else { throw FactoryCatalog.invalid("The verified factory catalog is unavailable.") }
        guard factoryImportOperation == nil, factoryDeletionOperation == nil else { throw VMFailure(code: "factory-busy", message: "Wait for the active factory import or deletion to finish.") }
        let id = UUID()
        let operation = Task.detached(priority: .utility) {
            try await withTaskCancellationHandler(operation: { try factoryCatalog.importBundle(source, onProgress: onProgress) }, onCancel: { onProgress(.cancelling) })
        }
        factoryImportOperation = FactoryImportOperation(id: id, task: operation)
        defer { finishFactoryImport(id) }
        return try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
    }
    public func cancelFactoryImportAndWait() async {
        guard let operation = factoryImportOperation else { return }
        operation.task.cancel()
        _ = try? await operation.task.value
        finishFactoryImport(operation.id)
    }
    private func finishFactoryImport(_ id: UUID) {
        if factoryImportOperation?.id == id { factoryImportOperation = nil; factoryLibraryRevision = UUID() }
    }

    public func create(name: String, memoryMiB: Int, cpus: Int, diskGiB: Int = 64,
                       clipboardEnabled: Bool, immersiveMode: Bool, sshEnabled: Bool = true,
                       publicKey: String? = nil, useOwnerDefaults: Bool? = nil, inheritDefaultPublicKey: Bool = true, factory: String = "official",
                       ownerOverrides: GuestOwnerOverrides? = nil) async throws -> UUID {
        guard !quitting, let registry else { throw VMFailure(code: "registry-unavailable", message: "The registry is unavailable or the manager is quitting.") }
        if let ownerOverrides {
            guard useOwnerDefaults != false, ownerDefaults != nil else { throw OwnerConfiguration.invalid("Owner overrides require enabled, saved Guest Defaults.") }
            _ = try ownerOverrides.applying(to: OwnerConfiguration())
        }
        if factory != "official" {
            guard factoryDeletionOperation?.selector != factory else { throw VMFailure(code: "factory-busy", message: "This factory is being deleted.") }
            pendingFactoryCreations[factory, default: 0] += 1
        }
        defer {
            if factory != "official" {
                pendingFactoryCreations[factory, default: 1] -= 1
                if pendingFactoryCreations[factory] == 0 { pendingFactoryCreations[factory] = nil }
            }
        }
        var profile = VMProfile(id: UUID(), name: name, memoryMiB: memoryMiB, cpus: cpus, diskGiB: diskGiB,
                                clipboardEnabled: clipboardEnabled, immersiveMode: immersiveMode)
        if factory == "official" { profile.factory = .official }
        else {
            guard let factoryCatalog else { throw FactoryCatalog.invalid("The verified factory catalog is unavailable.") }
            profile.factory = try await Task.detached(priority: .utility) {
                let identity = try factoryCatalog.identity(for: factory)
                try factoryCatalog.validateCapacity(identity, diskGiB: diskGiB)
                return identity
            }.value
        }
        try Task.checkCancellation()
        guard !quitting else { throw VMFailure(code: "registry-unavailable", message: "The manager is quitting.") }
        try validateResources(profile)
        var chosenPublicKey = publicKey
        if useOwnerDefaults != false, let ownerDefaults {
            let defaults = try ownerDefaults.load()
            if useOwnerDefaults == true, !defaults.enabled { throw OwnerConfiguration.invalid("Enable and save Guest Defaults before choosing unattended setup.") }
            profile.ownerSetup = try ownerDefaults.snapshot(for: profile.id, overrides: ownerOverrides)
            if profile.ownerSetup != nil, chosenPublicKey == nil, inheritDefaultPublicKey { chosenPublicKey = defaults.sshPublicKey }
        } else if useOwnerDefaults == true { throw OwnerConfiguration.invalid("Guest Defaults is unavailable.") }
        if sshEnabled {
            let occupied = Set(profiles.compactMap { $0.ssh?.hostPort })
            guard let port = (2222...49151).first(where: { !occupied.contains($0) && portProbe.isAvailable($0) }) else {
                throw VMFailure(code: "ssh-port-unavailable", message: "No unprivileged loopback port is available for SSH.")
            }
            let fingerprint = try chosenPublicKey.map { try SelectedPublicKeyStore(applicationSupport: applicationSupport).save($0, id: profile.id) }
            profile.ssh = SSHOptions(hostPort: port, publicKeyFingerprint: fingerprint)
        }
        try validateResources(profile)
        do { try registry.save(profiles + [profile]) }
        catch { SelectedPublicKeyStore(applicationSupport: applicationSupport).remove(profile.id); throw error }
        profiles.append(profile)
        return profile.id
    }

    public func guestDefaults() throws -> OwnerDefaults {
        guard let ownerDefaults else { return OwnerDefaults() }
        return try ownerDefaults.load()
    }

    public func saveGuestDefaults(enabled: Bool, configuration: OwnerConfiguration, password: Data?, sshPublicKey: String?) throws -> OwnerDefaults {
        guard !quitting, let registry, let ownerDefaults else { throw OwnerConfiguration.invalid("Guest Defaults is unavailable while the manager is quitting.") }
        try registry.checkRevision()
        return try ownerDefaults.save(enabled: enabled, configuration: configuration, password: password, sshPublicKey: sshPublicKey)
    }

    public func upgradeSavedGuestPassword() async throws {
        guard !quitting, let registry, let ownerDefaults else { throw OwnerConfiguration.invalid("Guest Defaults is unavailable while the manager is quitting.") }
        try registry.checkRevision()
        try await Task.detached(priority: .userInitiated) { try ownerDefaults.upgradeSavedPassword() }.value
    }

    public func update(_ id: UUID, configuration: GuestConfigurationPatch) throws {
        guard var profile = profiles.first(where: { $0.id == id }) else { throw VMFailure(code: "unknown-vm", message: "The VM profile does not exist.") }
        guard configuration.ssh == nil, configuration.ownerDefaults == nil, configuration.ownerOverrides == nil, configuration.publicKey == nil, configuration.inheritDefaultPublicKey == nil, configuration.factory == nil else { throw VMFailure(code: "creation-only", message: "SSH and owner enrollment are chosen at creation.") }
        if let value = configuration.name { profile.name = value }
        if let value = configuration.memoryMiB { profile.memoryMiB = value }
        if let value = configuration.cpus { profile.cpus = value }
        if let value = configuration.diskGiB { profile.diskGiB = value }
        if let value = configuration.clipboard { profile.clipboardEnabled = value }
        if let value = configuration.immersive { profile.immersiveMode = value }
        try configure(profile)
    }

    public func configure(_ profile: VMProfile) throws {
        try requireEditable(profile.id)
        guard !interruptedDeletions.contains(profile.id) else { throw VMFailure(code: "interrupted-deletion", message: "Finish reviewing the interrupted deletion before configuring this profile.") }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }), let registry,
              profiles[index].createdAt == profile.createdAt else { throw VMFailure(code: "unknown-vm", message: "The VM profile changed or is missing.") }
        guard profile.factory == profiles[index].factory else { throw FactoryCatalog.invalid("The factory is fixed at creation. Existing disks and recorded identities are preserved.") }
        guard profile.ownerSetup == profiles[index].ownerSetup else { throw OwnerConfiguration.invalid("Owner setup is fixed at guest creation. Existing disks need a separate reviewed migration.") }
        guard profile.ssh == profiles[index].ssh else { throw VMFailure(code: "ssh-migration-required", message: "SSH enrollment is chosen at creation. Changing existing access needs a separate stopped-VM migration.") }
        if let current = profiles[index].diskGiB {
            guard let requested = profile.diskGiB, requested >= current else {
                throw VMFailure(code: "disk-cannot-shrink", message: "VM disks can grow but cannot shrink. Keep or increase the current capacity.")
            }
        }
        try validateResources(profile)
        var edited = profile
        let storage = ManagerStorage(applicationSupport: applicationSupport)
        func save() throws {
            var next = profiles; next[index] = edited
            try registry.save(next)
            profiles = next
        }
        if PrivateFiles.exists(storage.root(for: edited)) {
            try storage.withLock(edited) {
                try storage.validate(edited)
                if let requested = edited.diskGiB, let currentDisk = try storage.diskCapacityGiB(edited), requested < currentDisk {
                    throw VMFailure(code: "disk-cannot-shrink", message: "The disk is already " + String(currentDisk) + " GiB and cannot shrink to " + String(requested) + " GiB.")
                }
                edited.settingsFingerprint = try storage.settingsFingerprint(edited)
                try save()
            }
        } else { try save() }
    }

    public func deletionRequest(_ id: UUID) throws -> TrashRequest? {
        try requireStopped(id)
        guard let profile = profiles.first(where: { $0.id == id }) else { throw VMFailure(code: "unknown-vm", message: "The VM profile does not exist.") }
        let storage = ManagerStorage(applicationSupport: applicationSupport)
        guard PrivateFiles.exists(storage.root(for: profile)) else { return nil }
        return try TrashRequest(profile: profile, expectedIdentity: storage.deletionIdentity(profile))
    }

    public func delete(_ id: UUID, confirmed: Bool, expectedIdentity: String?) async throws {
        guard confirmed else { throw VMFailure(code: "confirmation-required", message: "Confirm moving this VM to Trash.") }
        try requireStopped(id)
        guard let registry, let profile = profiles.first(where: { $0.id == id }) else { throw VMFailure(code: "registry-unavailable", message: "The registry is unavailable.") }
        let storage = ManagerStorage(applicationSupport: applicationSupport)
        let exists = PrivateFiles.exists(storage.root(for: profile))
        if exists, expectedIdentity == nil { throw VMFailure(code: "review-required", message: "Review the current VM storage before deleting it.") }
        try registry.markDeletion(id)
        interruptedDeletions.insert(id)
        storageTransactions.insert(id); states[id] = .deleting
        defer { storageTransactions.remove(id) }
        do {
            if exists {
                guard let trashService, let expectedIdentity else { throw VMFailure(code: "trash-unavailable", message: "The storage helper is unavailable.") }
                try await trashService.moveToTrash(TrashRequest(profile: profile, expectedIdentity: expectedIdentity))
                guard !PrivateFiles.exists(storage.root(for: profile)) else {
                    throw VMFailure(code: "trash-incomplete", message: "The helper did not move this VM. Its registry entry was retained.")
                }
            } else if expectedIdentity != nil { throw VMFailure(code: "storage-changed", message: "The VM storage changed since confirmation.") }
            else if PrivateFiles.exists(storage.root(for: profile)) { throw VMFailure(code: "storage-changed", message: "VM storage appeared since confirmation.") }
            let next = profiles.filter { $0.id != id }
            try registry.save(next)
            profiles = next; SelectedPublicKeyStore(applicationSupport: applicationSupport).remove(id); interruptedDeletions.remove(id); states[id] = nil; failures[id] = nil; notices[id] = nil
        } catch {
            if PrivateFiles.exists(storage.root(for: profile)), (try? registry.clearDeletion(id)) != nil { interruptedDeletions.remove(id) }
            let failure = Self.failure(error); states[id] = .failed(failure); failures[id] = failure
            throw failure
        }
    }

    private func requireEditable(_ id: UUID) throws {
        try requireStopped(id)
        guard !POCProfiles.ids.contains(id) else {
            throw VMFailure(code: "vm-not-editable", message: "Retained POC profiles are protected from configuration changes.")
        }
    }

    private func requireStopped(_ id: UUID) throws {
        guard suspensions[id] == nil, !unsafeSuspensions.contains(id) else { throw VMFailure(code: "suspended-disk-protected", message: "Restore or recover this experimental suspension before editing or deleting its disk.") }
        if let profile = profiles.first(where: { $0.id == id }) {
            try ManagerStorage(applicationSupport: applicationSupport).requireNoSavedSession(profile)
        }
        guard !quitting, sessions[id] == nil, !storageTransactions.contains(id),
              (states[id] ?? .stopped).canStart else {
            throw VMFailure(code: "vm-not-editable", message: "Stop the VM before changing or deleting it.")
        }
    }

    private func validateResources(_ profile: VMProfile) throws {
        try RegistryStore.validate(profile)
        guard profile.cpus <= logicalCPUs, profile.memoryMiB <= hostMemoryMiB - max(4096, hostMemoryMiB / 4) else {
            throw VMFailure(code: "unsupported-resources", message: "The requested CPU or memory allocation exceeds this Mac’s guest budget.")
        }
    }

    public func snapshots() -> [VMSnapshot] {
        profiles.map {
            VMSnapshot(profile: $0, state: states[$0.id] ?? .stopped,
                       sessionID: sessions[$0.id]?.id, lastFailure: failures[$0.id], notice: notices[$0.id],
                       sshReadiness: sshStates[$0.id] ?? ($0.ssh == nil ? .disabled : .stopped),
                       ownerSetupReadiness: ownerReadiness($0), hibernation: powerCapabilities[$0.id], suspension: suspensions[$0.id], suspensionMetadataUnsafe: unsafeSuspensions.contains($0.id), experimentalPowerBusy: sessions[$0.id]?.powerBusy ?? false)
        }
    }

    private func ownerReadiness(_ profile: VMProfile) -> OwnerSetupReadiness {
        guard profile.ownerSetup != nil else { return .manual }
        if let state = ownerStates[profile.id] { return state }
        let root = ManagerStorage(applicationSupport: applicationSupport).root(for: profile)
        return (try? ManagedOwnerStorage(root: root).completed(profile)) == true ? .configured : .pending
    }

    public var activeSessionCount: Int { sessions.count }
    public var isIdle: Bool { sessions.isEmpty && storageTransactions.isEmpty && factoryImportOperation == nil && factoryDeletionOperation == nil }
    public var allocatedMemoryMiB: Int {
        profiles.filter { sessions[$0.id] != nil }.reduce(0) { $0 + $1.memoryMiB }
    }

    public func start(_ vmID: UUID, launchIntent: VMLaunchIntent = .background) async throws { try await start(vmID, restoreVerificationTimeout: nil, launchIntent: launchIntent) }

    private func start(_ vmID: UUID, restoreVerificationTimeout: Duration?, launchIntent: VMLaunchIntent = .background) async throws {
        guard !unsafeSuspensions.contains(vmID), suspensions[vmID] == nil || restoreVerificationTimeout != nil else {
            throw VMFailure(code: "suspended-disk-protected", message: "Use Restore Experimental Session. Ordinary launch is blocked while a saved session may exist.")
        }
        try registry?.checkRevision()
        guard !interruptedDeletions.contains(vmID) else { throw VMFailure(code: "interrupted-deletion", message: "Review the interrupted deletion before launching. Missing storage will not be recreated.") }
        guard !quitting, !storageTransactions.contains(vmID) else { throw VMFailure(code: "transaction-busy", message: "A storage transaction or application shutdown is in progress.") }
        guard let profile = profiles.first(where: { $0.id == vmID }) else {
            throw VMFailure(code: "unknown-vm", message: "The VM profile does not exist.")
        }
        guard sessions[vmID] == nil, (states[vmID] ?? .stopped).canStart else {
            throw VMFailure(code: "already-active", message: "This VM already has an active session.")
        }
        let root = POCProfiles.root(for: profile, applicationSupport: applicationSupport).resolvingSymlinksInPath()
        guard !sessions.values.contains(where: { $0.root == root }) else {
            throw VMFailure(code: "duplicate-root", message: "This storage root is already in use.")
        }
        if enforcePOCPolicy {
            guard !sessions.values.contains(where: { $0.coldStart && !$0.reachedReady }) else {
                throw VMFailure(code: "cold-start-busy", message: "Wait until the first cold start is ready before starting another VM.")
            }
            let activeProfiles = profiles.filter { sessions[$0.id] != nil } + [profile]
            try POCHostPolicy.validate(memoryMiB: activeProfiles.reduce(0) { $0 + $1.memoryMiB },
                                       cpus: activeProfiles.reduce(0) { $0 + $1.cpus },
                                       physicalMemoryMiB: hostMemoryMiB, logicalCPUs: logicalCPUs)
        }
        if let port = profile.ssh?.hostPort {
            guard !profiles.contains(where: { $0.id != vmID && sessions[$0.id] != nil && $0.ssh?.hostPort == port }), portProbe.isAvailable(port) else {
                throw VMFailure(code: "ssh-port-in-use", message: "Mac loopback TCP port \(port) is in use. Stop its other owner before starting this VM; the endpoint was not changed.")
            }
        }
        states[vmID] = .validating
        failures[vmID] = nil
        notices[vmID] = nil
        powerCapabilities[vmID] = nil
        let sessionID = UUID()
        let (events, continuation) = AsyncStream<VMRuntimeEvent>.makeStream()
        sessions[vmID] = Session(id: sessionID, root: root, events: continuation,
                                 coldStart: !TryOmarchyStorage.hasVM(at: root))
        if let restoreVerificationTimeout { sessions[vmID]?.restoreVerificationTimeout = restoreVerificationTimeout }
        record("Start requested", vmID: vmID, sessionID: sessionID)
        do {
            if let error = runtime.preflight() { throw error }
            let request = VMStartRequest(profile: profile, storageRoot: root, sessionID: sessionID, launchIntent: launchIntent)
            let runtime = self.runtime
            let handle = try await Task.detached(priority: .userInitiated) {
                try runtime.start(request) { continuation.yield($0) }
            }.value
            sessions[vmID]?.handle = handle
            if sessions[vmID]?.forceRequested == true { handle.terminate() }
            else if sessions[vmID]?.shutdownRequested == true { handle.shutDown() }
            else { beginSSHProbe(request); beginOwnerProbe(request) }
            Task {
                for await event in events {
                    receive(event, vmID: vmID, sessionID: sessionID)
                }
            }
        } catch {
            continuation.finish()
            sessions[vmID] = nil
            let failure = Self.failure(error)
            failures[vmID] = failure
            states[vmID] = .failed(failure)
            record("Start refused: " + failure.message, vmID: vmID, sessionID: sessionID)
            throw failure
        }
    }

    private func beginOwnerProbe(_ request: VMStartRequest) {
        guard request.profile.ownerSetup != nil else { return }
        sessions[request.profile.id]?.ownerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkOwner(request)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func checkOwner(_ request: VMStartRequest) {
        guard sessions[request.profile.id]?.id == request.sessionID,
              ![.pausing, .paused, .resuming, .hostSleeping, .executionUnknown].contains(states[request.profile.id]) else { return }
        let owner = ManagedOwnerStorage(root: request.storageRoot)
        do {
            if try owner.completed(request.profile) { ownerStates[request.profile.id] = .configured; return }
            guard let report = try OwnerSetupGuestReport.read(request) else { return }
            switch report.state {
            case "configured":
                try owner.finish(request.profile)
                ownerStates[request.profile.id] = .configured
            case "error": ownerStates[request.profile.id] = .failed("Automatic setup failed (" + (report.failureCode ?? "provisioning-failed") + "). Shut down this guest and review the failure before restarting to retry.")
            default: ownerStates[request.profile.id] = .provisioning
            }
        } catch { ownerStates[request.profile.id] = .failed("Cannot verify owner setup or remove its temporary seed. Shut down this guest and review its storage.") }
    }

    private func beginSSHProbe(_ request: VMStartRequest) {
        guard request.profile.ssh != nil, let sshProbe else { return }
        sessions[request.profile.id]?.sshTask?.cancel()
        sessions[request.profile.id]?.powerProbeTask?.cancel()
        powerCapabilities[request.profile.id] = nil
        sshStates[request.profile.id] = .provisioning
        let probeID = UUID()
        sessions[request.profile.id]?.sshProbeID = probeID
        sessions[request.profile.id]?.sshTask = Task { [weak self] in
            await sshProbe.monitor(request) { [weak self] status in
                await self?.receiveSSH(status, vmID: request.profile.id, sessionID: request.sessionID, probeID: probeID)
            }
        }
    }

    func receiveSSH(_ status: SSHReadiness, vmID: UUID, sessionID: UUID, probeID: UUID? = nil) {
        guard let session = sessions[vmID], session.id == sessionID, !session.shutdownRequested, !session.forceRequested, states[vmID] != .stopping,
              probeID == nil || probeID == session.sshProbeID,
              states[vmID] == .running || !session.reachedReady else { return }
        sshStates[vmID] = status
        if case .ready(let user, _) = status { beginPowerProbe(vmID, user: user) }
        else if case .failed = status { powerCapabilities[vmID] = nil }
    }

    public func retrySSH(_ id: UUID) {
        guard let session = sessions[id], states[id] == .running, let profile = profiles.first(where: { $0.id == id }) else { return }
        beginSSHProbe(VMStartRequest(profile: profile, storageRoot: session.root, sessionID: session.id))
    }

    public func pause(_ id: UUID, timeout: Duration = .seconds(10)) async throws {
        guard suspensions[id] == nil, sessions[id]?.powerBusy != true else { throw VMFailure(code: "suspend-in-progress", message: "Finish experimental suspension recovery before pausing.") }
        try await changeExecution(id, command: .pause, timeout: timeout)
    }

    public func resume(_ id: UUID, timeout: Duration = .seconds(10)) async throws {
        try await changeExecution(id, command: .resume, timeout: timeout)
    }

    private func changeExecution(_ id: UUID, command: VMRunCommand, timeout: Duration) async throws {
        guard !quitting, let session = sessions[id], let handle = session.handle, !session.shutdownRequested, !session.forceRequested else {
            throw VMFailure(code: "not-running", message: "The guest has no controllable running session.")
        }
        guard session.executionCommand == nil else { throw VMFailure(code: "execution-busy", message: "An execution command is awaiting its acknowledgement. Wait or shut down the guest.") }
        if command == .pause && states[id] == .paused || command == .resume && states[id] == .running { return }
        guard command == .pause ? states[id] == .running : states[id] == .paused else {
            throw VMFailure(code: "execution-not-ready", message: "Pause requires a running guest; Resume requires a manually paused guest.")
        }
        suspendReadiness(id)
        states[id] = command == .pause ? .pausing : .resuming
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, any Error>) in
            sessions[id]?.executionCommand = command
            sessions[id]?.executionCompletion = completion
            sessions[id]?.executionTimeout = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                await self?.executionTimedOut(id, sessionID: session.id)
            }
            do {
                if command == .pause { try handle.pause() } else { try handle.resume() }
            } catch { executionTimedOut(id, sessionID: session.id) }
        }
    }

    private func executionTimedOut(_ id: UUID, sessionID: UUID) {
        guard sessions[id]?.id == sessionID, sessions[id]?.executionCommand != nil else { return }
        sessions[id]?.executionTimeout?.cancel()
        sessions[id]?.executionTimeout = nil
        let completion = sessions[id]?.executionCompletion
        sessions[id]?.executionCompletion = nil
        if states[id] != .stopping { states[id] = .executionUnknown }
        let failure = VMFailure(code: "execution-timeout", message: "The execution command was not acknowledged. The guest and its reservations remain active; wait for a late reply or shut it down.")
        notices[id] = failure.message
        completion?.resume(throwing: failure)
    }

    private func cancelExecutionChange(_ id: UUID, code: String) {
        sessions[id]?.executionTimeout?.cancel()
        sessions[id]?.executionTimeout = nil
        let completion = sessions[id]?.executionCompletion
        sessions[id]?.executionCompletion = nil
        sessions[id]?.executionCommand = nil
        completion?.resume(throwing: VMFailure(code: code, message: "The guest is stopping or has exited before its execution command completed."))
    }

    private func suspendReadiness(_ id: UUID) {
        sessions[id]?.powerProbeTask?.cancel(); sessions[id]?.powerProbeTask = nil
        powerCapabilities[id] = nil
        sessions[id]?.sshTask?.cancel(); sessions[id]?.ownerTask?.cancel()
        sessions[id]?.sshProbeID = UUID()
        sshStates[id] = profiles.first(where: { $0.id == id })?.ssh == nil ? .disabled : .paused
    }

    private func receiveExecution(_ report: VMRunExecutionReport, vmID: UUID) {
        guard let session = sessions[vmID], states[vmID] != .stopping, !session.shutdownRequested, !session.forceRequested else { return }
        if let command = report.command {
            guard session.executionCommand == command else { return }
            guard report.failure != nil || (command == .pause && report.state == .paused) || (command == .resume && report.state == .running) else {
                executionTimedOut(vmID, sessionID: session.id)
                return
            }
            sessions[vmID]?.executionTimeout?.cancel()
            sessions[vmID]?.executionTimeout = nil
            sessions[vmID]?.executionCommand = nil
            let completion = sessions[vmID]?.executionCompletion
            sessions[vmID]?.executionCompletion = nil
            if let failure = report.failure {
                let error = VMFailure(code: failure.reportedCode, message: failure.message)
                notices[vmID] = error.message
                completion?.resume(throwing: error)
            } else { notices[vmID] = nil; completion?.resume() }
        } else if session.executionCommand != nil { return }
        let previous = states[vmID]
        switch report.state {
        case .running: states[vmID] = .running
        case .paused: states[vmID] = .paused
        case .hostSleeping: states[vmID] = .hostSleeping
        case .unknown: states[vmID] = .executionUnknown
        }
        if report.state != .running { suspendReadiness(vmID) }
        else if previous != .running, let profile = profiles.first(where: { $0.id == vmID }) {
            let request = VMStartRequest(profile: profile, storageRoot: session.root, sessionID: session.id, startedAt: .distantPast)
            beginSSHProbe(request); sessions[vmID]?.ownerTask?.cancel(); beginOwnerProbe(request)
        }
    }

    public func shutDown(_ vmID: UUID) {
        guard var session = sessions[vmID], !session.shutdownRequested else { return }
        session.shutdownRequested = true
        sessions[vmID] = session
        states[vmID] = .stopping
        cancelExecutionChange(vmID, code: "guest-stopping")
        suspendReadiness(vmID)
        session.handle?.shutDown()
    }

    public func forceStop(_ vmID: UUID, confirmed: Bool) throws {
        guard confirmed else {
            throw VMFailure(code: "confirmation-required", message: "Force Stop can lose unsaved guest work.")
        }
        guard var session = sessions[vmID], !session.forceRequested else { return }
        session.forceRequested = true
        sessions[vmID] = session
        states[vmID] = .stopping
        cancelExecutionChange(vmID, code: "guest-stopping")
        suspendReadiness(vmID)
        session.handle?.terminate()
    }

    public func prepareToQuitIfIdle() -> Bool {
        guard isIdle else { return false }
        quitting = true
        return true
    }

    public func beginApplicationShutdown() -> Bool {
        guard !hasActiveSuspensionTransition else { return false }
        quitting = true
        factoryImportOperation?.task.cancel()
        for vmID in Array(sessions.keys) { shutDown(vmID) }
        return isIdle
    }

    func receive(_ event: VMRuntimeEvent, vmID: UUID, sessionID: UUID) {
        guard let session = sessions[vmID], session.id == sessionID else { return }
        record(Self.describe(event), vmID: vmID, sessionID: sessionID)
        switch event {
        case .progress(let phase, let percent):
            guard !session.reachedReady, states[vmID] != .stopping else { return }
            switch phase {
            case .waitingForDownload, .downloading, .reconnecting, .paused, .verifyingDownload:
                states[vmID] = .downloading(phase: phase, percent: percent)
            default:
                states[vmID] = .starting(phase: phase, percent: percent)
            }
        case .notice(let notice):
            notices[vmID] = notice.message
        case .displayReady:
            break
        case .ready:
            guard !session.reachedReady else { return }
            sessions[vmID]?.reachedReady = true
            if states[vmID] != .stopping {
                states[vmID] = .running
                if case .ready(let user, _) = sshStates[vmID] { beginPowerProbe(vmID, user: user) }
                if suspensions[vmID]?.stage == .restoring { beginRestoreVerification(vmID) }
            }
        case .executionState(let report):
            receiveExecution(report, vmID: vmID)
        case .stopping:
            states[vmID] = .stopping
            cancelExecutionChange(vmID, code: "guest-stopping")
            suspendReadiness(vmID)
        case .error(let error):
            failures[vmID] = VMFailure(code: error.reportedCode, message: error.message)
        case .exited(let status):
            cancelExecutionChange(vmID, code: "guest-exited")
            session.sshTask?.cancel()
            session.ownerTask?.cancel()
            session.powerProbeTask?.cancel(); session.powerOperationTask?.cancel()
            powerCapabilities[vmID] = nil
            finishSuspensionExit(vmID, status: status, forced: session.forceRequested)
            if let profile = profiles.first(where: { $0.id == vmID }), profile.ownerSetup != nil {
                checkOwner(VMStartRequest(profile: profile, storageRoot: session.root, sessionID: sessionID, startedAt: .distantPast))
                do { try ManagerStorage(applicationSupport: applicationSupport).withLock(profile) { try ManagedOwnerStorage(root: session.root).clearSeed() } }
                catch { failures[vmID] = VMFailure(code: "owner-seed-cleanup", message: "The guest stopped, but its temporary setup seed could not be removed.") }
            }
            sshStates[vmID] = profiles.first(where: { $0.id == vmID })?.ssh == nil ? .disabled : .stopped
            if failures[vmID] == nil, status != 0, !session.forceRequested {
                failures[vmID] = VMFailure(code: "helper-exit-\(status)", message: "The helper exited with status \(status).")
            }
            if let failure = failures[vmID] {
                failures[vmID] = VMFailure(code: failure.code, message: failure.message,
                                           diagnostics: session.handle?.recentStandardError ?? "")
            }
            session.events.finish()
            sessions[vmID] = nil
            if let failure = failures[vmID] { states[vmID] = .failed(failure) }
            else { states[vmID] = .stopped }
        }
    }

    private static func describe(_ event: VMRuntimeEvent) -> String {
        switch event {
        case .progress(let phase, let percent): "\(phase.rawValue)" + (percent.map { " \($0)%" } ?? "")
        case .notice(let notice): "Notice: " + notice.message
        case .ready: "Ready"
        case .displayReady: "Display ready"
        case .executionState(let report): "Execution: " + report.state.rawValue + (report.command.map { " (" + $0.rawValue + ")" } ?? "")
        case .stopping: "Stopping"
        case .error(let error): "Error [\(error.reportedCode)]: " + error.message
        case .exited(let status): "Exited (\(status))"
        }
    }

    private static func failure(_ error: any Error) -> VMFailure {
        if let failure = error as? VMFailure { return failure }
        if let error = error as? VMRunError { return VMFailure(code: error.reportedCode, message: error.message) }
        return VMFailure(code: "start-failed", message: error.localizedDescription)
    }
}

extension VMManager {
    public var hasActiveSuspensionTransition: Bool {
        sessions.contains { id, session in suspensions[id] != nil || session.powerBusy }
    }
    private func beginPowerProbe(_ id: UUID, user: String) {
        guard let hibernation, let session = sessions[id], session.powerProbeTask == nil,
              states[id] == .running, !session.shutdownRequested, !session.forceRequested,
              let profile = profiles.first(where: { $0.id == id }), suspensions[id] == nil else { return }
        let request = VMStartRequest(profile: profile, storageRoot: session.root, sessionID: session.id)
        let generation = session.sshProbeID
        sessions[id]?.powerProbeTask = Task { [weak self] in
            let report = try? await hibernation.capability(request, user: user)
            guard !Task.isCancelled else { return }
            await self?.receivePowerCapability(report, request: request, generation: generation)
        }
    }
    private func receivePowerCapability(_ value: GuestHibernationCapability?, request: VMStartRequest, generation: UUID) {
        let id = request.profile.id
        guard let session = sessions[id], session.id == request.sessionID, session.sshProbeID == generation,
              states[id] == .running, !session.shutdownRequested, !session.forceRequested else { return }
        powerCapabilities[id] = value
        sessions[id]?.powerProbeTask = nil
    }
    public func experimentalSuspend(_ id: UUID, confirmed: Bool, exitTimeout: Duration = .seconds(180)) async throws {
        guard confirmed else { throw VMFailure(code: "experimental-opt-in-required", message: "Confirm the experimental suspension risks before attempting it.") }
        guard let hibernation, let session = sessions[id], states[id] == .running, !session.shutdownRequested, !session.forceRequested,
              !session.powerBusy, suspensions[id] == nil, !unsafeSuspensions.contains(id),
              let profile = profiles.first(where: { $0.id == id }), case .ready(let user, _) = sshStates[id] else {
            throw VMFailure(code: "suspend-not-ready", message: "Experimental suspension requires a running guest and authenticated managed SSH.")
        }
        sessions[id]?.powerBusy = true
        defer { if sessions[id]?.id == session.id { sessions[id]?.powerBusy = false } }
        let request = VMStartRequest(profile: profile, storageRoot: session.root, sessionID: session.id)
        let capability = try await hibernation.capability(request, user: user)
        try requirePowerSession(id, session: session.id)
        powerCapabilities[id] = capability
        guard capability.canAttempt else { throw VMFailure(code: "hibernation-unavailable", message: capability.detail) }
        let proof = try await hibernation.prepare(request, user: user, token: UUID())
        try requirePowerSession(id, session: session.id)
        guard proof.kernel == capability.kernel else { throw SSHGuestHibernation.failure() }
        let storage = ManagerStorage(applicationSupport: applicationSupport)
        let record = ExperimentalSuspension(schemaVersion: 1, vmID: id, originSession: session.id, user: user, proof: proof,
            profileDigest: try ExperimentalSuspendStore.digest(profile), runtimeDigest: RuntimePin.lockSHA256,
            diskIdentity: try storage.suspensionIdentity(profile), stage: .requested)
        // Publish the guard durably before asking the guest to do anything privileged.
        do { try ExperimentalSuspendStore(root: session.root).save(record, exclusively: true) }
        catch { unsafeSuspensions.insert(id); throw error }
        suspensions[id] = record
        notices[id] = "Experimental suspension requested. RAM remains allocated until the VM exits."
        sessions[id]?.powerOperationTask = Task { [weak self] in
            do { try await Task.sleep(for: exitTimeout) } catch { return }
            await self?.suspensionTimedOut(id, sessionID: session.id)
        }
        do { try await hibernation.hibernate(request, user: user) }
        catch {
            if sessions[id] == nil, suspensions[id]?.originSession == session.id, suspensions[id]?.stage == .restorePending { return }
            // Lost SSH is ambiguous: the kernel may already be freezing or saving.
            if sessions[id]?.id == session.id { suspensionTimedOut(id, sessionID: session.id) }
            throw VMFailure(code: "suspend-request-unverified", message: "The hibernation request could not be acknowledged. The guest may still be suspending; its disk remains protected. No automatic force-stop was sent.")
        }
    }
    private func requirePowerSession(_ id: UUID, session: UUID) throws {
        guard let current = sessions[id], current.id == session, !current.shutdownRequested, !current.forceRequested, states[id] == .running else {
            throw VMFailure(code: "guest-stopping", message: "The guest changed or stopped before hibernation could be requested.")
        }
    }
    private func suspensionTimedOut(_ id: UUID, sessionID: UUID) {
        guard sessions[id]?.id == sessionID, var record = suspensions[id] else { return }
        record.stage = .recoveryRequired; persistSuspension(record)
        notices[id] = record.restoreAttempted
            ? "Restore verification could not finish. Keep the guest running and use Recheck Recovery. Stopping an unresolved restore requires manual recovery."
            : "Experimental suspension did not finish reliably. The VM retains its allocation until exit. Shut down or force-stop explicitly if stalled, then use Restore / Recover."
    }
    private func persistSuspension(_ record: ExperimentalSuspension) {
        guard let profile = profiles.first(where: { $0.id == record.vmID }) else { return }
        suspensions[record.vmID] = record
        do { try ExperimentalSuspendStore(root: ManagerStorage(applicationSupport: applicationSupport).root(for: profile)).save(record) }
        catch { unsafeSuspensions.insert(record.vmID); notices[record.vmID] = "Suspension metadata could not be saved. Disk protection is retained; explicit recovery is required." }
    }
    private func finishSuspensionExit(_ id: UUID, status: Int32, forced: Bool) {
        guard var record = suspensions[id], let profile = profiles.first(where: { $0.id == id }) else { return }
        let storage = ManagerStorage(applicationSupport: applicationSupport)
        if record.stage != .coldBootDetected {
            record.stage = status == 0 && !forced && record.stage == .requested ? .restorePending : .recoveryRequired
        }
        do {
            record.diskStamp = try storage.withLock(profile) { try storage.suspensionStamp(profile) }
            persistSuspension(record)
        } catch { unsafeSuspensions.insert(id); notices[id] = "The stopped suspension disk could not be identified safely. Ordinary launch and edits remain blocked." }
    }
    public func restoreExperimentalSuspension(_ id: UUID, confirmed: Bool, verificationTimeout: Duration = .seconds(180), launchIntent: VMLaunchIntent = .background) async throws {
        guard confirmed, hibernation != nil, var record = suspensions[id], !unsafeSuspensions.contains(id),
              sessions[id] == nil, let profile = profiles.first(where: { $0.id == id }) else {
            throw VMFailure(code: "restore-not-ready", message: "Confirm recovery of one stopped experimental suspension.")
        }
        guard !record.restoreAttempted else {
            throw VMFailure(code: "restore-already-attempted", message: "A previous restore was not resolved. Recheck the running guest, or obtain manual recovery; another boot could apply stale memory to a changed filesystem.")
        }
        let storage = ManagerStorage(applicationSupport: applicationSupport)
        try storage.withLock(profile) {
            let digest = try ExperimentalSuspendStore.digest(profile)
            let identity = try storage.suspensionIdentity(profile)
            let stamp = try storage.suspensionStamp(profile)
            guard record.runtimeDigest == RuntimePin.lockSHA256, record.profileDigest == digest,
                  record.diskIdentity == identity, record.diskStamp == nil || record.diskStamp == stamp else {
                throw VMFailure(code: "suspension-changed", message: "The runtime, configuration or saved-session disk changed. Automatic restore was refused.")
            }
        }
        record.stage = .restoring; record.restoreAttempted = true
        try ExperimentalSuspendStore(root: storage.root(for: profile)).save(record); suspensions[id] = record
        do { try await start(id, restoreVerificationTimeout: verificationTimeout, launchIntent: launchIntent) }
        catch { record.stage = .recoveryRequired; record.restoreAttempted = false; persistSuspension(record); throw error }
    }
    public func retryExperimentalRestoreVerification(_ id: UUID) throws {
        guard let session = sessions[id], states[id] == .running, !session.shutdownRequested, !session.forceRequested,
              var record = suspensions[id], record.restoreAttempted, record.stage == .recoveryRequired else {
            throw VMFailure(code: "restore-check-unavailable", message: "A running unresolved restore is required for a read-only recheck.")
        }
        record.stage = .restoring; persistSuspension(record)
        sessions[id]?.powerOperationTask?.cancel(); beginRestoreVerification(id)
    }
    private func beginRestoreVerification(_ id: UUID) {
        guard let hibernation, let session = sessions[id], let record = suspensions[id], record.stage == .restoring,
              let profile = profiles.first(where: { $0.id == id }) else { return }
        let request = VMStartRequest(profile: profile, storageRoot: session.root, sessionID: session.id)
        let deadline = ContinuousClock.now.advanced(by: session.restoreVerificationTimeout)
        sessions[id]?.powerOperationTask = Task { [weak self] in
            while ContinuousClock.now < deadline {
                if Task.isCancelled { return }
                if let result = try? await hibernation.verifyRestore(request, user: record.user, origin: record.originSession, proof: record.proof) {
                    await self?.receiveRestore(result, vmID: id, sessionID: session.id); return
                }
                do { try await Task.sleep(until: min(deadline, ContinuousClock.now.advanced(by: .seconds(2))), clock: .continuous) } catch { return }
            }
            await self?.suspensionTimedOut(id, sessionID: session.id)
        }
    }
    private func receiveRestore(_ result: GuestRestoreResult, vmID id: UUID, sessionID: UUID) {
        guard let session = sessions[id], session.id == sessionID, !session.shutdownRequested, !session.forceRequested,
              states[id] == .running, var record = suspensions[id] else { return }
        switch result {
        case .restored:
            do {
                try ExperimentalSuspendStore(root: session.root).remove(record); suspensions[id] = nil; unsafeSuspensions.remove(id)
                notices[id] = "Experimental memory restoration verified. Desktop, devices and fresh SSH readiness still require checks."
                if case .ready(let user, _) = sshStates[id] { beginPowerProbe(id, user: user) }
            } catch { unsafeSuspensions.insert(id) }
        case .coldBoot:
            record.stage = .coldBootDetected; persistSuspension(record)
            notices[id] = "The guest cold-booted; its previous memory/session was not restored. Have a guest administrator clear any stale resume image, then acknowledge this running cold boot before returning to normal management."
        }
    }
    public func acceptExperimentalColdBoot(_ id: UUID, confirmed: Bool, guestImageCleared: Bool = false) throws {
        guard confirmed, guestImageCleared, let record = suspensions[id], record.stage == .coldBootDetected, let session = sessions[id],
              states[id] == .running, !session.shutdownRequested, !session.forceRequested else {
            throw VMFailure(code: "recovery-not-verified", message: "A running, verified cold boot and explicit confirmation that a guest administrator cleared any stale resume image are required before releasing saved-session protection.")
        }
        try ExperimentalSuspendStore(root: session.root).remove(record); suspensions[id] = nil; unsafeSuspensions.remove(id)
        notices[id] = "Cold boot acknowledged. The previous session was not restored."
        if case .ready(let user, _) = sshStates[id] { beginPowerProbe(id, user: user) }
    }
}
