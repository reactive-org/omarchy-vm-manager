import AppKit
@preconcurrency import ApplicationServices
import Darwin
import Foundation
import OmarchyVMManagerCore
import SwiftUI
import TryOmarchyKitClient

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
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
    private let instanceLock: ManagerInstanceLock

    init() {
        let bundleOnly = CommandLine.arguments.contains("--verify-bundle-json")
        if bundleOnly || CommandLine.arguments.contains("--diagnostics-json") {
            do {
                let value = try AppModel.inspect(preflight: { bundleOnly ? nil : VMRunClient.preflight() })
                let json: [String: Any] = [
                    "kitPath": value.kitPath, "version": value.version, "runProtocolVersion": value.runProtocolVersion,
                    "supported": value.supported, "patchCommit": value.patchCommit, "kitSHA256": value.archiveSHA256,
                    "focusAwareClipboard": value.focusAwareClipboard,
                    "ownerSetupContractVersion": OwnerSetupContract.current.schemaVersion,
                    "touchIDProtectedStorageAvailable": KeychainOwnerSecretStore.supportsProtectedStorage,
                    "hostPreflightPerformed": !bundleOnly,
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
        Window("Omarchy VM Manager", id: "manager") {
            if AppModel.layoutPreview { LifecycleLayoutPreview() }
            else { ManagerView(model: model).task { delegate.model = model; await model.observe() } }
        }
        .defaultSize(width: 1120, height: 780)
        .windowResizability(.contentMinSize)
    }
}
