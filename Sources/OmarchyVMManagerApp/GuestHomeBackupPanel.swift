import OmarchyVMManagerCore
import SwiftUI

struct GuestHomeBackupPanel: View {
    let snapshot: VMSnapshot
    let review: () -> Void
    let cancel: () -> Void

    private var detail: String {
        switch snapshot.homeBackup {
        case .idle:
            if snapshot.profile.sharedFolder?.enabled != true { return "Enable a host folder in Configure while this guest is stopped, then launch it to back up its home." }
            if !snapshot.canBackUpHome { return "Requires a running guest, authenticated SSH and a mounted read-write host folder." }
            return "Save your guest home, including hidden files, to an archive in the host folder. Close guest apps first."
        case .working(let url): return "Creating and checking the archive…\n" + url.path
        case .cancelling: return "Cancelling the backup… Partial output will be preserved."
        case .completed(let url, let bytes): return "Backup verified · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))\n" + url.path
        case .failed(let url, let message): return message + "\nFolder: " + url.deletingLastPathComponent().path
        }
    }
    var body: some View {
        GroupedPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SpecHeading("home backup")
                    Spacer()
                    if snapshot.homeBackup.isBusy {
                        ProgressView().controlSize(.small)
                        Button("Cancel Backup", action: cancel).disabled({ if case .cancelling = snapshot.homeBackup { return true }; return false }())
                    } else {
                        Button("Back Up Home…", action: review).disabled(!snapshot.canBackUpHome)
                    }
                }
                Text(detail).font(Theme.sans(13)).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(20)
        }
    }
}
