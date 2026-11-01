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
    @Published var defaultsError: String?
    @Published var diagnostics: KitDiagnostics?
    @Published var diagnosticError: String?
    @Published var registryError: String?
    @Published var checking = true
    @Published var snapshots: [VMSnapshot] = []
    @Published var records: [VMLifecycleRecord] = []
    @Published var shuttingDown = false
    @Published var actionError: String?
    @Published var forceStopID: UUID?
    @Published var experimentalPowerReview: ExperimentalPowerReview?
    @Published var configurationError: String?
    @Published var deletionReview: DeletionReview?
    @Published var accessibilityTrusted = AXIsProcessTrusted()
    @Published var storageBytes: [UUID: Int64] = [:]
    let manager: VMManager
    private let support: URL
    private var observedFactoryRevision: UUID?
    private var factoryImportID: UUID?
    private var commandServer: ManagerCommandServer?
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
        if Self.layoutPreview {
            support = FileManager.default.temporaryDirectory.appendingPathComponent("omarchy-layout-preview")
            manager = VMManager(runtime: FakeRuntime(), profiles: [], applicationSupport: support)
            checking = false
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
    nonisolated static func inspect() throws -> KitDiagnostics {
        #if DEBUG
        let policy = KitBuildPolicy.debugPOC
        #else
        let policy = KitBuildPolicy.release
        #endif
        return try KitVerifier.inspect(kit: .embedded(), lockData: Data(contentsOf: lockURL), expectedLockSHA256: RuntimePin.lockSHA256, policy: policy)
    }

    func refresh() async {
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
        await refresh()
        startCommandServer()
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
    func stopCommandServer() { commandServer?.stop(); commandServer = nil }

    func save(_ profile: VMProfile?, name: String, memoryGiB: Int, cpus: Int, diskGiB: Int,
              clipboard: Bool, immersive: Bool, sshEnabled: Bool, publicKey: String?, useOwnerDefaults: Bool, factory: String = "official") async -> UUID? {
        guard registryError == nil else { return nil }
        configurationError = nil
        do {
            let id: UUID
            if var profile {
                profile.name = name; profile.memoryMiB = memoryGiB * 1024; profile.cpus = cpus; profile.diskGiB = diskGiB
                profile.clipboardEnabled = clipboard; profile.immersiveMode = immersive
                try await manager.configure(profile); id = profile.id
            } else {
                id = try await manager.create(name: name, memoryMiB: memoryGiB * 1024, cpus: cpus, diskGiB: diskGiB,
                                              clipboardEnabled: clipboard, immersiveMode: immersive, sshEnabled: sshEnabled,
                                              publicKey: publicKey, useOwnerDefaults: useOwnerDefaults, inheritDefaultPublicKey: false, factory: factory)
            }
            storageRefreshed = .distantPast
            await update(); return id
        } catch { configurationError = error.localizedDescription; return nil }
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
        do { ownerDefaults = try await manager.guestDefaults(); defaultsError = nil }
        catch { defaultsError = error.localizedDescription }
    }
    func saveDefaults(enabled: Bool, configuration: OwnerConfiguration, password: Data?, publicKey: String?) async -> Bool {
        do {
            ownerDefaults = try await manager.saveGuestDefaults(enabled: enabled, configuration: configuration, password: password, sshPublicKey: publicKey)
            defaultsError = nil; return true
        } catch { defaultsError = error.localizedDescription; return false }
    }

    func start(_ id: UUID) async {
        guard registryError == nil else { return }
        do { try await manager.start(id) } catch { actionError = error.localizedDescription }
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
            case .restore: try await manager.restoreExperimentalSuspension(review.id, confirmed: true)
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
        let observation = await manager.observation()
        if observedFactoryRevision != observation.factoryRevision {
            observedFactoryRevision = observation.factoryRevision
            Task { await loadFactories() }
        }
        snapshots = observation.snapshots; records = observation.records
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
        let logs = support.appendingPathComponent("Omarchy VM Manager/Logs")
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
        alert.informativeText = "The manager will wait for all VM helpers and storage transactions to finish."
        alert.addButton(withTitle: "Shut Down and Quit"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { NSApplication.shared.reply(toApplicationShouldTerminate: false); return }
        shuttingDown = true; _ = await manager.beginApplicationShutdown()
        while !(await manager.isIdle) { await update(); try? await Task.sleep(for: .milliseconds(100)) }
        await update(); NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
}
