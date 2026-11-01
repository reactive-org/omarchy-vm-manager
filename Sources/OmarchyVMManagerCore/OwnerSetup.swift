import Foundation

public struct OwnerKeyboard: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let keymap: String
    public let inputMethod: String
    public let xkbLayout: String
}

public struct OwnerSetupContract: Codable, Sendable {
    public let schemaVersion: Int
    public let programs: [String: String]
    public let keyboards: [OwnerKeyboard]
    public static let current: OwnerSetupContract = {
        guard let url = ManagerResources.bundle.url(forResource: "OwnerSetupContract", withExtension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data), value.schemaVersion == 1 else {
            preconditionFailure("Missing reviewed owner setup contract")
        }
        return value
    }()
}

public struct OwnerConfiguration: Codable, Equatable, Sendable {
    public var username: String
    public var fullName: String
    public var email: String
    public var hostnamePrefix: String
    public var timezone: String
    public var keyboardID: String
    public init(username: String = "omarchy", fullName: String = "", email: String = "", hostnamePrefix: String = "omarchy", timezone: String = "Same as macOS", keyboardID: String = "English (US)") {
        self.username = username; self.fullName = fullName; self.email = email
        self.hostnamePrefix = hostnamePrefix; self.timezone = timezone; self.keyboardID = keyboardID
    }
    public func validate() throws {
        let reserved: Set<String> = ["root", "bin", "daemon", "mail", "ftp", "http", "nobody", "dbus", "systemd-coredump", "systemd-network", "systemd-oom", "systemd-journal-remote", "systemd-resolve", "systemd-timesync", "tss", "uuidd", "alpm", "git", "avahi", "cups", "cups-browsed", "lp", "_talkd", "polkitd", "rtkit", "qemu", "brltty", "gluster", "rpc", "libvirt-qemu", "pcscd", "nvidia-persistenced", "sddm"]
        guard username.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil, !reserved.contains(username) else { throw Self.invalid("Choose a non-system username using lowercase letters, numbers, underscores or hyphens.") }
        guard hostnamePrefix.range(of: "^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$", options: .regularExpression) != nil else { throw Self.invalid("Use a hostname prefix of 1–40 lowercase letters, numbers or hyphens, starting and ending with a letter or number.") }
        for value in [fullName, email] {
            guard value.utf8.count <= 256, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Self.invalid("Name and email must be single-line values of at most 256 bytes.") }
        }
        guard email.isEmpty || (email.filter { $0 == "@" }.count == 1 && !email.contains(where: \.isWhitespace) && !email.hasPrefix("@") && !email.hasSuffix("@")) else { throw Self.invalid("Enter an email address or leave it empty.") }
        guard timezone == "Same as macOS" || timezone == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(timezone) else { throw Self.invalid("Choose a supported time zone.") }
        guard OwnerSetupContract.current.keyboards.contains(where: { $0.id == keyboardID }) else { throw Self.invalid("Choose a supported keyboard layout.") }
    }
    public static func validatePassword(_ data: Data) throws {
        guard let value = String(data: data, encoding: .utf8), (8...1024).contains(data.count),
              !value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { throw invalid("Use a password of 8–1024 UTF-8 bytes without line breaks or NUL characters.") }
    }
    static func invalid(_ message: String) -> VMFailure { VMFailure(code: "invalid-owner-defaults", message: message) }
}

/// Creation-only, non-secret changes layered over a saved Guest Defaults snapshot.
public struct GuestOwnerOverrides: Codable, Equatable, Sendable {
    public var username: String?
    public var fullName: String?
    public var email: String?
    public var hostnamePrefix: String?
    public var timezone: String?
    public var keyboardID: String?
    public init(username: String? = nil, fullName: String? = nil, email: String? = nil,
                hostnamePrefix: String? = nil, timezone: String? = nil, keyboardID: String? = nil) {
        self.username = username; self.fullName = fullName; self.email = email
        self.hostnamePrefix = hostnamePrefix; self.timezone = timezone; self.keyboardID = keyboardID
    }
    public func applying(to saved: OwnerConfiguration) throws -> OwnerConfiguration {
        guard username != nil || fullName != nil || email != nil || hostnamePrefix != nil || timezone != nil || keyboardID != nil else {
            throw OwnerConfiguration.invalid("Supply at least one owner override.")
        }
        var value = saved
        if let username { value.username = username }
        if let fullName { value.fullName = fullName }
        if let email { value.email = email }
        if let hostnamePrefix { value.hostnamePrefix = hostnamePrefix }
        if let timezone { value.timezone = timezone }
        if let keyboardID { value.keyboardID = keyboardID }
        try value.validate()
        return value
    }
    static func validateJSON(_ object: Any) throws {
        guard let fields = object as? [String: Any],
              Set(fields.keys).isSubset(of: ["username", "fullName", "email", "hostnamePrefix", "timezone", "keyboardID"]),
              fields.values.allSatisfy({ $0 is String }) else {
            throw commandFailure("invalid-config", "Owner overrides must contain only supported, non-null text settings.")
        }
    }
}

public struct OwnerDefaults: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: UUID
    public let enabled: Bool
    public let configuration: OwnerConfiguration
    public let credentialReference: UUID?
    public let sshPublicKey: String?
    public init(revision: UUID = UUID(), enabled: Bool = false, configuration: OwnerConfiguration = OwnerConfiguration(), credentialReference: UUID? = nil, sshPublicKey: String? = nil) {
        schemaVersion = 1; self.revision = revision; self.enabled = enabled
        self.configuration = configuration; self.credentialReference = credentialReference; self.sshPublicKey = sshPublicKey
    }
    public func validate() throws {
        guard schemaVersion == 1, !enabled || credentialReference != nil else { throw OwnerConfiguration.invalid("Unattended setup needs saved credentials. Existing settings were preserved.") }
        try configuration.validate()
        if let sshPublicKey { guard try SSHPublicKey.canonical(sshPublicKey) == sshPublicKey else { throw OwnerConfiguration.invalid("The saved SSH public key is malformed.") } }
    }
    public func snapshot(for id: UUID) throws -> OwnerSetupOptions? {
        try validate(); guard enabled, let credentialReference else { return nil }
        return OwnerSetupOptions(defaultsRevision: revision, configuration: configuration, credentialReference: credentialReference, hostname: configuration.hostnamePrefix + "-" + id.uuidString.prefix(8).lowercased())
    }
}

public struct OwnerSetupOptions: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let defaultsRevision: UUID
    public let configuration: OwnerConfiguration
    public let credentialReference: UUID
    public let hostname: String
    public init(defaultsRevision: UUID, configuration: OwnerConfiguration, credentialReference: UUID, hostname: String) {
        schemaVersion = 1; self.defaultsRevision = defaultsRevision; self.configuration = configuration
        self.credentialReference = credentialReference; self.hostname = hostname
    }
    public func validate(for id: UUID) throws {
        try configuration.validate()
        guard schemaVersion == 1, hostname == configuration.hostnamePrefix + "-" + id.uuidString.prefix(8).lowercased() else { throw OwnerConfiguration.invalid("Unknown or mismatched unattended setup snapshot. Existing data was preserved.") }
    }
    public func fingerprint() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return KitVerifier.sha256(try encoder.encode(self))
    }
}

public enum OwnerSetupReadiness: Equatable, Sendable {
    case manual, pending, provisioning, configured, failed(String)
    public var label: String {
        switch self {
        case .manual: "Manual setup"
        case .pending: "Saved defaults · waiting for first boot"
        case .provisioning: "Applying saved setup defaults"
        case .configured: "Owner setup completed"
        case .failed(let message): message
        }
    }
}
