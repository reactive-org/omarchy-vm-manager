import Foundation

public enum ProvisioningTool: String, Codable, CaseIterable, Sendable {
    case brew, bash, ssh, scp, sftp
    case ansiblePlaybook = "ansible-playbook"
    case ansibleInventory = "ansible-inventory"
    case gh

    public var title: String {
        switch self {
        case .brew: "Homebrew"
        case .bash: "Bash"
        case .ssh: "OpenSSH"
        case .scp: "SCP"
        case .sftp: "SFTP"
        case .ansiblePlaybook: "Ansible Playbook"
        case .ansibleInventory: "Ansible Inventory"
        case .gh: "GitHub CLI"
        }
    }
    public var installCommand: String? {
        switch self {
        case .brew, .bash, .ssh, .scp, .sftp: nil
        case .ansiblePlaybook, .ansibleInventory: "brew install ansible"
        case .gh: "brew install gh"
        }
    }
}

public enum ProvisioningToolStatus: String, Codable, Sendable {
    case available, missing, incompatible
    case needsAuthentication = "needs-authentication"
    case checkFailed = "check-failed"
    public var label: String {
        switch self {
        case .available: "Available"
        case .missing: "Missing"
        case .incompatible: "Incompatible"
        case .needsAuthentication: "Needs authentication"
        case .checkFailed: "Check failed"
        }
    }
}

public struct ProvisioningToolIdentity: Codable, Equatable, Sendable {
    public let path: String
    public let fingerprint: String
}

public struct ProvisioningToolResult: Codable, Equatable, Identifiable, Sendable {
    public var id: ProvisioningTool { tool }
    public let tool: ProvisioningTool
    public var status: ProvisioningToolStatus
    public var version: String?
    public var executable: ProvisioningToolIdentity?
    public var provider: String
    public var reason: String
    public var installation: ProvisioningToolIdentity?
    public let installCommand: String?
    public init(tool: ProvisioningTool, status: ProvisioningToolStatus, version: String? = nil,
                executable: ProvisioningToolIdentity? = nil, provider: String = "host", reason: String,
                installation: ProvisioningToolIdentity? = nil) {
        self.tool = tool; self.status = status; self.version = version; self.executable = executable
        self.provider = provider; self.reason = reason; self.installation = installation; installCommand = tool.installCommand
    }
}

public enum ProvisioningCapability: String, Codable, CaseIterable, Sendable {
    case jsonPlanning = "json-planning"
    case basicProvisioning = "basic-provisioning"
    case yamlPlanning = "yaml-planning"
    case developerFeatures = "developer-features"
    case externalSetup = "external-setup"
    case githubStarThemes = "github-star-themes"
    case remoteSetup = "remote-setup"
    case imageBuilding = "image-building"
    public var title: String {
        switch self {
        case .jsonPlanning: "JSON setup preview"
        case .basicProvisioning: "Basic provisioning"
        case .yamlPlanning: "YAML setup preview"
        case .developerFeatures: "Developer features"
        case .externalSetup: "External setups"
        case .githubStarThemes: "Themes by GitHub stars"
        case .remoteSetup: "Remote setup retrieval"
        case .imageBuilding: "Custom image building"
        }
    }
}

public struct ProvisioningFeatureGate: Codable, Equatable, Identifiable, Sendable {
    public var id: ProvisioningCapability { capability }
    public let capability: ProvisioningCapability
    public let toolsReady: Bool
    public let implemented: Bool
    public let enabled: Bool
    public let blockers: [ProvisioningTool]
    public let reason: String
}

