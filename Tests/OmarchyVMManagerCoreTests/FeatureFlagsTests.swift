import Foundation
import Testing
@testable import OmarchyVMManagerCore

@Suite("Channel-compiled feature flags — synthetic snapshots only")
struct FeatureFlagsTests {
    private let profile = VMProfile(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000F1")!, name: "Feature Flag Fixture")
    private var saved: ExperimentalSuspension {
        ExperimentalSuspension(schemaVersion: 1, vmID: profile.id, originSession: UUID(), user: "fixture",
                               proof: GuestSuspendProof(token: UUID(), bootID: UUID(), kernel: "7.2.8-test"),
                               profileDigest: "profile", runtimeDigest: "runtime", diskIdentity: "disk", stage: .restorePending)
    }

    @Test("stable hides experimental suspend-to-disk; Dev keeps it")
    func channelDefaults() {
        #expect(!FeatureFlags(channel: .stable).experimentalSuspendToDisk)
        #expect(FeatureFlags(channel: .development).experimentalSuspendToDisk)
    }

    @Test("the compiled flags follow the compiled channel")
    func compiledChannel() {
        #expect(FeatureFlags.current == FeatureFlags(channel: AppChannel.current))
    }

    @Test("recovery stays visible for a saved session or damaged metadata when attempts are hidden")
    func recoveryVisibility() {
        let off = FeatureFlags(experimentalSuspendToDisk: false), on = FeatureFlags(experimentalSuspendToDisk: true)
        let idle = VMSnapshot(profile: profile, state: .stopped)
        let suspended = VMSnapshot(profile: profile, state: .stopped, suspension: saved)
        let damaged = VMSnapshot(profile: profile, state: .stopped, suspensionMetadataUnsafe: true)
        #expect(!off.showsSuspendPanel(for: idle))
        #expect(off.showsSuspendPanel(for: suspended))
        #expect(off.showsSuspendPanel(for: damaged))
        for snapshot in [idle, suspended, damaged] { #expect(on.showsSuspendPanel(for: snapshot)) }
    }
}
