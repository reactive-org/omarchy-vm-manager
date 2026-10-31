import OmarchyVMManagerCore
import SwiftUI

#if DEBUG
struct LifecycleLayoutPreview: View {
    enum Phase: String, CaseIterable {
        case stopped = "Stopped", validating = "Checking", downloading = "Downloading", preparing = "Preparing", running = "Running", pausing = "Pausing", paused = "Paused", resuming = "Resuming", hostSleeping = "Mac sleep", unknown = "Unknown", stopping = "Stopping", failed = "Failed"
        var state: VMState {
            switch self {
            case .stopped: .stopped
            case .validating: .validating
            case .downloading: .downloading(phase: .downloading, percent: 48)
            case .preparing: .starting(phase: .preparing, percent: nil)
            case .running: .running
            case .pausing: .pausing
            case .paused: .paused
            case .resuming: .resuming
            case .hostSleeping: .hostSleeping
            case .unknown: .executionUnknown
            case .stopping: .stopping
            case .failed: .failed(VMFailure(code: "preview", message: "The download could not finish. Check your connection and try again."))
            }
        }
    }
    enum Power: String, CaseIterable {
        case unknown = "Not checked", unsupported = "Stock kernel", incomplete = "Guest setup needed", ready = "Experimental ready"
        var capability: GuestHibernationCapability? {
            switch self {
            case .unknown: nil
            case .unsupported: .init(kernel: "7.2.8-23-omarchy", kernelSupport: .unsupported, diskStateAvailable: false, persistentSwap: false, resumeConfigured: false, nonInteractivePermission: false)
            case .incomplete: .init(kernel: "7.2.8-experimental", kernelSupport: .supported, diskStateAvailable: true, persistentSwap: false, resumeConfigured: false, nonInteractivePermission: false)
            case .ready: .init(kernel: "7.2.8-experimental", kernelSupport: .supported, diskStateAvailable: true, persistentSwap: true, resumeConfigured: true, nonInteractivePermission: true)
            }
        }
    }
    @State private var power: Power = .unknown
    @State private var phase: Phase = .stopped
    @State private var rowFrame = CGRect.zero
    @State private var heroFrame = CGRect.zero
    private var snapshot: VMSnapshot {
        var profile = VMProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, name: "Omarchy Layout Fixture")
        profile.ssh = SSHOptions(hostPort: 2222)
        return VMSnapshot(profile: profile, state: phase.state,
                   sessionID: phase == .stopped || phase == .failed ? nil : UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                   lastFailure: phase == .failed ? VMFailure(code: "preview", message: "The download could not finish. Check your connection and try again.") : nil,
                   sshReadiness: phase == .running ? .ready(user: "fixture", command: "synthetic") : .stopped,
                   hibernation: power.capability)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Lifecycle layout preview").font(.largeTitle.bold())
                Text("Synthetic presentation only · No VM, registry, Keychain or network access").foregroundStyle(.secondary)
                Picker("Preview state", selection: $phase) {
                    ForEach(Phase.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
                Text("Library card").font(.title2.bold())
                GuestLibraryRow(snapshot: snapshot, open: {}) { GuestControls(snapshot: snapshot, start: { phase = .running }, stop: { phase = .stopped }, forceStop: { phase = .stopped }, pause: { phase = .paused }, resume: { phase = .running }) }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("gallery")) }, action: { rowFrame = $0 })
                Text("Guest home").font(.title2.bold())
                GuestHomeHero(snapshot: snapshot)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("gallery")) }, action: { heroFrame = $0 })
                Picker("Hibernation capability", selection: $power) {
                    ForEach(Power.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
                GuestHibernationPanel(snapshot: snapshot, review: { _ in })
                OmarchyAttribution()
                Text("This content stays in the same position in every state.").foregroundStyle(.secondary)
                Text("Measured card: y \(Int(rowFrame.minY)), height \(Int(rowFrame.height)); hero: y \(Int(heroFrame.minY)), height \(Int(heroFrame.height))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }.coordinateSpace(name: "gallery").padding(28).frame(maxWidth: 1050).frame(maxWidth: .infinity)
        }.frame(minWidth: 660, minHeight: 650)
    }
}
#else
struct LifecycleLayoutPreview: View {
    var body: some View { Text("Layout preview is available only in debug builds.") }
}
#endif
