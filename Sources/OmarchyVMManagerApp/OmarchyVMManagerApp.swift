import AppKit
@preconcurrency import ApplicationServices
import Darwin
import Foundation
import OmarchyVMManagerCore
import SwiftUI
import TryOmarchyKitClient

@MainActor
final class AppModel: ObservableObject {
    @Published var diagnostics: KitDiagnostics?
    @Published var diagnosticError: String?
    @Published var checking = true
    @Published var snapshots: [VMSnapshot] = []
    @Published var records: [VMLifecycleRecord] = []
    @Published var shuttingDown = false
    @Published var actionError: String?
    @Published var forceStopID: UUID?
    @Published var accessibilityTrusted = AXIsProcessTrusted()
    let approved: Bool
    let manager: VMManager
    private let support: URL
    private var lastReportID: UUID?
    private var lastAccessibilityTrusted: Bool?

    init() {
        approved = CommandLine.arguments.contains("--poc-approved")
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let kit = TryOmarchyKit.embedded()
        let runtime: TryOmarchyRuntime
        if approved, let data = try? Data(contentsOf: Self.lockURL) {
            runtime = TryOmarchyRuntime(approvedPOCKit: kit, lockData: data, applicationSupport: support)
        } else { runtime = TryOmarchyRuntime(kit: kit) }
        manager = VMManager(runtime: runtime, profiles: POCProfiles.all, applicationSupport: support, enforcePOCPolicy: true)
    }

