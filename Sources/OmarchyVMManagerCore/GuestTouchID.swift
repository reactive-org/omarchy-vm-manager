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
    public static let reviewedRuntimePackageSHA256 = "a2912a97967d315439b4ec387bb6125912dc9db0568aee2408cdb524159fd59b"
    public static let reviewedLeanPackageSHA256 = "9fc986521b67cfa9e891fd826453553f1e2e4a319e6edb1302c760f1e22a2211"
    public static func validate(_ profile: VMProfile, lockData: Data) throws {
        guard profile.guestTouchIDEnabled else { return }
        let provenance = try JSONDecoder().decode(RuntimeProvenance.self, from: lockData)
        guard provenance.managedAuthenticationVersion == 1,
              provenance.files[VMFactorySelection.packagePath] == reviewedRuntimePackageSHA256,
              profile.factory?.kind != .custom || VMGuestIntegrationContract.current.leanPackageSHA256 == reviewedLeanPackageSHA256 else {
            throw VMFailure(code: "unproven-authentication-runtime", message: "Guest Touch ID requires the reviewed UUID-scoped authentication runtime. This guest was not launched.")
        }
    }
}
