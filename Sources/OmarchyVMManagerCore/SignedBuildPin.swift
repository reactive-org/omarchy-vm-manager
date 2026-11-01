// Populated only inside the authorized signed-release job, then restored.
// Empty defaults keep manually compiled signed builds fail-closed.
enum SignedBuildPin {
    static let signingTeamID = ""
    static let sourceKitSHA256 = ""
    static let sourceLockSHA256 = ""
}
