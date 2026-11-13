import OmarchyVMManagerCore
import SwiftUI

/// Reclaim space: trims a running guest's filesystems so space freed inside
/// it is returned to macOS. The sparse disk files otherwise only grow.
struct GuestReclaimPanel: View {
    let snapshot: VMSnapshot
    let reclaim: () -> Void

    static let limits = "Guest snapshots, including Omarchy's factory reset snapshot, keep the space they hold. Blocks still shared with the factory image or a copied home disk, and Time Machine local snapshots on this Mac, can also delay or keep space."

    private var status: (value: String, tint: Color?, note: String) {
        switch snapshot.reclaim {
        case .working:
            return ("Reclaiming…", Theme.lavender, "Trimming the guest's free space. You can keep using the guest.")
        case .completed(let result):
            let returned = ByteCountFormatter.string(fromByteCount: result.reclaimedBytes, countStyle: .file)
            let used = ByteCountFormatter.string(fromByteCount: result.afterBytes, countStyle: .file)
            let disks = result.filesystems.contains("home") ? "system and home disks" : "system disk"
            return ("Reclaimed \(returned)", Theme.green, "Trimmed the \(disks). This guest now uses \(used) on this Mac. " + Self.limits)
        case .failed(let message):
            return ("Not reclaimed", Theme.amber, message)
        case .idle:
            if !snapshot.guestTrimSupported {
                return ("Unavailable", nil, "This runtime doesn't pass guest TRIM through to its disks.")
            }
            if snapshot.profile.ssh == nil {
                return ("Needs managed SSH", nil, "Reclaim space runs over this guest's managed SSH, which is chosen at creation.")
            }
            if !snapshot.canReclaimSpace {
                return ("Ready when running", nil, "Requires a running guest with authenticated SSH. Disk files grow as the guest writes and don't shrink by themselves.")
            }
            return ("Ready", nil, "Returns space freed inside the guest to macOS. " + Self.limits)
        }
    }

    var body: some View {
        GroupedPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SpecHeading("space")
                    Spacer(minLength: 0)
                    if snapshot.reclaim.isBusy { ProgressView().controlSize(.small) }
                    Button("Reclaim space", action: reclaim).disabled(!snapshot.canReclaimSpace)
                }.padding(.bottom, 8)
                HStack(alignment: .center, spacing: 12) {
                    Text("unused").font(Theme.mono(14)).foregroundStyle(Theme.lavender).frame(width: 88, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.value).font(Theme.mono(14)).foregroundStyle(status.tint ?? Theme.text)
                        Text(status.note).font(Theme.sans(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 9)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
        }
    }
}
