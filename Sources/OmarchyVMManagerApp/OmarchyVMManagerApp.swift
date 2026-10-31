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
        if let url = Bundle.main.url(forResource: "OmarchyVMManager", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
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
                    "vmLaunchEnabled": !AppModel.layoutPreview, "launchScope": AppModel.layoutPreview ? "synthetic-layout-preview" : "registered-manager-owned-private-build"
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
            if AppModel.layoutPreview { LifecycleLayoutPreview() }
            else { ManagerView(model: model).task { delegate.model = model; await model.observe() } }
        }
        .defaultSize(width: 1120, height: 780)
        .windowResizability(.contentMinSize)
    }
}
