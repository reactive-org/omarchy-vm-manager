import AppKit
import OmarchyVMManagerCore
import SwiftUI

@MainActor
final class UpdateCheckController: ObservableObject {
    @Published private(set) var isChecking = false

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            let tag = Bundle.main.object(forInfoDictionaryKey: AppReleaseChecker.releaseTagKey) as? String
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let alert = NSAlert()
            var releaseURL: URL?
            do {
                switch try await AppReleaseChecker().check(installedTag: tag, shortVersion: version) {
                case .available(let release):
                    alert.messageText = "An update is available"
                    alert.informativeText = "You have \(tag ?? "unknown") installed. \(release.tag) is available. Open its GitHub release page to read the notes and download the app."
                    alert.addButton(withTitle: "View Release")
                    alert.addButton(withTitle: "Later")
                    releaseURL = release.url
                case .upToDate:
                    alert.messageText = "You’re up to date"
                    alert.informativeText = "You’re running \(tag ?? "an unknown version"). No newer published release is available for this app’s \(AppChannel.current == .development ? "Dev" : "stable") channel."
                    alert.addButton(withTitle: "OK")
                case .noReleases:
                    alert.messageText = "No app releases are available"
                    alert.informativeText = "GitHub has no published app downloads to compare with this installation. Please check again later."
                    alert.addButton(withTitle: "OK")
                }
            } catch is CancellationError { return }
            catch {
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t check for updates"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
            }
            if alert.runModal() == .alertFirstButtonReturn, let releaseURL {
                NSWorkspace.shared.open(releaseURL)
            }
        }
    }
}
