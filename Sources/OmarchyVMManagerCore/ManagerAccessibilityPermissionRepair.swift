import Foundation

public enum ManagerAccessibilityPermissionRepair {
    public static let bundleIdentifier = "dev.omarchy.vm-manager"

    public static func resetCurrentAppEntry() -> Bool {
        resetStaleEntry(bundleIdentifier: Bundle.main.bundleIdentifier,
                        tccutilURL: URL(fileURLWithPath: "/usr/bin/tccutil"))
    }

    static func resetStaleEntry(bundleIdentifier: String?, tccutilURL: URL) -> Bool {
        guard bundleIdentifier == Self.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = tccutilURL
        process.arguments = ["reset", "Accessibility", Self.bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0
        } catch { return false }
    }
}
