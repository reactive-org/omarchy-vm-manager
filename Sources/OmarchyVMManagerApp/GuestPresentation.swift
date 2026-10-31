import AppKit
import OmarchyVMManagerCore
import SwiftUI

struct GuestArtwork: View {
    let size: CGFloat
    var state: VMState = .stopped
    private var busy: Bool {
        switch state {
        case .validating, .downloading, .starting, .pausing, .resuming, .stopping, .deleting: true
        default: false
        }
    }
    var body: some View {
        ZStack {
            if let url = Bundle.main.url(forResource: "OmarchyGuest", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "desktopcomputer").resizable().scaledToFit().padding(size * 0.2)
            }
            if busy {
                RoundedRectangle(cornerRadius: size * 0.185).fill(.black.opacity(0.55))
                    .frame(width: size * 0.81, height: size * 0.81)
                ProgressView().controlSize(size < 40 ? .mini : .regular)
                    .environment(\.colorScheme, .dark)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct GuestProgressSlot: View {
    let state: VMState
    private var detail: (text: String, percent: Int?)? {
        switch state {
        case .downloading(let phase, let percent), .starting(let phase, let percent):
            (phase.rawValue.replacingOccurrences(of: "-", with: " ").capitalized, percent)
        case .paused: ("Execution paused · RAM stays reserved", nil)
        case .pausing: ("Waiting for Pause acknowledgement…", nil)
        case .resuming: ("Waiting for Resume acknowledgement…", nil)
        case .hostSleeping: ("Paused with the Mac · resumes on wake", nil)
        case .executionUnknown: ("Execution state unknown · shut down to recover", nil)
        case .validating: ("Checking this guest…", nil)
        case .stopping: ("Waiting for the guest to shut down…", nil)
        case .deleting: ("Moving this guest to Trash…", nil)
        default: nil
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let detail {
                let label = detail.text + (detail.percent.map { " · \($0)%" } ?? "")
                Text(label).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).help(label)
                if let percent = detail.percent {
                    ProgressView(value: Double(percent), total: 100).progressViewStyle(.linear).frame(height: 4)
                } else { Color.clear.frame(height: 4) }
            }
        }.frame(maxWidth: 320, alignment: .leading).frame(height: 32, alignment: .top)
            .accessibilityHidden(detail == nil)
    }
}

struct GuestLibraryRow<Controls: View>: View {
    let snapshot: VMSnapshot
    let open: () -> Void
    @ViewBuilder var controls: Controls
    var body: some View {
        GroupedPanel {
            HStack(spacing: 18) {
                GuestArtwork(size: 52, state: snapshot.state)
                VStack(alignment: .leading, spacing: 5) {
                    Button(snapshot.profile.name, action: open).buttonStyle(.plain).font(.title3.bold())
                        .lineLimit(1).help(snapshot.profile.name)
                    let disk = snapshot.profile.diskGiB.map { " · \($0) GiB disk" } ?? ""
                    let summary = "\(snapshot.state.label) · \(snapshot.profile.cpus) cores · \(snapshot.profile.memoryMiB / 1024) GiB memory" + disk
                    Text(summary).font(.callout).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).help(summary)
                    GuestProgressSlot(state: snapshot.state)
                    Group {
                        if let suspension = snapshot.suspension {
                            Text(suspension.label).foregroundStyle(.orange).lineLimit(2)
                        } else if let failure = snapshot.lastFailure {
                            Text(failure.message).foregroundStyle(.red).lineLimit(2).help(failure.message)
                        } else if snapshot.profile.isRetainedPOC {
                            Label("Retained POC disk", systemImage: "lock.shield").foregroundStyle(.secondary)
                        } else { Color.clear }
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .topLeading).frame(height: 28, alignment: .top)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 120, alignment: .top)
                controls.frame(width: 148, height: 30, alignment: .trailing)
            }.padding(20)
        }
    }
}

struct GuestHomeHero: View {
    let snapshot: VMSnapshot
    var body: some View {
        GroupedPanel {
            HStack(spacing: 24) {
                GuestArtwork(size: 104, state: snapshot.state)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Omarchy").font(.system(size: 34, weight: .bold))
                    Text(snapshot.suspension?.label ?? (snapshot.state == .stopped ? "Ready to launch" : snapshot.state.label)).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                    Text("Independent disk · Shared (NAT) network").foregroundStyle(.secondary).lineLimit(1)
                    GuestProgressSlot(state: snapshot.state)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 148, alignment: .center)
            }.padding(26)
        }
    }
}

