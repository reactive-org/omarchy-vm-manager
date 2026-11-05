import Foundation

/// A build identity, never a preference or an environment override. Every
/// executable in an app is compiled for the same channel.
public enum AppChannel: String, CaseIterable, Sendable {
    case stable, development

    public static var current: Self {
        #if DEVELOPMENT_CHANNEL
        .development
        #else
        .stable
        #endif
    }

    public var displayName: String { self == .stable ? "Omarchy VM Manager" : "Omarchy VM Manager Dev" }
    public var bundleIdentifier: String { self == .stable ? "dev.omarchy.vm-manager" : "dev.omarchy.vm-manager.dev" }
    public var cliName: String { self == .stable ? "omarchy-vm" : "omarchy-vm-dev" }
    public var activationNotification: String { bundleIdentifier + ".activate" }
    public var credentialService: String { bundleIdentifier + ".unattended.biometric.v1" }
    public var legacyCredentialService: String { bundleIdentifier + ".unattended" }
    public var sshPorts: ClosedRange<Int> { self == .stable ? 2222...49151 : 49200...59999 }

    public func directory(in applicationSupport: URL) -> URL {
        applicationSupport.resolvingSymlinksInPath().appendingPathComponent(displayName, isDirectory: true)
    }

    /// Existing stable sockets retain their exact identity, including clients
    /// talking to an already installed stable app.
    public func commandIdentity(in applicationSupport: URL) -> String {
        let path = applicationSupport.resolvingSymlinksInPath().path
        return self == .stable ? path : path + "/" + bundleIdentifier
    }

    public func validateBundle(identifier: String?, layoutPreview: Bool = false) throws {
        let expected = layoutPreview ? "dev.omarchy.vm-manager.layout-preview" : bundleIdentifier
        guard identifier == expected else {
            throw VMFailure(code: "app-channel-mismatch", message: "This executable does not match its app channel. Rebuild the complete app before using it.")
        }
    }

    /// Resolve the containing app for auxiliary executables and symlinked CLIs.
    /// Never choose a channel from a user-supplied path or a renamed executable.
    public func enclosingApp(for executable: URL) throws -> URL {
        let executable = executable.resolvingSymlinksInPath()
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              app.pathExtension == "app", let bundle = Bundle(url: app) else {
            throw VMFailure(code: "app-required", message: "Run the bundled \(cliName) from a complete \(displayName) app.")
        }
        try validateBundle(identifier: bundle.bundleIdentifier)
        return app
    }

    public func guestName(_ name: String) -> String {
        guard self == .development else { return name }
        var shortened = String(name.prefix(58))
        while shortened.utf8.count > 249 { shortened.removeLast() }
        shortened = shortened.trimmingCharacters(in: .whitespacesAndNewlines)
        return shortened.isEmpty ? "[Dev]" : "[Dev] " + shortened
    }

    public func validateRuntimeChannels(_ version: Int?) throws {
        guard self == .stable || version == 1 else {
            throw VMFailure(code: "unproven-channel-runtime", message: "Dev requires the verified runtime with separate development caches and guest authentication keys.")
        }
    }
}