    nonisolated static var lockURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/TryOmarchyRuntime.lock.json")
    }

    nonisolated static func inspect() throws -> KitDiagnostics {
        #if DEBUG
        let policy = KitBuildPolicy.debugPOC
        #else
        let policy = KitBuildPolicy.release
        #endif
        return try KitVerifier.inspect(kit: .embedded(), lockData: Data(contentsOf: lockURL),
                                       expectedLockSHA256: RuntimePin.lockSHA256, policy: policy)
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
        if approved && CommandLine.arguments.contains("--poc-start-a") { await start(POCProfiles.all[0].id) }
        while !Task.isCancelled {
            await update()
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }

    func start(_ id: UUID) async {
        do { try await manager.start(id) }
        catch { actionError = error.localizedDescription }
        await update()
    }

    func stop(_ id: UUID) async { await manager.shutDown(id); await update() }
    func forceStop(_ id: UUID) async {
        do { try await manager.forceStop(id, confirmed: true) }
        catch { actionError = error.localizedDescription }
        await update()
    }

    func requestSuperShortcuts() async {
        guard await manager.activeSessionCount == 0 else {
            actionError = "Shut down the disposable VMs before refreshing Accessibility access."
            return
        }
        guard !AXIsProcessTrusted() else { await update(); return }
        guard ManagerAccessibilityPermissionRepair.resetCurrentAppEntry() else {
            actionError = "macOS could not refresh this manager's Accessibility entry."
            return
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        await update()
    }

    private func update() async {
        let observation = await manager.observation()
        snapshots = observation.snapshots
        records = observation.records
        let accessibilityTrusted = AXIsProcessTrusted()
        if self.accessibilityTrusted != accessibilityTrusted { self.accessibilityTrusted = accessibilityTrusted }
        guard approved,
              records.last?.id != lastReportID || accessibilityTrusted != lastAccessibilityTrusted else { return }
        lastReportID = records.last?.id
        lastAccessibilityTrusted = accessibilityTrusted
        do { try writeReport(accessibilityTrusted: accessibilityTrusted) }
        catch { actionError = "Cannot save POC evidence: " + error.localizedDescription }
    }

    private func writeReport(accessibilityTrusted: Bool) throws {
        let logs = support.appendingPathComponent("Omarchy VM Manager/Logs")
        if mkdir(logs.path, 0o700) != 0, errno != EEXIST { return }
        var info = stat()
        guard lstat(logs.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { return }
        let object: [String: Any] = [
            "format": 1, "processID": ProcessInfo.processInfo.processIdentifier,
            "accessibilityTrusted": accessibilityTrusted,
            "updated": ISO8601DateFormatter().string(from: Date()),
            "vms": snapshots.map { snapshot -> [String: Any] in
                var row: [String: Any] = ["id": snapshot.id.uuidString, "name": snapshot.profile.name,
                    "state": snapshot.state.label, "root": POCProfiles.root(for: snapshot.profile, applicationSupport: support).path,
                    "active": snapshot.sessionID != nil, "memoryMiB": snapshot.profile.memoryMiB, "cpus": snapshot.profile.cpus]
                row["sessionID"] = snapshot.sessionID?.uuidString
                row["error"] = snapshot.lastFailure?.message
                row["stderr"] = snapshot.lastFailure?.diagnostics
                return row
            },
            "events": records.map { ["at": ISO8601DateFormatter().string(from: $0.date), "vmID": $0.vmID.uuidString,
                                      "sessionID": $0.sessionID.uuidString, "event": $0.text] }
        ]
        let path = logs.appendingPathComponent("POC-status.json")
        if lstat(path.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG { return }
        let temporary = logs.appendingPathComponent(".poc-report-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try file.write(contentsOf: JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
        try file.close()
        guard rename(temporary.path, path.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func requestQuit() async {
        if await manager.activeSessionCount == 0 { NSApplication.shared.reply(toApplicationShouldTerminate: true); return }
        let alert = NSAlert()
        alert.messageText = "Shut down the POC VMs and quit?"
        alert.informativeText = "The manager will wait for both disposable VM helpers to exit."
        alert.addButton(withTitle: "Shut Down and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApplication.shared.reply(toApplicationShouldTerminate: false)
            return
        }
        shuttingDown = true
        _ = await manager.beginApplicationShutdown()
        while await manager.activeSessionCount > 0 {
            await update()
            try? await Task.sleep(for: .milliseconds(100))
        }
        await update()
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { await model.requestQuit() }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct OmarchyVMManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--diagnostics-json") {
            do {
                let value = try AppModel.inspect()
                let json: [String: Any] = [
                    "kitPath": value.kitPath, "version": value.version, "runProtocolVersion": value.runProtocolVersion,
                    "supported": value.supported, "patchCommit": value.patchCommit, "kitSHA256": value.archiveSHA256,
                    "focusAwareClipboard": value.focusAwareClipboard, "preflight": value.preflightFailure ?? "passed",
                    "vmLaunchEnabled": CommandLine.arguments.contains("--poc-approved")
                ]
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(value.preflightFailure == nil ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data("Kit diagnostics failed: \(error.localizedDescription)\n".utf8)); exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup("Omarchy VM Manager") {
            ManagerView(model: model).task { delegate.model = model; await model.observe() }
        }
        .defaultSize(width: 900, height: 760)
        .windowResizability(.contentMinSize)
    }
}

private struct ManagerView: View {
    @ObservedObject var model: AppModel
    private var active: [VMSnapshot] { model.snapshots.filter { $0.sessionID != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Omarchy VM Manager").font(.largeTitle.bold())
                        Text("\(active.count) active · \(active.reduce(0) { $0 + $1.profile.memoryMiB } / 1024) GiB allocated")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("Private POC", systemImage: "hammer").padding(10).background(.quaternary, in: Capsule())
                }
                GroupBox {
                    Label(model.approved ? "Disposable POC run approved · NAT · 4 GiB / 4 CPUs per VM" : "VM launch disabled · open with --poc-approved after consent",
                          systemImage: model.approved ? "checkmark.shield" : "pause.circle")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                ForEach(model.snapshots) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "desktopcomputer").font(.title)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.profile.name).font(.headline)
                                Text("\(item.profile.memoryMiB / 1024) GiB · \(item.profile.cpus) CPUs · Clipboard enabled").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.state.label).foregroundStyle(.secondary)
                            if item.sessionID == nil {
                                Button("Start") { Task { await model.start(item.id) } }
                                    .disabled(!model.approved || model.checking || model.diagnostics?.preflightFailure != nil || model.diagnostics == nil)
                            } else {
                                Button("Shut Down") { Task { await model.stop(item.id) } }.disabled(item.state == .stopping)
                                Button("Force Stop") { model.forceStopID = item.id }
                            }
                        }
                        switch item.state {
                        case .downloading(let phase, let percent), .starting(let phase, let percent):
                            HStack {
                                if let percent { ProgressView(value: Double(percent), total: 100) }
                                else { ProgressView().controlSize(.small) }
                                Text(phase.rawValue + (percent.map { " \($0)%" } ?? "")).font(.caption)
                            }
                        default: EmptyView()
                        }
                        if let failure = item.lastFailure {
                            Text(failure.message).foregroundStyle(.red).textSelection(.enabled)
                            if !failure.diagnostics.isEmpty {
                                DisclosureGroup("Helper diagnostics") {
                                    Text(failure.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }
                    }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Super shortcuts").font(.headline)
                        Text(model.accessibilityTrusted ? "Manager Accessibility access is allowed." :
                            "Allow the manager to keep Command+Space and other Mac shortcuts in the focused guest.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !model.accessibilityTrusted && model.snapshots.contains(where: { $0.sessionID != nil }) {
                            Text("Shut down the VMs before refreshing access.").font(.caption)
                        }
                    }
                    Spacer()
                    if !model.accessibilityTrusted {
                        Button("Enable Super shortcuts…") { Task { await model.requestSuperShortcuts() } }
                            .disabled(model.checking || model.snapshots.contains(where: { $0.sessionID != nil }))
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Runtime validation").font(.title2.bold())
                        Spacer()
                        Button("Check again") { Task { await model.refresh() } }.disabled(model.checking)
                    }
                    if model.checking { ProgressView("Checking embedded kit…") }
                    else if let value = model.diagnostics {
                        Label("Pinned focus-aware kit verified · protocol \(value.runProtocolVersion)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("Host preflight: " + (value.preflightFailure ?? "Passed")).font(.caption)
                        Text("Patch: " + value.patchCommit).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    } else { Text(model.diagnosticError ?? "Kit unavailable").foregroundStyle(.red) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Session events").font(.title2.bold())
                    if model.records.isEmpty { Text("No sessions started.").foregroundStyle(.secondary) }
                    ForEach(Array(model.records.suffix(40).reversed())) { record in
                        Text("\(record.date.formatted(date: .omitted, time: .standard)) · \(record.vmID == POCProfiles.all[0].id ? "A" : "B") · \(record.text)")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Text("POC evidence is saved under the manager’s Logs folder. Your existing Try Omarchy VM is outside this manager’s storage roots.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .frame(minWidth: 820, minHeight: 620)
        .sheet(isPresented: $model.shuttingDown) { ProgressView("Shutting down disposable VMs…").padding(40) }
        .alert("Power off this disposable VM?", isPresented: Binding(get: { model.forceStopID != nil }, set: { if !$0 { model.forceStopID = nil } })) {
            Button("Force Stop", role: .destructive) { if let id = model.forceStopID { Task { await model.forceStop(id) }; model.forceStopID = nil } }
            Button("Cancel", role: .cancel) { model.forceStopID = nil }
        } message: { Text("Unsaved guest work can be lost. Prefer Shut Down when the guest responds.") }
        .alert("POC action failed", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: { Text(model.actionError ?? "") }
    }
}
