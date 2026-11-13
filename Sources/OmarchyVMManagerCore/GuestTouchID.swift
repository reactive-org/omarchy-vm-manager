import Foundation
import TryOmarchyKitClient

public struct GuestTouchIDRecord: Codable, Sendable {
    public let enabled: Bool
    public let hostBridge: String
    public let guestPairing: String
    public init(_ snapshot: VMSnapshot) {
        enabled = snapshot.profile.guestTouchIDEnabled
        hostBridge = !enabled ? "disabled" : snapshot.sessionID == nil ? "next-start" : snapshot.state == .running ? "requested" : "unavailable"
        guestPairing = "unknown"
    }
}

public enum GuestTouchIDPolicy {
    /// try-omarchy 0.1.0-49: its UUID-scoped authentication is unchanged from the
    /// reviewed 0.1.0-47; 48 added the Omarchy 4.5 lean owner contract and 49
    /// only adds the argument-less reclaim helper and its sudoers rule.
    public static let reviewedRuntimePackageSHA256 = "7733a29ff3a7b91ff592f8a936f746a2660a5dd562c30141a0c0d92721e7592b"
    /// Image packages of the reviewed lean contracts (0.1.0-43.1 and 0.1.0-48.1).
    public static let reviewedLeanPackageSHA256s: Set<String> = [
        "9fc986521b67cfa9e891fd826453553f1e2e4a319e6edb1302c760f1e22a2211",
        "876e05d829c3dbbb57991140c61563caeca990035a2ad01b9afb3b26d06bb5d3"]
    public static func validate(_ profile: VMProfile, lockData: Data) throws {
        guard profile.guestTouchIDEnabled else { return }
        let provenance = try JSONDecoder().decode(RuntimeProvenance.self, from: lockData)
        guard provenance.managedAuthenticationVersion == 1,
              provenance.files[VMFactorySelection.packagePath] == reviewedRuntimePackageSHA256,
              profile.factory?.kind != .custom || Set(VMGuestIntegrationContract.current.leanContracts.map(\.leanPackageSHA256)).isSubset(of: reviewedLeanPackageSHA256s) else {
            throw VMFailure(code: "unproven-authentication-runtime", message: "Guest Touch ID requires the reviewed UUID-scoped authentication runtime. This guest was not launched.")
        }
    }
}
