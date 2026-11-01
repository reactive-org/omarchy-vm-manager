import AppKit
import Darwin
import Foundation
import OmarchyVMManagerCore

@MainActor
enum SingleInstanceApplication {
    static var activationNotification: Notification.Name {
        Notification.Name(AppModel.layoutPreview
            ? "dev.omarchy.vm-manager.layout-preview.activate"
            : "dev.omarchy.vm-manager.activate")
    }

    static func acquire() -> ManagerInstanceLock {
        let directory: URL
        if AppModel.layoutPreview {
            directory = URL(fileURLWithPath: "/private/tmp/omarchy-manager-layout-preview-\(getuid())")
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .resolvingSymlinksInPath().appendingPathComponent("Omarchy VM Manager")
        }
        do {
            if let lock = try ManagerInstanceLock.acquire(in: directory) { return lock }
            DistributedNotificationCenter.default().postNotificationName(activationNotification, object: nil, userInfo: nil, deliverImmediately: true)
            let identifier = Bundle.main.bundleIdentifier ?? "dev.omarchy.vm-manager"
            for application in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                where application.processIdentifier != getpid() {
                application.activate(options: [.activateAllWindows])
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Omarchy VM Manager cannot open: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
