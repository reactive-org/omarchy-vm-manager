import AppKit
@preconcurrency import ApplicationServices
import Darwin
import Foundation
import OmarchyVMManagerCore
import SwiftUI
import TryOmarchyKitClient

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? {
        didSet {
            guard let model, model !== oldValue else { return }
            model.attentionSurfaces = attention
            if let vmID = pendingAttention { pendingAttention = nil; model.openAttention(vmID) }
        }
    }
    /// Dock and notifications for setup attention, set up before launch finishes
    /// so notification clicks always have a delegate.
    private let attention = SystemAttentionSurfaces()
    /// A notification click that arrived before the window's model was bound.
    private var pendingAttention: UUID?
    func applicationWillFinishLaunching(_ notification: Notification) {
        attention.open = { [weak self] vmID in
            guard let self else { return }
            showManagerWindow()
            if let model { model.openAttention(vmID) } else { pendingAttention = vmID }
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Asked at launch (issue #16); notifications only fire when setup is blocked.
        if !AppModel.layoutPreview { attention.start() }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(activationRequested(_:)),
            name: SingleInstanceApplication.activationNotification, object: nil)
        if let url = Bundle.main.url(forResource: "OmarchyVMManager", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    @objc private func activationRequested(_ notification: Notification) { showManagerWindow() }
    private func showManagerWindow() {
        NSApplication.shared.unhide(nil)
        for window in NSApplication.shared.windows where window.canBecomeMain && !(window is NSPanel) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showManagerWindow()
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { await model.requestQuit() }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { model?.stopCommandServer() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct OmarchyVMManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @StateObject private var updateChecker = UpdateCheckController()
    private let instanceLock: ManagerInstanceLock

    init() {
        // Thin, unsmoothed text like the design's antialiased rendering. macOS otherwise thickens
        // light-on-dark glyph stems, which made the dark manager read as bold. In-process only.
        UserDefaults.standard.register(defaults: ["AppleFontSmoothing": 0])
        BundledFonts.register()
        #if DEBUG
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--accept-factory-screens" {
            do { try FactoryScreenAcceptance.run(output: URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) }
            catch { FileHandle.standardError.write(Data("Factory screen acceptance failed.\n".utf8)); exit(1) }
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--accept-setup-screens" {
            do { try SetupScreenAcceptance.run(output: URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) }
            catch { FileHandle.standardError.write(Data("Setup screen acceptance failed.\n".utf8)); exit(1) }
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-setup-component-fixture" {
            do { try SetupComponentPreview.render(to: URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) }
            catch { FileHandle.standardError.write(Data("Offscreen setup fixture could not be rendered.\n".utf8)); exit(1) }
        }
        #endif
        do {
            try AppChannel.current.validateBundle(identifier: Bundle.main.bundleIdentifier, layoutPreview: AppModel.layoutPreview)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
        }
        let bundleOnly = CommandLine.arguments.contains("--verify-bundle-json")
        if bundleOnly || CommandLine.arguments.contains("--diagnostics-json") {
            do {
                let value = try AppModel.inspect(preflight: { bundleOnly ? nil : VMRunClient.preflight() })
                let provisioning = try BundledProvisioning.inspect(ProvisioningPackageLayout(contents: Bundle.main.bundleURL.appendingPathComponent("Contents")))
                let json: [String: Any] = [
                    "appChannel": AppChannel.current.rawValue,
                    "bundleIdentifier": AppChannel.current.bundleIdentifier,
                    "dataDirectoryName": AppChannel.current.displayName,
                    "kitPath": value.kitPath, "version": value.version, "runProtocolVersion": value.runProtocolVersion,
                    "supported": value.supported, "patchCommit": value.patchCommit, "kitSHA256": value.archiveSHA256,
                    "focusAwareClipboard": value.focusAwareClipboard,
                    "ownerSetupContractVersion": OwnerSetupContract.current.schemaVersion,
                    "touchIDProtectedStorageAvailable": KeychainOwnerSecretStore.supportsProtectedStorage,
                    "developmentKeychainCompatibility": KeychainOwnerSecretStore.usesDevelopmentKeychain,
                    "hostPreflightPerformed": !bundleOnly,
                    "provisioningSourceRevision": provisioning.sourceRevision,
                    "provisioningSourceSnapshotSHA256": provisioning.sourceSnapshotSHA256,
                    "provisioningExecutionEnabled": provisioning.executionEnabled,
                    "preflight": bundleOnly ? "not performed (bundle verification only)" : (value.preflightFailure ?? "passed"),
                    "vmLaunchEnabled": !bundleOnly && !AppModel.layoutPreview, "launchScope": AppModel.layoutPreview ? "synthetic-layout-preview" : "registered-manager-owned-private-build"
                ]
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(value.preflightFailure == nil ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data("Kit diagnostics failed: \(error.localizedDescription)\n".utf8)); exit(1)
            }
        }
        instanceLock = SingleInstanceApplication.acquire()
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        Window(AppChannel.current.displayName, id: "manager") {
            if AppModel.layoutPreview { LifecycleLayoutPreview() }
            else { ManagerView(model: model).preferredColorScheme(.dark).tint(Theme.green).foregroundStyle(Theme.text).task { delegate.model = model; await model.observe() } }
        }
        .defaultSize(width: 1120, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(updateChecker.isChecking ? "Checking for Updates…" : "Check for Updates…") {
                    updateChecker.checkForUpdates()
                }
                .disabled(updateChecker.isChecking)
                Divider()
            }
        }
    }
}
