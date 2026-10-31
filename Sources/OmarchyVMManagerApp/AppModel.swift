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
    @Published var diagnostics: KitDiagnostics?
    @Published var diagnosticError: String?
    @Published var registryError: String?
    @Published var checking = true
    @Published var snapshots: [VMSnapshot] = []
    @Published var records: [VMLifecycleRecord] = []
    @Published var shuttingDown = false
    @Published var actionError: String?
    @Published var forceStopID: UUID?
    @Published var configurationError: String?
    @Published var deletionReview: DeletionReview?
    @Published var accessibilityTrusted = AXIsProcessTrusted()
    @Published var storageBytes: [UUID: Int64] = [:]
    let manager: VMManager
    private let support: URL
    private var lastReportID: UUID?
    private var lastAccessibilityTrusted: Bool?
    private var lastSSHStates: [UUID: SSHReadiness] = [:]
    private var storageRefreshed = Date.distantPast

    init() {
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
        await update()
    }

    func observe() async {
        await refresh()
        while !Task.isCancelled {
            await update()
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }

    func save(_ profile: VMProfile?, name: String, memoryGiB: Int, cpus: Int, clipboard: Bool, immersive: Bool, sshEnabled: Bool, publicKey: String?) async -> UUID? {
        guard registryError == nil else { return nil }
        configurationError = nil
        do {
            let id: UUID
            if var profile {
                profile.name = name; profile.memoryMiB = memoryGiB * 1024; profile.cpus = cpus
                profile.clipboardEnabled = clipboard; profile.immersiveMode = immersive
                try await manager.configure(profile); id = profile.id
            } else {
                id = try await manager.create(name: name, memoryMiB: memoryGiB * 1024, cpus: cpus, clipboardEnabled: clipboard, immersiveMode: immersive, sshEnabled: sshEnabled, publicKey: publicKey)
            }
            storageRefreshed = .distantPast
            await update(); return id
        } catch { configurationError = error.localizedDescription; return nil }
    }

    func start(_ id: UUID) async {
        guard registryError == nil else { return }
        do { try await manager.start(id) } catch { actionError = error.localizedDescription }
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
        snapshots = observation.snapshots; records = observation.records
        accessibilityTrusted = AXIsProcessTrusted()
        if Date().timeIntervalSince(storageRefreshed) > 10 {
            storageRefreshed = Date()
            let profiles = snapshots.map(\.profile), support = support
            storageBytes = await Task.detached {
                Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, TryOmarchyStorage.allocatedBytes(at: POCProfiles.root(for: $0, applicationSupport: support))) })
            }.value
        }
        let sshStates = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.sshReadiness) })
        guard registryError == nil, records.last?.id != lastReportID || accessibilityTrusted != lastAccessibilityTrusted || sshStates != lastSSHStates else { return }
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
