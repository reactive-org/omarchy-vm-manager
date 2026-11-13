import Foundation

public struct HomebrewProvisioningDependencies: ProvisioningDependencyProviding {
    private let configuration: ProvisioningToolConfiguration
    private let files: any ProvisioningToolFiles
    private let probes: any ProvisioningToolProbing
    public init(configuration: ProvisioningToolConfiguration = .host()) {
        self.init(configuration: configuration, files: LocalProvisioningToolFiles(), probes: LocalProvisioningToolProbe())
    }
    init(configuration: ProvisioningToolConfiguration, files: any ProvisioningToolFiles, probes: any ProvisioningToolProbing) {
        self.configuration = configuration; self.files = files; self.probes = probes
    }

    public func inspect() async throws -> ProvisioningToolReport {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("omarchy-tool-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        let config = workspace.appendingPathComponent("ansible.cfg")
        let inventory = workspace.appendingPathComponent("inventory.ini")
        let playbook = workspace.appendingPathComponent("syntax.yml")
        try PrivateFiles.write(Data(Self.ansibleConfig.utf8), name: config.lastPathComponent, in: workspace)
        try PrivateFiles.write(Data("[provisioning_probe]\nfixture.invalid\n".utf8), name: inventory.lastPathComponent, in: workspace)
        try PrivateFiles.write(Data(Self.syntaxPlaybook.utf8), name: playbook.lastPathComponent, in: workspace)

        var directories = unique(configuration.homebrewDirectories + configuration.searchDirectories + ["/usr/bin", "/bin"])
        var results: [ProvisioningToolResult] = []
        let ansibleTools: [ProvisioningTool] = [.ansiblePlaybook, .ansibleInventory]

        func locate(_ tool: ProvisioningTool) -> ProvisioningExecutable? {
            if [.bash, .ssh, .scp, .sftp].contains(tool) {
                return files.executable((tool == .bash ? "/bin/" : "/usr/bin/") + tool.rawValue)
            }
            if let override = configuration.overrides[tool] { return files.executable(override) }
            return directories.lazy.compactMap { files.executable($0 + "/" + tool.rawValue) }.first
        }
        func environment() -> [String: String] {
            ["PATH": directories.joined(separator: ":"), "HOME": workspace.path, "TMPDIR": workspace.path,
             "LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1", "PYTHONSAFEPATH": "1",
             "ANSIBLE_CONFIG": config.path, "ANSIBLE_HOME": workspace.appendingPathComponent("ansible").path,
             "ANSIBLE_LOCAL_TEMP": workspace.appendingPathComponent("tmp").path,
             "ANSIBLE_COLLECTIONS_PATH": workspace.appendingPathComponent("collections").path,
             "ANSIBLE_ROLES_PATH": workspace.appendingPathComponent("roles").path, "ANSIBLE_NOCOLOR": "1",
             "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1",
             "GH_CONFIG_DIR": workspace.appendingPathComponent("gh").path, "GH_PROMPT_DISABLED": "1"]
        }
        func probe(_ executable: ProvisioningExecutable, _ arguments: [String], origin: ProvisioningInstallation? = nil) async throws -> ProvisioningProbeResult {
            try Task.checkCancellation()
            guard files.executable(executable.identity.path) == executable,
                  origin == nil || files.directory(origin!.identity.path) == origin else { return .failed(.changed) }
            let result = await probes.run(.init(executable: executable.identity, arguments: arguments,
                environment: environment(), workingDirectory: workspace.path))
            try Task.checkCancellation()
            guard files.executable(executable.identity.path) == executable,
                  origin == nil || files.directory(origin!.identity.path) == origin else { return .failed(.changed) }
            return result
        }
        func record(_ tool: ProvisioningTool, _ executable: ProvisioningExecutable?, _ result: ProvisioningProbeResult? = nil) -> ProvisioningToolResult {
            guard let executable else {
                return .init(tool: tool, status: configuration.overrides[tool] == nil ? .missing : .checkFailed,
                    reason: configuration.overrides[tool] == nil ? "Executable not found." : "The explicit tool path is invalid or unavailable; no fallback was used.")
            }
            let provider = configuration.overrides[tool] != nil ? "override" :
                ([.bash, .ssh, .scp, .sftp].contains(tool) ? "macOS" : "host")
            if let result, let reason = Self.failureReason(result) {
                return .init(tool: tool, status: .checkFailed, executable: executable.identity, provider: provider, reason: reason)
            }
            return .init(tool: tool, status: .available, executable: executable.identity, provider: provider, reason: "Tool check passed.")
        }

        let brew = locate(.brew)
        let brewProbe = try await brew.asyncMap { try await probe($0, ["--version"]) }
        var brewResult = record(.brew, brew, brewProbe)
        if brewResult.status == .available, let brew, let brewProbe {
            if let version = Self.capture("^Homebrew ([0-9]+\\.[0-9]+\\.[0-9]+)(?:\\s|$)", brewProbe.output) {
                brewResult.version = version
                let prefix = try await probe(brew, ["--prefix"])
                if let path = Self.prefix(prefix) {
                    directories = unique(configuration.homebrewDirectories + [path + "/bin"] + configuration.searchDirectories + ["/usr/bin", "/bin"])
                } else { brewResult.status = .checkFailed; brewResult.reason = "Homebrew prefix check failed; system tools remain independent." }
            } else { brewResult.status = .checkFailed; brewResult.reason = "Homebrew version output was not recognized." }
        }
        results.append(brewResult)

        var installation: ProvisioningInstallation?
        var installationStatus = ProvisioningToolStatus.missing
        var installationReason = "A verified Homebrew Ansible installation is required. No Ansible command was executed."
        if brewResult.status == .available, let brew {
            // This installed-prefix query never installs, updates or builds a package.
            let prefix = try await probe(brew, ["--prefix", "--installed", "ansible"])
            if let failure = prefix.failure {
                installationStatus = .checkFailed; installationReason = "Homebrew Ansible prefix probe failed (" + failure.rawValue + ")."
            } else if prefix.status != 0 {
                installationReason = "Homebrew did not report an installed ansible formula. No installation was attempted."
            } else if let path = Self.prefix(prefix), let directory = files.directory(path) {
                installation = directory
            } else {
                installationStatus = .checkFailed; installationReason = "Homebrew returned an invalid or unavailable Ansible installation prefix."
            }
        } else if brewResult.status != .missing { installationStatus = .checkFailed }

        for tool in [ProvisioningTool.bash, .ssh, .scp, .sftp] {
            let executable = locate(tool)
            let args = tool == .bash ? ["--noprofile", "--norc", "--version"] : ["-V"]
            // scp/sftp expose no stable version-only command. No connections run.
            let output = [.scp, .sftp].contains(tool) ? nil : try await executable.asyncMap { try await probe($0, args) }
            var value = record(tool, executable, output)
            if value.status == .available {
                if let output {
                    // OpenSSH intentionally writes its version to stderr.
                    let versionOutput = tool == .ssh ? output.output + output.standardError : output.output
                    value.version = Self.capture(tool == .bash ? "^GNU bash, version ([0-9]+\\.[0-9]+\\.[0-9]+)" : "^OpenSSH_([0-9]+\\.[0-9]+[a-z0-9]*)", versionOutput)
                    if value.version == nil { value.status = .checkFailed; value.reason = "System tool version output was not recognized." }
                } else { value.reason = "Fixed macOS executable is present; no connection was attempted." }
            }
            results.append(value)
        }

        var commands: [ProvisioningTool: ProvisioningExecutable] = [:]
        var pair: [ProvisioningToolResult] = []
        for tool in ansibleTools {
            let expected = installation.flatMap { files.executable($0.identity.path + "/bin/" + tool.rawValue) }
            let executable = configuration.overrides[tool].flatMap { files.executable($0) } ??
                (configuration.overrides[tool] == nil ? expected : nil)
            var value = record(tool, executable)
            if let installation {
                value.installation = installation.identity
                if let executable {
                    guard let expected, executable.resolvedPath == expected.resolvedPath,
                          executable.resolvedPath.hasPrefix(installation.resolvedPath + "/"),
                          URL(fileURLWithPath: executable.resolvedPath).lastPathComponent == tool.rawValue else {
                        value.status = .incompatible
                        value.reason = "The command does not match Homebrew's active Ansible installation; no fallback or execution was attempted."
                        pair.append(value); continue
                    }
                    commands[tool] = executable
                    let output = try await probe(executable, ["--version"], origin: installation)
                    value = record(tool, executable, output); value.installation = installation.identity
                    value.provider = configuration.overrides[tool] == nil ? "homebrew" : "override"
                    if value.status == .available {
                        if let version = Self.capture("^" + tool.rawValue + " \\[core ([0-9]+\\.[0-9]+\\.[0-9]+)\\]\\r?$", output.output) {
                            value.version = version
                            if !Self.supportedCore(version) { value.status = .incompatible; value.reason = "Dependency policy requires stable Ansible Core 2.21.x." }
                        } else { value.status = .incompatible; value.reason = "Ansible did not report a recognized stable Core version." }
                    }
                }
            } else {
                value.status = installationStatus; value.reason = installationReason
                if configuration.overrides[tool] != nil, installationStatus == .missing { value.status = .incompatible }
            }
            pair.append(value)
        }

        if pair.allSatisfy({ $0.status == .available }), pair[0].version == pair[1].version,
           let installation, let inventoryCommand = commands[.ansibleInventory], let playbookCommand = commands[.ansiblePlaybook] {
            let inventoryCheck = try await probe(inventoryCommand, ["-i", inventory.path, "--list"], origin: installation)
            var reason = Self.failureReason(inventoryCheck)
            if reason == nil, !Self.validInventory(inventoryCheck.output) { reason = "Inventory self-check returned unexpected data; raw output was discarded." }
            if reason == nil {
                let syntaxCheck = try await probe(playbookCommand, ["--syntax-check", "-i", inventory.path, playbook.path], origin: installation)
                reason = Self.failureReason(syntaxCheck)
                let text = String(decoding: syntaxCheck.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let expected = ["playbook: " + playbook.path, "playbook: " + playbook.resolvingSymlinksInPath().path]
                if reason == nil, !expected.contains(text) { reason = "Syntax self-check returned unexpected output; raw output was discarded." }
            }
            for index in pair.indices {
                pair[index].status = reason == nil ? .available : .checkFailed
                pair[index].reason = reason.map { "Ansible CLI self-check failed. " + $0 } ?? "Homebrew command pair, Core versions, static inventory and syntax checks passed. No task or guest connection was executed."
            }
        } else {
            for index in pair.indices where pair[index].status == .available {
                pair[index].status = .incompatible
                pair[index].reason = "Both Homebrew Ansible commands must report the same supported Core version before local self-checks can run."
            }
        }
        results += pair

        let gh = locate(.gh)
        let ghOutput = try await gh.asyncMap { try await probe($0, ["--version"]) }
        var ghResult = record(.gh, gh, ghOutput)
        if ghResult.status == .available, let ghOutput {
            ghResult.version = Self.capture("^gh version ([0-9]+\\.[0-9]+\\.[0-9]+)", ghOutput.output)
            if ghResult.version != nil {
                ghResult.status = .needsAuthentication; ghResult.reason = "CLI is present. Authentication is unverified; no credentials or tokens are read."
            } else { ghResult.status = .checkFailed; ghResult.reason = "GitHub CLI version output was not recognized." }
        }
        results.append(ghResult)
        try Task.checkCancellation()
        var changed: Set<ProvisioningTool> = []
        for value in results {
            if let identity = value.executable, files.executable(identity.path)?.identity != identity { changed.insert(value.tool) }
        }
        let pairChanged = !changed.isDisjoint(with: Set(ansibleTools + [.brew])) ||
            (installation != nil && files.directory(installation!.identity.path) != installation)
        for index in results.indices {
            if changed.contains(results[index].tool) || (pairChanged && ansibleTools.contains(results[index].tool)) {
                results[index].status = .checkFailed; results[index].reason = "Tool or Homebrew installation changed during discovery. Check again."
            }
        }
        return ProvisioningToolReport(tools: results)
    }

    private static func prefix(_ result: ProvisioningProbeResult) -> String? {
        guard result.failure == nil, result.status == 0, let text = String(data: result.output, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProvisioningToolConfiguration.validPath(path) ? path : nil
    }
    private static func failureReason(_ result: ProvisioningProbeResult) -> String? {
        if let failure = result.failure { return "Tool probe failed (" + failure.rawValue + ")." }
        if result.status != 0 { return "Tool probe returned an error (exit \(result.status)); raw output was discarded." }
        return nil
    }
    private static func capture(_ pattern: String, _ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    private static func supportedCore(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        return value.count < 32 && parts.count == 3 && parts[0] == 2 && parts[1] == 21
    }
    private static func validInventory(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys).isSubset(of: ["_meta", "all", "provisioning_probe", "ungrouped"]),
              let meta = root["_meta"] as? [String: Any], Set(meta.keys).isSubset(of: ["hostvars", "profile"]),
              let vars = meta["hostvars"] as? [String: Any],
              vars.isEmpty || Set(vars.keys) == ["fixture.invalid"],
              let all = root["all"] as? [String: Any], Set(all.keys) == ["children"],
              let children = all["children"] as? [String], children.count == 2, Set(children) == ["ungrouped", "provisioning_probe"],
              let group = root["provisioning_probe"] as? [String: Any], Set(group.keys) == ["hosts"],
              group["hosts"] as? [String] == ["fixture.invalid"] else { return false }
        if let profile = meta["profile"], !(profile is String) { return false }
        if let host = vars["fixture.invalid"] {
            guard let values = host as? [String: Any], Set(values.keys).isSubset(of: ["ansible_local"]) else { return false }
            // Core 2.21 can include the empty local-facts namespace even though no
            // facts have been gathered. No other or nonempty variables are allowed.
            if let local = values["ansible_local"], (local as? [String: Any])?.isEmpty != true { return false }
        }
        if let ungrouped = root["ungrouped"], (ungrouped as? [String: Any])?.isEmpty != true { return false }
        return true
    }
    private static let ansibleConfig = """
    [defaults]
    retry_files_enabled = false
    inject_facts_as_vars = false
    vars_plugins_enabled =
    [inventory]
    enable_plugins = ini
    """
    private static let syntaxPlaybook = """
    ---
    - name: Manager dependency syntax probe
      hosts: provisioning_probe
      gather_facts: false
      tasks:
        - name: Syntax validation only
          ansible.builtin.debug:
            msg: provisioning-probe
    """
}

private func unique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
}

private extension Optional where Wrapped: Sendable {
    func asyncMap<T: Sendable>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
