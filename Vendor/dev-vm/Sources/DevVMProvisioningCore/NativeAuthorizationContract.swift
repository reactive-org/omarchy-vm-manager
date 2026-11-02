import Foundation

/// PRIVATE COUPLING: fixed native guest commands from the Python controller at
/// the reviewed dev-vm baseline. This describes guest argv; it never executes it.
/// A future transport must route through the pinned non-root guest connection,
/// quote argv correctly at the SSH boundary, and use the approved input lease.
public struct NativeGuestInvocation: Sendable {
    public static let contractVersion = 1
    public let arguments: [String]
    public let requiresInteractiveTerminal: Bool
    public let acceptsNonterminalInput: Bool
}

extension GuestOperation {
    /// Data-only command construction. No user strings, paths or credentials are
    /// interpolated into these scripts, and no host execution adapter is supplied.
    public var nativeInvocation: NativeGuestInvocation? {
        let script: String
        switch self {
        case .resetGrant, .revokeGrant:
            script = "omarchy sudo passwordless --disable"
        case .clearAuthenticationCache:
            script = "sudo -K"
        case .requestPersistentGrant:
            script = "omarchy sudo passwordless permanent"
        case .verifyGrantActive:
            script = "omarchy sudo passwordless --active && sudo -kn true"
        case .verifyGrantInactive:
            // The compound observation also reconciles lost disable/clear replies.
            script = "omarchy sudo passwordless --disable && sudo -K && if omarchy sudo passwordless --active; then exit 1; else test \"$?\" -eq 1; fi"
        case .configureDockerOwnerAccess:
            // Native --configured uses status 0 to request configuration and 1
            // for configured. Any other status is an error, never consent.
            script = """
            if omarchy-sudo-docker --configured; then
              OMARCHY_DEFER_REBOOT=1 omarchy-setup-security-sudoless-docker || exit "$?"
            else
              test "$?" -eq 1 || exit 1
            fi
            if omarchy-sudo-docker --configured; then exit 1; else test "$?" -eq 1; fi
            """
        case .verifyOwnerDockerAccess:
            script = "env -u DOCKER_HOST -u DOCKER_CONTEXT /usr/bin/docker --host unix:///var/run/docker.sock version --format '{{.Server.Version}}' && /usr/bin/docker compose version && /usr/bin/docker buildx version"
        default: return nil
        }
        return NativeGuestInvocation(arguments: ["bash", "-lc", script], requiresInteractiveTerminal: interactive,
                                     acceptsNonterminalInput: false)
    }
}
