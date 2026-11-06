import AppKit
@preconcurrency import ApplicationServices
import Darwin
import Foundation
import OmarchyVMManagerCore
import TryOmarchyKitClient

struct DeletionReview: Identifiable {
    let id: UUID
    let name: String
    let identity: String?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var factoryImportInProgress = false
    @Published var factoryImportProgress = FactoryImportProgress.verifying
    @Published private var factoryLibrary = FactoryLibraryCache()
    var factories: [FactoryIdentity] { factoryLibrary.factories }
    var factorySelectionNotice: String? { factoryLibrary.selectionNotice }
    @Published var ownerDefaults: OwnerDefaults?
    @Published var diskDefaults = DiskDefaults()
    @Published var defaultsError: String?
    @Published private var passwordUpgrade: (reference: UUID, result: OwnerPasswordUpgradeResult)?
    var passwordUpgradeResult: OwnerPasswordUpgradeResult? {
        guard let passwordUpgrade, passwordUpgrade.reference == ownerDefaults?.credentialReference else { return nil }
        return passwordUpgrade.result
    }
    @Published var diagnostics: KitDiagnostics?
    @Published var diagnosticError: String?
    @Published var registryError: String?
    @Published private(set) var isLoading = true
    @Published var checking = true
    @Published var snapshots: [VMSnapshot] = []
    @Published var records: [VMLifecycleRecord] = []
    @Published var shuttingDown = false
    @Published var actionError: String?
    @Published var forceStopID: UUID?
    @Published var experimentalPowerReview: ExperimentalPowerReview?
    @Published var homeBackupReview: VMSnapshot?
    @Published var configurationError: String?
    @Published var deletionReview: DeletionReview?
    @Published var accessibilityTrusted = false
    @Published var storageBytes: [UUID: Int64] = [:]
    let manager: VMManager
    private let support: URL
    private var observedFactoryRevision: UUID?
    private var factoryImportID: UUID?
    private var commandServer: ManagerCommandServer?
    private var provisioningService: ProvisioningService?
    private var setupServer: ProvisioningExternalServer?
    @Published var setupWorkflows: [ProvisioningWorkflowSnapshot] = []
    @Published var setupJobs: [UUID: ProvisioningJobSnapshot] = [:]
    #if DEBUG
    private var isolatedService: (any ProvisioningObserving)?
    private var isolatedSave: (@MainActor (GuestConfigurationPatch, ProvisioningCreationConsent?) async throws -> VMProfile)?
    private var isolated = false
    init(isolatedManager: VMManager, support: URL, snapshots: [VMSnapshot], service: (any ProvisioningObserving)?,
         save: @escaping @MainActor (GuestConfigurationPatch, ProvisioningCreationConsent?) async throws -> VMProfile) {
        manager = isolatedManager; self.support = support; self.snapshots = snapshots
        isolatedService = service; isolatedSave = save; isolated = true; checking = false; isLoading = false
    }
    #endif
    var setupService: (any ProvisioningObserving)? {
        #if DEBUG
        if isolated { return isolatedService }
        #endif
        return provisioningService
    }
    func setupSummary(for vmID: UUID) -> (title: String, cleanupRequired: Bool)? {
        let rows = setupWorkflows.filter { $0.vmID == vmID }
        guard let row = rows.first(where: { $0.cleanupRequired }) ?? rows.first(where: { $0.canCancel }) ?? rows.first else { return nil }
        // UUID ordering is not chronology. Never present an arbitrary historical
        // failure as the current result when several completed runs exist.
        let title = rows.count > 1 && !row.cleanupRequired && !row.canCancel ? "Setup history (\(rows.count) runs)" : row.title
        return (title, row.cleanupRequired)
    }
    /// Guests whose setup was observed finishing while this manager ran. Home
    /// shows a dismissible completion line for these; nothing is persisted.
    @Published var setupCompletedThisRun: Set<UUID> = []
    func noteSetupCompletions(previous: [ProvisioningWorkflowSnapshot], current: [ProvisioningWorkflowSnapshot]) {
        let before = Dictionary(previous.map { ($0.id, $0.stage) }, uniquingKeysWith: { first, _ in first })
        for row in current where [.succeeded, .checked].contains(row.stage) {
            if let stage = before[row.id], ![.succeeded, .checked].contains(stage) { setupCompletedThisRun.insert(row.vmID) }
        }
    }
    func cancelSetup(_ id: UUID) async {
        do { try await setupService?.cancel(id) }
        catch { actionError = "Setup cancellation could not be confirmed. Check its job state and cleanup requirement." }
    }
    private var lastReportID: UUID?
    private var lastAccessibilityTrusted: Bool?
    private var lastOwnerStates: [UUID: OwnerSetupReadiness] = [:]
    private var lastSSHStates: [UUID: SSHReadiness] = [:]
    private var storageRefreshed = Date.distantPast

