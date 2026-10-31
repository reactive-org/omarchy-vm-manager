import AppKit
import OmarchyVMManagerCore
import SwiftUI

struct GuestArtwork: View {
    let size: CGFloat
    var state: VMState = .stopped
    private var busy: Bool {
        switch state {
        case .validating, .downloading, .starting, .stopping, .deleting: true
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
                    let summary = "\(snapshot.state.label) · \(snapshot.profile.cpus) cores · \(snapshot.profile.memoryMiB / 1024) GiB memory"
                    Text(summary).font(.callout).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).help(summary)
                    GuestProgressSlot(state: snapshot.state)
                    Group {
                        if let failure = snapshot.lastFailure {
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
                    Text(snapshot.state == .stopped ? "Ready to launch" : snapshot.state.label).font(.title3).foregroundStyle(.secondary).lineLimit(1)
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
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if snapshot.state.canStart {
                    Button { start() } label: { Label("Launch", systemImage: "play.fill").frame(width: 96) }
                        .buttonStyle(.borderedProminent).disabled(!launchEnabled)
                } else if snapshot.sessionID != nil {
                    Button { stop() } label: { Text("Shut Down").frame(width: 96) }
                        .disabled(snapshot.state == .stopping)
                } else { Text("Please wait…").font(.callout).foregroundStyle(.secondary) }
            }.frame(width: 116, height: 30)
            Menu { Button("Force Stop…", role: .destructive) { forceStop() } } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 24)
                .opacity(snapshot.sessionID == nil ? 0 : 1).disabled(snapshot.sessionID == nil)
                .accessibilityHidden(snapshot.sessionID == nil)
        }.frame(width: 148, height: 30)
    }
}
