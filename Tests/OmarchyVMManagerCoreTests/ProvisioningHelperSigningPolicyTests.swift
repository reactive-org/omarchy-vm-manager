import Foundation
import Testing
@testable import OmarchyVMManagerCore

@Suite("Provisioning helper signing policy — pure identities, no Security calls")
struct ProvisioningHelperSigningPolicyTests {
    private static func id(_ team: String?, adHoc: Bool) -> ProvisioningHelperCodeIdentity {
        .init(cdHash: Data(repeating: adHoc ? 1 : 2, count: 20), team: team, adHoc: adHoc)
    }
    private static let adHoc = id(nil, adHoc: true)
    private static let teamA = id("TEAMAAAAAA", adHoc: false)
    private static let teamB = id("TEAMBBBBBB", adHoc: false)
    private static let emptyTeam = id("", adHoc: false)
    private static let adHocClaimingTeam = id("TEAMAAAAAA", adHoc: true)

    /// (outer, helper, sameApplicationTeam, adHocFixture, sameApplicationTeamOrLocalAdHoc)
    static let cases: [(String, ProvisioningHelperCodeIdentity, ProvisioningHelperCodeIdentity, Bool, Bool, Bool)] = [
        ("ad-hoc pair", adHoc, adHoc, false, true, true),
        ("same team", teamA, teamA, true, false, true),
        ("different teams", teamA, teamB, false, false, false),
        ("team app, ad-hoc helper", teamA, adHoc, false, false, false),
        ("ad-hoc app, team helper", adHoc, teamA, false, false, false),
        ("empty team pair", emptyTeam, emptyTeam, false, false, false),
        ("ad-hoc flagged with team", adHocClaimingTeam, adHocClaimingTeam, false, false, false),
    ]

    @Test(arguments: cases.indices)
    func signaturePairs(index: Int) {
        let (name, outer, helper, strict, fixture, local) = Self.cases[index]
        #expect(ProvisioningHelperSigningPolicy.sameApplicationTeam.admits(outer: outer, helper: helper) == strict, "\(name): strict")
        #expect(ProvisioningHelperSigningPolicy.adHocFixture.admits(outer: outer, helper: helper) == fixture, "\(name): fixture")
        #expect(ProvisioningHelperSigningPolicy.sameApplicationTeamOrLocalAdHoc.admits(outer: outer, helper: helper) == local, "\(name): local Dev")
    }

    /// Stable and signed Dev prereleases stay strict; only local Dev builds relax.
    @Test func compiledProvisioningHelperSigningPolicy() {
        var expected = ProvisioningHelperSigningPolicy.sameApplicationTeam
        #if DEVELOPMENT_CHANNEL && !SIGNED_PRERELEASE
        expected = .sameApplicationTeamOrLocalAdHoc
        #endif
        #expect(ProvisioningHelperSigningPolicy.product == expected)
        if AppChannel.current == .stable { #expect(ProvisioningHelperSigningPolicy.product == .sameApplicationTeam) }
        #if SIGNED_PRERELEASE
        #expect(ProvisioningHelperSigningPolicy.product == .sameApplicationTeam)
        #endif
    }
}