    static var layoutPreview: Bool {
        #if DEBUG
        Bundle.main.object(forInfoDictionaryKey: "OmarchyLayoutPreview") as? Bool == true
        #else
        false
        #endif
    }

    init() {
        accessibilityTrusted = AXIsProcessTrusted()
        if Self.layoutPreview {
            support = FileManager.default.temporaryDirectory.appendingPathComponent("omarchy-layout-preview")
            manager = VMManager(runtime: FakeRuntime(), profiles: [], applicationSupport: support)
            checking = false
            isLoading = false
            return
        }
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
        let kit = TryOmarchyKit.embedded()
        do {
            let data = try Data(contentsOf: Self.lockURL)
            let runtime = TryOmarchyRuntime(managedKit: kit, lockData: data, applicationSupport: support)
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/OmarchyVMStorageHelper")
            manager = try VMManager.open(runtime: runtime, applicationSupport: support, trashService: HelperTrashService(executable: helper))
        } catch {
            registryError = error.localizedDescription
            manager = VMManager(runtime: TryOmarchyRuntime(kit: kit), profiles: [], applicationSupport: support)
        }
    }

    nonisolated static var lockURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/TryOmarchyRuntime.lock.json") }
    nonisolated static func inspect(preflight: () -> VMRunError? = { VMRunClient.preflight() }) throws -> KitDiagnostics {
        return try KitVerifier.inspect(kit: .embedded(), lockData: Data(contentsOf: lockURL), expectedLockSHA256: RuntimePin.lockSHA256, policy: .current, preflight: preflight)
    }

    func refresh() async {
        #if DEBUG
        if isolated { return }
        #endif
        checking = true
        let result = await Task.detached { Result { try AppModel.inspect() } }.value
        switch result {
        case .success(let value): diagnostics = value; diagnosticError = nil
        case .failure(let error): diagnostics = nil; diagnosticError = error.localizedDescription
        }
        checking = false
        if diagnostics != nil {
            do {
                let catalog = try FactoryCatalog(applicationSupport: support, kit: .embedded(), lockData: Data(contentsOf: Self.lockURL))
                await manager.installFactoryCatalog(catalog)
                observedFactoryRevision = await manager.factoryLibraryRevision
                let request = factoryLibrary.beginRefresh()
                do {
                    let listing = try await manager.factoryListing()
                    factoryLibrary.apply(listing, for: request)
                } catch {
                    if factoryLibrary.isCurrent(request) { actionError = error.localizedDescription }
                }
            } catch { actionError = error.localizedDescription }
        }
        await loadDefaults()
        await update()
    }

