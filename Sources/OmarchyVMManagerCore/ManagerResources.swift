import Foundation

// SwiftPM's generated accessor differs between toolchains. Packaged apps must
// resolve their embedded bundle rather than falling back to a builder's path.
enum ManagerResources {
    static var bundle: Bundle {
        let executableResources = Bundle.main.executableURL?
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        for directory in [Bundle.main.resourceURL, executableResources].compactMap({ $0 }) {
            if let bundle = Bundle(url: directory.appendingPathComponent("OmarchyVMManager_OmarchyVMManagerCore.bundle")) {
                return bundle
            }
        }
        return .module
    }
}
