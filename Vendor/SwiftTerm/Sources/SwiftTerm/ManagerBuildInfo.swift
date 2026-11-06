// Manager integration overlay: deterministic identity, no host git/build plugin.
public enum SwiftTermBuildInfo {
    public static let tag: String? = "v1.99.0"
    public static let branch: String? = nil
    public static let commit: String? = "2dad6a1e516f755bed77cf9bbd09455062f54758"
    public static let hasUncommittedChanges: Bool? = false
    public static let version = "1.99.0"
}
enum SwiftTermTerminfo { static let xtgettcapReplies: [String: String] = [:] }
#if os(macOS)
import AppKit
@MainActor public extension TerminalView {
    /// Manager-only integration: no arbitrary terminal access is exposed.
    func configureProvisioningDisplay() {
        withTerminal { $0.silentLog = true }
        changeScrollback(500)
    }
}
#endif
