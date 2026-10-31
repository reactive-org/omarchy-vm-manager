import AppKit
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
    @Published var shuttingDown = false
    let manager: VMManager

    init() {
        manager = VMManager(runtime: TryOmarchyRuntime(kit: .embedded()), profiles: POCProfiles.all,
                            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory,
                                                                         in: .userDomainMask)[0])
    }

    nonisolated static func inspect() throws -> KitDiagnostics {
        let lockURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/TryOmarchyRuntime.lock.json")
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
        let result = await Task.detached {
            Result { try AppModel.inspect() }
        }.value
        switch result {
        case .success(let value): diagnostics = value; diagnosticError = nil
        case .failure(let error): diagnostics = nil; diagnosticError = error.localizedDescription
        }
        snapshots = await manager.snapshots()
        checking = false
    }

    func shutDownForQuit() async {
        shuttingDown = true
        _ = await manager.beginApplicationShutdown()
        while await manager.activeSessionCount > 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.snapshots.contains(where: { $0.sessionID != nil }) else { return .terminateNow }
        Task { await model.shutDownForQuit() }
        return .terminateLater
    }
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
                    "kitPath": value.kitPath, "version": value.version,
                    "runProtocolVersion": value.runProtocolVersion, "supported": value.supported,
                    "patchCommit": value.patchCommit, "kitSHA256": value.archiveSHA256,
                    "focusAwareClipboard": value.focusAwareClipboard,
                    "preflight": value.preflightFailure ?? "passed", "vmLaunchEnabled": false
                ]
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(value.preflightFailure == nil ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data("Kit diagnostics failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup("Omarchy VM Manager") {
            ManagerView(model: model)
                .task {
                    delegate.model = model
                    await model.refresh()
                }
        }
        .defaultSize(width: 820, height: 650)
        .windowResizability(.contentMinSize)
    }
}

private struct ManagerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Omarchy VM Manager").font(.largeTitle.bold())
                        Text("0 running · 2 prepared profiles").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("Private POC", systemImage: "hammer")
                        .font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
                GroupBox {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "pause.circle.fill").font(.title2).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Ready for validation; VM launch disabled").font(.headline)
                            Text("The two-VM run needs your approval. No VM storage or factory image has been created by this app.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Prepared VMs").font(.title2.bold())
                    ForEach(model.snapshots) { item in
                        HStack(spacing: 14) {
                            Image(systemName: "desktopcomputer").font(.title).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.profile.name).font(.headline)
                                Text("4 GiB memory · 2 CPUs · Shared networking").foregroundStyle(.secondary)
                                Label("Clipboard enabled", systemImage: "doc.on.clipboard")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.state.label).foregroundStyle(.secondary)
                            Button("Start") {}.disabled(true)
                        }
                        .padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Text("Profiles are fixtures only. UUID storage roots will be initialized after POC approval.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Runtime validation").font(.title2.bold())
                        Spacer()
                        Button("Check again") { Task { await model.refresh() } }.disabled(model.checking)
                    }
                    if model.checking {
                        ProgressView("Checking embedded kit…")
                    } else if let value = model.diagnostics {
                        Label("Pinned kit verified", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            detail("Kit", "\(value.version) · protocol \(value.runProtocolVersion) · supported")
                            detail("Clipboard", value.focusAwareClipboard ? "Focus-aware patch verified" : "Unproven")
                            detail("Host preflight", value.preflightFailure ?? "Passed")
                            detail("Patch commit", value.patchCommit)
                            detail("Archive SHA-256", value.archiveSHA256)
                            detail("Embedded path", value.kitPath)
                        }
                    } else {
                        Label("Kit validation failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(model.diagnosticError ?? "No runtime lock is available.").textSelection(.enabled)
                    }
                }
                Text("Two-guest clipboard, sleep/wake and independent shutdown remain to be proved on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .frame(minWidth: 760, minHeight: 580)
        .sheet(isPresented: $model.shuttingDown) {
            ProgressView("Shutting down VMs…").padding(40)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
