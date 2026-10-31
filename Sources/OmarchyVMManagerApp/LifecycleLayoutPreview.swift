import OmarchyVMManagerCore
import SwiftUI

#if DEBUG
struct LifecycleLayoutPreview: View {
    enum Phase: String, CaseIterable {
        case stopped = "Stopped", validating = "Checking", downloading = "Downloading", preparing = "Preparing", running = "Running", stopping = "Stopping", failed = "Failed"
        var state: VMState {
            switch self {
            case .stopped: .stopped
            case .validating: .validating
            case .downloading: .downloading(phase: .downloading, percent: 48)
            case .preparing: .starting(phase: .preparing, percent: nil)
            case .running: .running
            case .stopping: .stopping
            case .failed: .failed(VMFailure(code: "preview", message: "The download could not finish. Check your connection and try again."))
            }
        }
    }
    @State private var phase: Phase = .stopped
    @State private var rowFrame = CGRect.zero
    @State private var heroFrame = CGRect.zero
    private var snapshot: VMSnapshot {
        VMSnapshot(profile: VMProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, name: "Omarchy Layout Fixture"), state: phase.state,
                   sessionID: phase == .stopped || phase == .failed ? nil : UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                   lastFailure: phase == .failed ? VMFailure(code: "preview", message: "The download could not finish. Check your connection and try again.") : nil)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Lifecycle layout preview").font(.largeTitle.bold())
                Text("Synthetic presentation only · No VM, registry, Keychain or network access").foregroundStyle(.secondary)
                Picker("Preview state", selection: $phase) {
                    ForEach(Phase.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Text("Library card").font(.title2.bold())
                GuestLibraryRow(snapshot: snapshot, open: {}) { GuestControls(snapshot: snapshot, start: {}, stop: {}, forceStop: {}) }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("gallery")) }, action: { rowFrame = $0 })
                Text("Guest home").font(.title2.bold())
                GuestHomeHero(snapshot: snapshot)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("gallery")) }, action: { heroFrame = $0 })
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
