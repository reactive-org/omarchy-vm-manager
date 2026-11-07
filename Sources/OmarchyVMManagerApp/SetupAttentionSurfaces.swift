import AppKit
import OmarchyVMManagerCore
import SwiftUI
import UserNotifications

/// Where setup attention shows outside the manager window. The rules for when
/// each effect happens live in Core's `SetupAttentionTracker`; these only carry
/// them out. Acceptance fixtures inject a recording fake, so no test touches the
/// Dock or macOS notifications.
@MainActor protocol SetupAttentionSurfaces: AnyObject {
    func notify(_ attention: SetupAttention, guestName: String)
    func clear(_ vmID: UUID)
    func bounce()
    func marker(_ shown: Bool)
}

/// The Dock and macOS notifications. Notifications need a bundled app with an
/// identifier (the bare debug binary has none), so they are skipped there; the
/// Dock bounce and marker need no permission and work either way.
@MainActor final class SystemAttentionSurfaces: NSObject, SetupAttentionSurfaces, UNUserNotificationCenterDelegate {
    nonisolated static let identifierPrefix = "setup-attention."
    nonisolated static let guestKey = "vmID"
    private let center: UNUserNotificationCenter?
    /// Called with the guest of a clicked notification.
    var open: ((UUID) -> Void)?

    override init() {
        center = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
        super.init()
        center?.delegate = self
    }

    /// At launch: ask once (macOS remembers the answer) and drop anything left
    /// from an earlier run, whose setup can't still be waiting.
    func start() {
        guard let center else { return }
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ attention: SetupAttention, guestName: String) {
        guard let center else { return }
        // The guest name and fixed text only: never terminal output or guest data.
        let content = UNMutableNotificationContent(), text = Self.text(attention, guestName: guestName)
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.userInfo = [Self.guestKey: attention.vmID.uuidString]
        center.add(UNNotificationRequest(identifier: Self.identifierPrefix + attention.vmID.uuidString, content: content, trigger: nil))
    }

    /// The whole of a notification's text: the guest's name and fixed wording.
    nonisolated static func text(_ attention: SetupAttention, guestName: String) -> (title: String, body: String) {
        (guestName, attention.reason.summary + ".")
    }

    func clear(_ vmID: UUID) {
        let identifier = Self.identifierPrefix + vmID.uuidString
        center?.removePendingNotificationRequests(withIdentifiers: [identifier])
        center?.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func bounce() { NSApp.requestUserAttention(.informationalRequest) }
    func marker(_ shown: Bool) { NSApp.dockTile.badgeLabel = shown ? "!" : nil }

    /// Show the banner even while the manager is in front: the tracker only
    /// notifies when that guest isn't the one on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content.userInfo[Self.guestKey] as? String, let vmID = UUID(uuidString: raw) else { return }
        await MainActor.run { self.open?(vmID) }
    }
}

extension AppModel {
    /// A click asking the window to open a guest at what its setup waits for.
    struct AttentionRoute: Equatable {
        let id = UUID()
        let vmID: UUID
        /// Output for the sudo prompt, the review otherwise; nil just opens Home.
        let sheet: SetupSheet?
    }

    /// One shared answer per guest, read by the card, tracker, sidebar, Dock and notifications.
    var setupAttention: [UUID: SetupAttention] {
        Dictionary(uniqueKeysWithValues: snapshots.compactMap { snapshot in
            SetupAttention.make(snapshot, workflows: setupWorkflows, jobs: setupJobs, auto: SetupAutoApproval(autoSetup[snapshot.id])).map { (snapshot.id, $0) }
        })
    }

    /// Opens the guest at what it's waiting for, worked out now rather than when
    /// the click's source was made: a stale notification just opens Home.
    func openAttention(_ vmID: UUID) {
        let reason = setupAttention[vmID]?.reason
        attentionRoute = AttentionRoute(vmID: vmID, sheet: reason.map { $0.opensOutput ? .output : .change })
    }

    /// Applies the tracker's effects after each observation.
    func refreshAttention(appActive: Bool) {
        guard let surfaces = attentionSurfaces else { return }
        let names = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.profile.name) })
        for effect in attentionTracker.update(setupAttention, appActive: appActive, visibleGuest: visibleGuest) {
            switch effect {
            case .notify(let attention): surfaces.notify(attention, guestName: names[attention.vmID] ?? "Guest")
            case .clear(let vmID): surfaces.clear(vmID)
            case .bounce: surfaces.bounce()
            case .marker(let shown): surfaces.marker(shown)
            }
        }
    }
}