public struct ProvisioningToolReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let tools: [ProvisioningToolResult]
    public let features: [ProvisioningFeatureGate]
    public let policy: String
    public init(tools: [ProvisioningToolResult]) {
        schemaVersion = 2; self.tools = tools
        policy = "Homebrew Ansible Core 2.21.x with local CLI self-checks. No separate Python/PyYAML requirement. The pinned Swift engine supports offline helper planning; setup UI/CLI execution is disabled."
        features = ProvisioningCapability.allCases.map { capability in
            let required: [ProvisioningTool]
            switch capability {
            case .jsonPlanning, .yamlPlanning: required = []
            case .basicProvisioning: required = [.bash, .ssh, .scp, .sftp]
            case .developerFeatures, .externalSetup:
                required = [.brew, .bash, .ssh, .scp, .sftp, .ansiblePlaybook, .ansibleInventory]
            case .githubStarThemes: required = [.bash, .ssh, .gh]
            case .remoteSetup, .imageBuilding: required = []
            }
            let deferred = capability == .remoteSetup || capability == .imageBuilding
            let blockers = required.filter { tool in tools.first(where: { $0.tool == tool })?.status != .available }
            return ProvisioningFeatureGate(capability: capability, toolsReady: !deferred && blockers.isEmpty,
                implemented: false, enabled: false, blockers: blockers,
                reason: deferred ? "Deferred; dependencies are not probed." :
                    (capability == .jsonPlanning || capability == .yamlPlanning ? "No external tools required; pinned offline helper APIs are integrated, while the setup UI/CLI workflow is disabled." :
                     (blockers.isEmpty ? "Tool prerequisites pass; setup execution remains disabled." : "Required tools are missing, incompatible or unverified.")))
        }
    }
    public func tool(_ id: ProvisioningTool) -> ProvisioningToolResult? { tools.first { $0.tool == id } }
}

public protocol ProvisioningDependencyProviding: Sendable {
    func inspect() async throws -> ProvisioningToolReport
}

public struct ProvisioningToolConfiguration: Sendable {
    public var overrides: [ProvisioningTool: String]
    public var searchDirectories: [String]
    public var homebrewDirectories: [String]
    public init(overrides: [ProvisioningTool: String] = [:], searchDirectories: [String] = [],
                homebrewDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) {
        self.overrides = overrides
        self.searchDirectories = Array(searchDirectories.filter(Self.validPath).prefix(32))
        self.homebrewDirectories = Array(homebrewDirectories.filter(Self.validPath).prefix(8))
    }
    public static func host(overrides: [ProvisioningTool: String] = [:]) -> Self {
        Self(overrides: overrides, searchDirectories: (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init))
    }
    static func validPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 1024 &&
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
            !value.split(separator: "/").contains("..")
    }
}

/// A separate local command: never opens the manager or reads a guest registry.
public struct ProvisioningToolsInvocation: Sendable {
    public let overrides: [ProvisioningTool: String]
    public static func parse(_ arguments: [String]) throws -> Self? {
        guard arguments.first == "setup" else { return nil }
        guard arguments.count >= 2, arguments[1] == "tools" else { return nil }
        var overrides: [ProvisioningTool: String] = [:], index = 2
        while index < arguments.count {
            guard arguments[index] == "--tool", index + 1 < arguments.count else { throw invalid() }
            let parts = arguments[index + 1].split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, ["python", "python3", "yaml", "pyyaml"].contains(parts[0]) {
                throw VMFailure(code: "retired-tool-override", message: "Dependency report schema 2 no longer accepts Python/PyYAML overrides. Select Homebrew's Ansible commands with --tool ansible-playbook=/absolute/path and --tool ansible-inventory=/absolute/path.")
            }
            guard parts.count == 2, let tool = ProvisioningTool(rawValue: parts[0]),
                  ![.bash, .ssh, .scp, .sftp].contains(tool), overrides[tool] == nil,
                  ProvisioningToolConfiguration.validPath(parts[1]) else { throw invalid() }
            overrides[tool] = parts[1]; index += 2
        }
        return Self(overrides: overrides)
    }
    private static func invalid() -> VMFailure {
        VMFailure(code: "usage", message: "Use setup tools [--tool brew|ansible-playbook|ansible-inventory|gh=/absolute/path].")
    }
}