    func observe() async {
        #if DEBUG
        if isolated { return }
        #endif
        await refresh()
        guard !Task.isCancelled else { return }
        if !Self.layoutPreview, registryError == nil, provisioningService == nil {
            do { provisioningService = try await manager.installProvisioningService(layout: .init(contents: Bundle.main.bundleURL.appendingPathComponent("Contents"))) }
            catch { actionError = "Setup coordination is unavailable. Recovery metadata was preserved." }
        }
        startCommandServer()
        if let provisioningService, setupServer == nil {
            do { setupServer = try ProvisioningExternalServer(endpoint: ManagerCommandEndpoint(applicationSupport: support), service: provisioningService) }
            catch { actionError = "Setup CLI endpoint unavailable. Existing job metadata was preserved." }
        }
        // An empty snapshot list is meaningful only after the first full refresh.
        isLoading = false
        while !Task.isCancelled {
            await update()
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }

    private func startCommandServer() {
        guard !Self.layoutPreview, registryError == nil, commandServer == nil else { return }
        let service = GuestCommandService(manager: manager, applicationSupport: support)
        do {
            commandServer = try ManagerCommandServer(endpoint: ManagerCommandEndpoint(applicationSupport: support)) { request in
                await service.execute(request)
            }
        } catch { actionError = "CLI command server unavailable: " + error.localizedDescription }
    }
    func stopCommandServer() { commandServer?.stop(); commandServer = nil; setupServer?.stop(); setupServer = nil }

    func save(_ profile: VMProfile?, name: String, memoryGiB: Int, cpus: Int, diskGiB: Int,
              clipboard: Bool, guestTouchID: Bool = false, immersive: Bool, sshEnabled: Bool, publicKey: String?, useOwnerDefaults: Bool, factory: String = "official", share: Bool = false, sharePath: String = SharedFolderMapping.defaultPath,
              separateHome: Bool = true, homeDiskGiB: Int = 64, reuseHomeFrom: UUID? = nil, setupSource: ProvisioningSetupSource? = nil, setupRequestID: UUID? = nil) async -> UUID? {
        guard registryError == nil else { return nil }
        configurationError = nil
        var preparingSetup = false
        do {
            let setupConsent: ProvisioningCreationConsent?
            if let setupSource {
                preparingSetup = true
                guard profile == nil, let setupRequestID,
                      let planner = setupService as? any ProvisioningCreationPlanning else { throw ProvisioningReviewFailure.unavailable }
                let review = try await planner.prepareCreation(id: setupRequestID, source: setupSource)
                // The primary Create action confirms the inputs it just froze.
                // This consent saves metadata only; it grants no execution rights.
                setupConsent = .init(reviewID: review.id, reviewIdentity: review.reviewIdentity, acknowledged: true)
                preparingSetup = false
            } else { setupConsent = nil }
            #if DEBUG
            if isolated {
                guard profile == nil, let isolatedSave else { throw ProvisioningReviewFailure.invalid }
                let config = GuestConfigurationPatch(name: name, memoryMiB: memoryGiB * 1024, cpus: cpus, diskGiB: diskGiB,
                    clipboard: clipboard, immersive: immersive, guestTouchID: guestTouchID, ssh: sshEnabled, ownerDefaults: useOwnerDefaults,
                    publicKey: publicKey, factory: factory, inheritDefaultPublicKey: false, share: share, sharePath: sharePath, separateHome: separateHome, homeDiskGiB: separateHome ? homeDiskGiB : nil, reuseHomeFrom: reuseHomeFrom)
                let saved = try await isolatedSave(config, setupConsent)
                if !snapshots.contains(where: { $0.id == saved.id }) { snapshots.append(.init(profile: saved, state: .stopped)) }; return saved.id
            }
            #endif
            let id: UUID
            if var profile {
                guard setupConsent == nil else { throw ProvisioningReviewFailure.invalid }
                profile.name = name; profile.memoryMiB = memoryGiB * 1024; profile.cpus = cpus; profile.diskGiB = diskGiB
                profile.guestTouchIDEnabled = guestTouchID
                if profile.homeDisk != nil { profile.homeDisk?.sizeGiB = homeDiskGiB }
                profile.clipboardEnabled = clipboard; profile.immersiveMode = immersive
                if share || profile.sharedFolder != nil { profile.sharedFolder = try SharedFolderPolicy.mapping(path: sharePath, enabled: share) }
                try await manager.configure(profile); id = profile.id
            } else {
                id = try await manager.create(name: name, memoryMiB: memoryGiB * 1024, cpus: cpus, diskGiB: diskGiB,
                                              clipboardEnabled: clipboard, guestTouchIDEnabled: guestTouchID, immersiveMode: immersive, sshEnabled: sshEnabled,
                                              publicKey: publicKey, useOwnerDefaults: useOwnerDefaults, inheritDefaultPublicKey: false, factory: factory,
                                              sharedFolder: share ? try SharedFolderPolicy.mapping(path: sharePath) : nil,
                                              separateHome: separateHome, homeDiskGiB: separateHome ? homeDiskGiB : nil, reuseHomeFrom: reuseHomeFrom, setupConsent: setupConsent)
            }
            storageRefreshed = .distantPast
            await update(); return id
        } catch {
            if preparingSetup {
                if error as? ProvisioningReviewFailure == .conflictingProfiles {
                    configurationError = "These profiles have conflicting settings. Choose a compatible combination or resolve the settings in a local vm.yml."
                } else if error as? ProvisioningReviewFailure == .unavailable {
                    configurationError = "Developer setup is unavailable. Choose Source: None to create this VM without it."
                } else {
                    configurationError = ProvisioningAppearance.failureMessage(error) ?? "Could not prepare developer setup. Check the configuration and referenced files, then try Create VM again. No VM was created."
                }
            } else { configurationError = error.localizedDescription }
            return nil
        }
    }

    func importFactory(from url: URL) async throws -> FactoryIdentity {
        guard registryError == nil, !factoryImportInProgress, !shuttingDown else { throw VMFailure(code: "factory-import-unavailable", message: "A factory import is already running or the manager is unavailable.") }
        let importID = UUID()
        factoryImportID = importID
        factoryImportInProgress = true
        factoryImportProgress = .verifying
        defer { factoryImportInProgress = false; factoryImportID = nil }
        let identity = try await manager.importFactory(url) { [weak self] progress in
            Task { @MainActor in
                guard let self, self.factoryImportID == importID else { return }
                self.factoryImportProgress = progress
            }
        }
        factoryLibrary.imported(identity)
        return identity
    }

    func loadFactories() async {
        let request = factoryLibrary.beginRefresh()
        do {
            let listing = try await manager.factoryListing()
            factoryLibrary.apply(listing, for: request)
        } catch {
            if factoryLibrary.isCurrent(request) { configurationError = error.localizedDescription }
        }
    }

    func loadDefaults() async {
        do { diskDefaults = try await manager.diskDefaults(); ownerDefaults = try await manager.guestDefaults(); defaultsError = nil }
        catch { defaultsError = error.localizedDescription }
    }
    func saveDiskDefaults(_ value: DiskDefaults) async -> Bool {
        do { try await manager.saveDiskDefaults(value); diskDefaults = value; defaultsError = nil; return true }
        catch { defaultsError = error.localizedDescription; return false }
    }
    func saveDefaults(configuration: OwnerConfiguration, password: Data?, publicKey: String?) async -> Bool {
        do {
            ownerDefaults = try await manager.saveGuestDefaults(configuration: configuration, password: password, sshPublicKey: publicKey)
            defaultsError = nil; return true
        } catch { defaultsError = error.localizedDescription; return false }
    }

    func upgradeSavedGuestPassword() async -> Bool {
        do {
            let reference = ownerDefaults?.credentialReference
            let result = try await manager.upgradeSavedGuestPassword()
            if let reference { passwordUpgrade = (reference, result) }
            defaultsError = nil; return true
        } catch { defaultsError = error.localizedDescription; return false }
    }

    func start(_ id: UUID) async {
        guard registryError == nil else { return }
        do { try await manager.start(id, launchIntent: .foreground) } catch { actionError = error.localizedDescription }
        await update()
    }
    func recheckExperimentalRecovery(_ id: UUID) async {
        do { try await manager.retryExperimentalRestoreVerification(id) } catch { actionError = error.localizedDescription }
        await update()
    }
    func experimentalPower(_ review: ExperimentalPowerReview) async {
        do {
            switch review.action {
            case .suspend: try await manager.experimentalSuspend(review.id, confirmed: true)
            case .restore: try await manager.restoreExperimentalSuspension(review.id, confirmed: true, launchIntent: .foreground)
            case .acceptColdBoot: try await manager.acceptExperimentalColdBoot(review.id, confirmed: true, guestImageCleared: true)
            }
        } catch { actionError = error.localizedDescription }
        await update()
    }

    func pause(_ id: UUID) async {
        do { try await manager.pause(id) } catch { actionError = error.localizedDescription }
        await update()
    }
    func resume(_ id: UUID) async {
        do { try await manager.resume(id) } catch { actionError = error.localizedDescription }
        await update()
    }
    func retrySSH(_ id: UUID) async { await manager.retrySSH(id); await update() }
    func beginHomeBackup(_ id: UUID) async {
        do { try await manager.beginHomeBackup(id, confirmed: true) }
        catch { actionError = error.localizedDescription }
        await update()
    }
    func cancelHomeBackup(_ id: UUID) async { await manager.cancelHomeBackup(id); await update() }
    func stop(_ id: UUID) async { await manager.shutDown(id); await update() }
    func forceStop(_ id: UUID) async {
        do { try await manager.forceStop(id, confirmed: true) } catch { actionError = error.localizedDescription }
        await update()
    }
    func reviewDeletion(_ snapshot: VMSnapshot) async {
        do {
            let request = try await manager.deletionRequest(snapshot.id)
            deletionReview = DeletionReview(id: snapshot.id, name: snapshot.profile.name, identity: request?.expectedIdentity)
        } catch { actionError = error.localizedDescription }
    }
    func delete(_ review: DeletionReview) async {
        do { try await manager.delete(review.id, confirmed: true, expectedIdentity: review.identity) }
        catch { actionError = error.localizedDescription }
        storageRefreshed = .distantPast; await update()
    }

    func requestSuperShortcuts() async {
        guard await manager.isIdle else { actionError = "Shut down the VMs before refreshing Accessibility access."; return }
        guard !AXIsProcessTrusted() else { await update(); return }
        guard ManagerAccessibilityPermissionRepair.resetCurrentAppEntry() else { actionError = "macOS could not refresh this manager’s Accessibility entry."; return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
        }
        await update()
    }

    private func update() async {
        #if DEBUG
        if isolated { return }
        #endif
        let observation = await manager.observation()
        if observedFactoryRevision != observation.factoryRevision {
            observedFactoryRevision = observation.factoryRevision
            Task { await loadFactories() }
        }
        snapshots = observation.snapshots; records = observation.records
        if let provisioningService {
            let workflows = await provisioningService.statuses()
            noteSetupCompletions(previous: setupWorkflows, current: workflows)
            setupWorkflows = workflows
            var jobs: [UUID: ProvisioningJobSnapshot] = [:]
            for workflow in setupWorkflows { jobs[workflow.id] = await provisioningService.jobStatus(workflow.id) }
            setupJobs = jobs
        }
        accessibilityTrusted = AXIsProcessTrusted()
        if Date().timeIntervalSince(storageRefreshed) > 10 {
            storageRefreshed = Date()
            let profiles = snapshots.map(\.profile), support = support
            storageBytes = await Task.detached {
                Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, TryOmarchyStorage.allocatedBytes(at: POCProfiles.root(for: $0, applicationSupport: support))) })
            }.value
        }
        let ownerStates = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.ownerSetupReadiness) })
        let sshStates = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.sshReadiness) })
        guard registryError == nil, records.last?.id != lastReportID || accessibilityTrusted != lastAccessibilityTrusted || sshStates != lastSSHStates || ownerStates != lastOwnerStates else { return }
        lastOwnerStates = ownerStates
        lastSSHStates = sshStates
        lastReportID = records.last?.id; lastAccessibilityTrusted = accessibilityTrusted
        do { try writeReport() } catch { actionError = "Cannot save session evidence: " + error.localizedDescription }
    }

    private func writeReport() throws {
        let logs = ManagerStorage(applicationSupport: support).directory.appendingPathComponent("Logs")
        if mkdir(logs.path, 0o700) != 0, errno != EEXIST { throw CocoaError(.fileWriteUnknown) }
        try PrivateFiles.directory(logs)
        let object: [String: Any] = [
            "format": 1, "processID": ProcessInfo.processInfo.processIdentifier,
            "accessibilityTrusted": accessibilityTrusted, "updated": ISO8601DateFormatter().string(from: Date()),
            "vms": snapshots.map { s -> [String: Any] in
                var row: [String: Any] = ["id": s.id.uuidString, "name": s.profile.name, "state": s.state.label,
                    "root": POCProfiles.root(for: s.profile, applicationSupport: support).path,
                    "active": s.sessionID != nil, "memoryMiB": s.profile.memoryMiB, "cpus": s.profile.cpus]
                row["sshStatus"] = s.sshReadiness.label
                row["ownerSetupStatus"] = s.ownerSetupReadiness.label
                row["sessionID"] = s.sessionID?.uuidString; row["error"] = s.lastFailure?.message
                row["stderr"] = s.lastFailure?.diagnostics
                return row
            },
            "events": records.map { ["at": ISO8601DateFormatter().string(from: $0.date), "vmID": $0.vmID.uuidString, "sessionID": $0.sessionID.uuidString, "event": $0.text] }
        ]
        let path = logs.appendingPathComponent("POC-status.json")
        var info = stat()
        if lstat(path.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG { throw CocoaError(.fileWriteUnknown) }
        let temporary = logs.appendingPathComponent(".manager-report-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd); unlink(temporary.path) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
        guard rename(temporary.path, path.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func requestQuit() async {
        await manager.cancelFactoryImportAndWait()
        await manager.waitForFactoryDeletion()
        if await manager.hasActiveSuspensionTransition {
            actionError = "An experimental suspension or restore is unresolved. Let it finish, or explicitly stop that guest and preserve its guarded state before quitting."
            NSApplication.shared.reply(toApplicationShouldTerminate: false); return
        }
        if await manager.prepareToQuitIfIdle() { NSApplication.shared.reply(toApplicationShouldTerminate: true); return }
        let alert = NSAlert()
        alert.messageText = "Shut down the VMs and quit?"
        alert.informativeText = "The manager will cancel backups and wait for all VM helpers, backup workers and storage transactions to finish."
        alert.addButton(withTitle: "Shut Down and Quit"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { NSApplication.shared.reply(toApplicationShouldTerminate: false); return }
        shuttingDown = true; _ = await manager.beginApplicationShutdown()
        while !(await manager.isIdle) { await update(); try? await Task.sleep(for: .milliseconds(100)) }
        await update(); NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
}
