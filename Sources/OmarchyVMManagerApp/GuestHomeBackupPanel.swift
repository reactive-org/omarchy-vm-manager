import OmarchyVMManagerCore
import SwiftUI

/// Everything about the guest's home in one card: where it lives, its backup and,
/// for a separate home disk, replacing the system around it.
struct GuestHomePanel: View {
    let snapshot: VMSnapshot
    var canReplaceSystem = false
    let review: () -> Void
    let cancel: () -> Void
    var replaceSystem: () -> Void = {}

    private var storage: (value: String, note: String) {
        if let home = snapshot.profile.homeDisk {
            return ("Separate disk · \(home.sizeGiB) GiB", "Kept when you replace the system. It can grow but not shrink.")
        }
        return ("On the system disk", "A separate home disk is chosen when a VM is created.")
    }
    private var backup: (value: String, tint: Color?, note: String) {
        switch snapshot.homeBackup {
        case .idle:
            if snapshot.profile.sharedFolder?.enabled != true {
                return ("Needs a host folder", nil, "Enable a host folder in Configure while this guest is stopped, then launch it to back up its home.")
            }
            if !snapshot.canBackUpHome {
                return ("Ready when running", nil, "Requires a running guest, authenticated SSH and a mounted read-write host folder.")
            }
            return ("Ready", nil, "Saves the guest home, including hidden files, to an archive in the host folder. Close guest apps first.")
        case .working(let url): return ("Backing up…", Theme.lavender, "Creating and checking the archive.\n" + url.path)
        case .cancelling: return ("Cancelling…", Theme.amber, "Partial output will be preserved.")
        case .completed(let url, let bytes):
            return ("Verified · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), Theme.green, url.path)
        case .failed(let url, let message): return ("Failed", Theme.amber, message + "\nFolder: " + url.deletingLastPathComponent().path)
        }
    }

    var body: some View {
        GroupedPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SpecHeading("home")
                    Spacer(minLength: 0)
                    if snapshot.homeBackup.isBusy {
                        ProgressView().controlSize(.small)
                        Button("Cancel backup", action: cancel).disabled({ if case .cancelling = snapshot.homeBackup { return true }; return false }())
                    } else {
                        Button("Back up home…", action: review).disabled(!snapshot.canBackUpHome)
                    }
                }.padding(.bottom, 8)
                row("storage", value: storage.value, note: storage.note)
                row("backup", value: backup.value, tint: backup.tint, note: backup.note)
                if snapshot.profile.homeDisk != nil {
                    row("system", value: "Replaceable", note: "Start again from a fresh system disk and keep this home, its files and settings.") {
                        Button("Replace system…", action: replaceSystem).disabled(!canReplaceSystem)
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
        }
    }

    private func row(_ key: String, value: String, tint: Color? = nil, note: String) -> some View { row(key, value: value, tint: tint, note: note) { EmptyView() } }
    private func row<Trailing: View>(_ key: String, value: String, tint: Color? = nil, note: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(key).font(Theme.mono(14)).foregroundStyle(Theme.lavender).frame(width: 88, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(Theme.mono(14)).foregroundStyle(tint ?? Theme.text)
                Text(note).font(Theme.sans(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