struct OmarchyAttribution: View {
    var body: some View {
        Text("Omarchy is a pending trademark of the [Omacom Foundation](https://omarchy.org/foundation/).")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct GuestControls: View {
    let snapshot: VMSnapshot
    var launchEnabled = true
    let start: () -> Void
    let stop: () -> Void
    let forceStop: () -> Void
    var pause: () -> Void = {}
    var resume: () -> Void = {}
    var suspendToDisk: () -> Void = {}
    var restoreSuspension: () -> Void = {}
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if snapshot.sessionID == nil && snapshot.suspension != nil {
                    Button { restoreSuspension() } label: { Text("Restore…").frame(width: 96) }
                        .buttonStyle(.borderedProminent).disabled(!launchEnabled || !snapshot.canRestoreExperimentalSuspension)
                } else if snapshot.state.canStart {
                    Button { start() } label: { Label("Launch", systemImage: "play.fill").frame(width: 96) }
                        .buttonStyle(.borderedProminent).disabled(!launchEnabled || snapshot.suspensionMetadataUnsafe)
                } else if snapshot.state == .paused {
                    Button { resume() } label: { Label("Resume", systemImage: "play.fill").frame(width: 96) }
                        .buttonStyle(.borderedProminent)
                } else if snapshot.sessionID != nil {
                    Button { stop() } label: { Text("Shut Down").frame(width: 96) }
                        .disabled(snapshot.state == .stopping)
                } else { Text("Please wait…").font(.callout).foregroundStyle(.secondary) }
            }.frame(width: 116, height: 30)
            Menu {
                if snapshot.state == .running {
                    Button("Pause", systemImage: "pause.fill") { pause() }.disabled(snapshot.suspension != nil)
                    Button("Suspend to Disk (Experimental)…", systemImage: "moon.zzz") { suspendToDisk() }
                        .disabled(!snapshot.canAttemptExperimentalSuspend)
                }
                if snapshot.state == .paused { Button("Shut Down") { stop() } }
                Divider()
                Button("Force Stop…", role: .destructive) { forceStop() }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 24)
                .opacity(snapshot.sessionID == nil ? 0 : 1).disabled(snapshot.sessionID == nil)
                .accessibilityHidden(snapshot.sessionID == nil)
        }.frame(width: 148, height: 30)
    }
}


struct ExperimentalPowerReview: Identifiable {
    enum Action { case suspend, restore, acceptColdBoot }
    let id: UUID
    let action: Action
    var title: String {
        switch action {
        case .suspend: "Attempt experimental suspend-to-disk?"
        case .restore: "Attempt experimental session restoration?"
        case .acceptColdBoot: "Accept the failed restoration?"
        }
    }
    var message: String {
        switch action {
        case .suspend: "Save your work first. Our tested runtime has stalled during hibernation. This attempt may hang or fail to preserve your session. RAM is released only after VM exit. The manager will protect this disk from ordinary launches, edits and deletion until recovery is verified. The guest must already have its kernel, swap, resume boot configuration and hibernation permissions configured."
        case .restore: "The saved session is unverified. Restoration may fail, cold-boot instead, or leave devices and desktop unusable. The manager will check whether memory actually survived. Keep the disk and resource configuration unchanged."
        case .acceptColdBoot: "The guest cold-booted and did not restore memory. Before accepting, a guest administrator must invalidate any stale hibernation image on the configured resume area. The app cannot perform or verify that cleanup. Confirm only after it is done, while the guest is still running. This releases protection and permits normal management; reusing stale memory after filesystem changes can corrupt data."
        }
    }
    var button: String {
        switch action {
        case .suspend: "Opt In and Attempt Suspension"
        case .restore: "Attempt Restore / Recovery"
        case .acceptColdBoot: "Confirm Guest Image Cleared"
        }
    }
}

struct GuestHibernationPanel: View {
    let snapshot: VMSnapshot
    let review: (ExperimentalPowerReview.Action) -> Void
    var recheck: () -> Void = {}
    private var detail: String {
        if snapshot.experimentalPowerBusy && snapshot.suspension == nil { return "Rechecking guest prerequisites and preparing the experimental attempt…" }
        if snapshot.suspensionMetadataUnsafe { return "Saved-session metadata needs manual recovery. Ordinary launch, configuration and deletion are blocked." }
        if snapshot.suspension?.restoreAttempted == true && snapshot.sessionID == nil { return "An earlier restore was unresolved. Another boot is blocked because it could reuse stale memory after filesystem changes. Manual recovery is required." }
        if snapshot.suspension?.stage == .coldBootDetected { return "Session restoration failed. A guest administrator must clear any stale resume image before you acknowledge this running cold boot. Complete recovery before shutting it down." }
        if let suspension = snapshot.suspension { return suspension.label + ". Restore or recover this session before changing its disk or configuration." }
        if let capability = snapshot.hibernation { return capability.detail }
        if snapshot.profile.ssh == nil { return "Enable managed SSH when creating a guest to detect its running kernel’s hibernation capability." }
        if snapshot.state != .running { return "Launch the guest to inspect its running kernel over authenticated managed SSH." }
        return "Waiting for a verified guest capability check over managed SSH."
    }
    var body: some View {
        GroupedPanel {
            HStack(spacing: 16) {
                ZStack {
                    Image(systemName: "moon.zzz").font(.title2).foregroundStyle(.indigo)
                        .opacity(snapshot.experimentalPowerBusy ? 0.25 : 1)
                    if snapshot.experimentalPowerBusy { ProgressView().controlSize(.small) }
                }.frame(width: 34)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suspend to Disk · Experimental").font(.headline)
                    Text(snapshot.hibernation.map { $0.label + " · " + $0.kernel } ?? (snapshot.suspension == nil ? "Capability not yet verified" : "Saved-session protection active")).font(.callout).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(detail)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Group {
                if snapshot.suspension?.stage == .coldBootDetected && snapshot.state == .running {
                    Button("Accept Cold Boot…") { review(.acceptColdBoot) }
                } else if snapshot.suspension != nil && snapshot.sessionID == nil {
                    Button("Restore / Recover…") { review(.restore) }.disabled(!snapshot.canRestoreExperimentalSuspension)
                } else if snapshot.suspension?.restoreAttempted == true && snapshot.suspension?.stage == .recoveryRequired && snapshot.state == .running {
                    Button("Recheck Recovery") { recheck() }
                } else {
                    Button("Suspend…") { review(.suspend) }.disabled(!snapshot.canAttemptExperimentalSuspend)
                }
                }.frame(width: 180, height: 30, alignment: .trailing)
            }.padding(20).frame(height: 144)
        }
    }
}
