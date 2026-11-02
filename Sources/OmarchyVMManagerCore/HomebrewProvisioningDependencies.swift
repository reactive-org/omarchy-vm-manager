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
        try Data("[defaults]\nretry_files_enabled = false\ninject_facts_as_vars = false\n".utf8).write(to: config)
        var directories = unique(configuration.homebrewDirectories + configuration.searchDirectories + ["/usr/bin", "/bin"])
        var results: [ProvisioningToolResult] = []

        func locate(_ tool: ProvisioningTool, directories: [String]) -> ProvisioningExecutable? {
            if [.bash, .ssh, .scp, .sftp].contains(tool) {
                return files.executable((tool == .bash ? "/bin/" : "/usr/bin/") + tool.rawValue)
            }
            if let override = configuration.overrides[tool] { return files.executable(override) }
            return directories.lazy.compactMap { directory -> ProvisioningExecutable? in
                let path = directory + "/" + (tool == .python ? "python3" : tool.rawValue)
                // Apple's Python entry can invoke developer-tool installation UI.
                if tool == .python, path == "/usr/bin/python3" { return nil }
                return files.executable(path)
            }.first
        }
        func environment(_ directories: [String]) -> [String: String] {
            ["PATH": directories.joined(separator: ":"), "HOME": workspace.path, "TMPDIR": workspace.path,
             "LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1", "PYTHONSAFEPATH": "1",
             "ANSIBLE_CONFIG": config.path, "ANSIBLE_HOME": workspace.appendingPathComponent("ansible").path,
             "ANSIBLE_LOCAL_TEMP": workspace.appendingPathComponent("tmp").path,
             "ANSIBLE_COLLECTIONS_PATH": workspace.appendingPathComponent("collections").path,
             "ANSIBLE_ROLES_PATH": workspace.appendingPathComponent("roles").path,
             "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1",
             "GH_CONFIG_DIR": workspace.appendingPathComponent("gh").path, "GH_PROMPT_DISABLED": "1"]
        }
        func probe(_ executable: ProvisioningExecutable, _ arguments: [String]) async throws -> ProvisioningProbeResult {
            try Task.checkCancellation()
            guard files.executable(executable.identity.path) == executable else { return .failed(.changed) }
            let result = await probes.run(.init(executable: executable.identity, arguments: arguments,
                environment: environment(directories), workingDirectory: workspace.path))
            try Task.checkCancellation()
            guard files.executable(executable.identity.path) == executable else { return .failed(.changed) }
            return result
        }
        func record(_ tool: ProvisioningTool, _ executable: ProvisioningExecutable?, _ result: ProvisioningProbeResult?) -> ProvisioningToolResult {
            guard let executable else {
                return .init(tool: tool, status: configuration.overrides[tool] == nil ? .missing : .checkFailed,
                    reason: configuration.overrides[tool] == nil ? "Executable not found." : "The explicit tool path is invalid or unavailable; no fallback was used.")
            }
            let provider = configuration.overrides[tool] != nil ? "override" :
                ([.bash, .ssh, .scp, .sftp].contains(tool) ? "macOS" : "host")
            if let failure = result?.failure {
                return .init(tool: tool, status: .checkFailed, executable: executable.identity, provider: provider,
                    reason: "Tool probe failed (" + failure.rawValue + ").")
            }
            guard result == nil || result?.status == 0 else {
                return .init(tool: tool, status: .checkFailed, executable: executable.identity, provider: provider, reason: "Tool probe returned an error (exit \(result?.status ?? -1)); raw output was discarded.")
            }
            return .init(tool: tool, status: .available, executable: executable.identity, provider: provider, reason: "Tool check passed.")
        }

        let brew = locate(.brew, directories: directories)
        let brewProbe = try await brew.asyncMap { try await probe($0, ["--version"]) }
        var brewResult = record(.brew, brew, brewProbe)
        if brewResult.status == .available, let brew, let brewProbe {
            if let version = Self.capture("^Homebrew ([0-9]+\\.[0-9]+\\.[0-9]+)(?:\\s|$)", brewProbe.output) {
                brewResult.version = version
                let prefix = try await probe(brew, ["--prefix"])
                let path = String(decoding: prefix.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if prefix.failure == nil, prefix.status == 0, ProvisioningToolConfiguration.validPath(path) {
                    directories = unique(configuration.homebrewDirectories + [path + "/bin"] + configuration.searchDirectories + ["/usr/bin", "/bin"])
                } else { brewResult.status = .checkFailed; brewResult.reason = "Homebrew prefix check failed; known paths remain usable." }
            } else { brewResult.status = .checkFailed; brewResult.reason = "Homebrew version output was not recognized." }
        }
        results.append(brewResult)

        for tool in [ProvisioningTool.bash, .ssh, .scp, .sftp] {
            let executable = locate(tool, directories: directories)
            let args = tool == .bash ? ["--noprofile", "--norc", "--version"] : ["-V"]
            // scp/sftp expose no stable version-only command. Verify their fixed
            // system executables, without starting a connection or parsing help.
            let output = [.scp, .sftp].contains(tool) ? nil : try await executable.asyncMap { try await probe($0, args) }
            var value = record(tool, executable, output)
            if value.status == .available {
                if let output {
                    value.version = Self.capture(tool == .bash ? "^GNU bash, version ([0-9]+\\.[0-9]+\\.[0-9]+)" : "^OpenSSH_([0-9]+\\.[0-9]+[a-z0-9]*)", output.output)
                    if value.version == nil { value.status = .checkFailed; value.reason = "System tool version output was not recognized." }
                } else { value.reason = "Fixed macOS executable is present; no connection was attempted." }
            }
            results.append(value)
        }

        let playbook = locate(.ansiblePlaybook, directories: directories)
        let inventory = locate(.ansibleInventory, directories: directories)
        let playbookPython = interpreter(for: playbook, directories: directories)
        let inventoryPython = interpreter(for: inventory, directories: directories)
        let python = configuration.overrides[.python] != nil ? locate(.python, directories: directories) :
            (playbookPython ?? inventoryPython ?? locate(.python, directories: directories))
        var pythonResult = record(.python, python, nil)
        var yamlResult = ProvisioningToolResult(tool: .yaml, status: .missing, reason: "Select a compatible Python runtime first.")
        var runtime: PythonReport?
        if let python, python.identity.path == "/usr/bin/python3" {
            pythonResult.status = .incompatible
            pythonResult.reason = "Apple's Python launcher is not probed because it may request developer-tool installation. Select a Homebrew Python runtime."
        } else if let python {
            let output = try await probe(python, ["-I", "-B", "-c", Self.pythonProbe])
            pythonResult = record(.python, python, output)
            if pythonResult.status == .available {
                if let info = try? JSONDecoder().decode(PythonReport.self, from: output.output),
                   info.python.count == 3, info.python.allSatisfy({ (0...10000).contains($0) }),
                   files.executable(info.executable)?.identity == python.identity {
                    runtime = info; pythonResult.version = info.python.map(String.init).joined(separator: ".")
                    if info.python[0] != 3 || !(11...14).contains(info.python[1]) || info.releaselevel != "final" {
                        pythonResult.status = .incompatible; pythonResult.reason = "Dependency policy requires a stable Python 3.11–3.14 runtime."
                    }
                    if let yaml = info.yaml, let version = Self.numericVersion(yaml) {
                        yamlResult = .init(tool: .yaml, status: pythonResult.status == .available ? .available : .incompatible,
                            version: yaml, provider: "python-runtime", reason: "PyYAML import checked in the selected Python runtime.", interpreter: python.identity)
                        if version[0] != 6 { yamlResult.status = .incompatible; yamlResult.reason = "Dependency policy requires PyYAML 6.x in the selected Python runtime." }
                    } else { yamlResult = .init(tool: .yaml, status: .missing, provider: "python-runtime",
                        reason: "PyYAML cannot be imported in the selected Python runtime. Recheck after installing Ansible; do not use a global pip install.", interpreter: python.identity) }
                } else { pythonResult.status = .checkFailed; pythonResult.reason = "Python returned an invalid runtime report or a different interpreter." }
            }
        }
        results += [pythonResult, yamlResult]

        for (tool, executable, interpreter) in [(ProvisioningTool.ansiblePlaybook, playbook, playbookPython), (.ansibleInventory, inventory, inventoryPython)] {
            var value = record(tool, executable, nil)
            value.interpreter = interpreter?.identity
            if let executable {
                guard let interpreter, let python, interpreter.identity == python.identity,
                      let runtime, pythonResult.status == .available, runtime.python[1] >= 12,
                      let core = runtime.ansible, Self.ansibleVersion(core), runtime.dependencies else {
                    value.status = .incompatible
                    value.reason = "Requires a matching Python 3.12–3.14 runtime with Ansible Core 2.21.x and its dependencies; ambiguous launchers are refused."
                    results.append(value); continue
                }
                let output = try await probe(executable, ["--version"])
                value = record(tool, executable, output); value.interpreter = interpreter.identity
                if value.status == .available {
                    let version = Self.capture("^" + tool.rawValue + " \\[core ([0-9]+\\.[0-9]+\\.[0-9]+)\\]", output.output)
                    if version == runtime.ansible { value.version = version }
                    else { value.status = .incompatible; value.reason = "Ansible launcher and selected Python package versions do not match." }
                }
            }
            results.append(value)
        }

        let gh = locate(.gh, directories: directories)
        let ghOutput = try await gh.asyncMap { try await probe($0, ["--version"]) }
        var ghResult = record(.gh, gh, ghOutput)
        if ghResult.status == .available, let ghOutput {
            ghResult.version = Self.capture("^gh version ([0-9]+\\.[0-9]+\\.[0-9]+)", ghOutput.output)
            if ghResult.version != nil {
                ghResult.status = .needsAuthentication
                ghResult.reason = "CLI is present. Authentication is not checked in milestone 1; no credentials or tokens are read."
            } else { ghResult.status = .checkFailed; ghResult.reason = "GitHub CLI version output was not recognized." }
        }
        results.append(ghResult)
        try Task.checkCancellation()
        // Recheck every selected entry after all probes, including Python symlinks
        // and script launchers, so an upgrade cannot produce a mixed ready report.
        for index in results.indices {
            let identities = [results[index].executable, results[index].interpreter].compactMap { $0 }
            if identities.contains(where: { files.executable($0.path)?.identity != $0 }) {
                results[index].status = .checkFailed; results[index].reason = "Tool changed during discovery. Check again."
            }
        }
        return ProvisioningToolReport(tools: results)
    }

    /// Accept direct absolute shebangs, or exactly /usr/bin/env python3 using the
    /// controlled search path. Shell wrappers, env options and extra args fail closed.
    private func interpreter(for executable: ProvisioningExecutable?, directories: [String]) -> ProvisioningExecutable? {
        guard let line = executable?.firstLine, line.hasPrefix("#!"), line.utf8.count < 1024 else { return nil }
        let words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if words.count == 1, ProvisioningToolConfiguration.validPath(words[0]),
           URL(fileURLWithPath: words[0]).lastPathComponent.hasPrefix("python") { return files.executable(words[0]) }
        if words == ["/usr/bin/env", "python3"] {
            return directories.lazy.compactMap { files.executable($0 + "/python3") }.first
        }
        return nil
    }

    private struct PythonReport: Decodable {
        let python: [Int]
        let releaselevel: String
        let executable: String
        let yaml: String?
        let ansible: String?
        let dependencies: Bool
    }
    private static let pythonProbe = """
    import sys, json, importlib
    def version(name):
        try: return str(importlib.import_module(name).__version__)
        except (Exception, SystemExit): return None
    def dependencies():
        try:
            for name in ('jinja2', 'cryptography', 'packaging', 'resolvelib', 'ansible.cli.playbook', 'ansible.cli.inventory'):
                importlib.import_module(name)
            return True
        except (Exception, SystemExit): return False
    print(json.dumps(dict(python=list(sys.version_info[:3]), releaselevel=sys.version_info.releaselevel, executable=sys.executable,
        yaml=version('yaml'), ansible=version('ansible.release'), dependencies=dependencies())))
    """
    private static func capture(_ pattern: String, _ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    private static func numericVersion(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }), value.count < 32 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }
    private static func ansibleVersion(_ value: String) -> Bool {
        guard let numbers = numericVersion(value), numbers.count == 3 else { return false }
        return numbers[0] == 2 && numbers[1] == 21
    }
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
