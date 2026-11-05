import Darwin
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private final class ProvisioningFakeFiles: ProvisioningToolFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: ProvisioningExecutable] = [:]
    private var directories: [String: ProvisioningInstallation] = [:]
    private var queriedPaths: [String] = []
    var queries: [String] { lock.withLock { queriedPaths } }
    func executable(_ path: String) -> ProvisioningExecutable? { lock.withLock { queriedPaths.append(path); return entries[path] } }
    func directory(_ path: String) -> ProvisioningInstallation? { lock.withLock { queriedPaths.append(path); return directories[path] } }
    func put(_ path: String, resolved: String? = nil, fingerprint: String = "original") {
        lock.withLock { entries[path] = .init(identity: .init(path: path, fingerprint: fingerprint), resolvedPath: resolved ?? path) }
    }
    func putDirectory(_ path: String, resolved: String? = nil, fingerprint: String = "original") {
        lock.withLock { directories[path] = .init(identity: .init(path: path, fingerprint: fingerprint), resolvedPath: resolved ?? path) }
    }
    func remove(_ path: String) { lock.withLock { entries[path] = nil } }
}

private actor ProvisioningFakeProbes: ProvisioningToolProbing {
    private(set) var requests: [ProvisioningProbeRequest] = []
    let response: @Sendable (ProvisioningProbeRequest) -> ProvisioningProbeResult
    init(_ response: @escaping @Sendable (ProvisioningProbeRequest) -> ProvisioningProbeResult) { self.response = response }
    func run(_ request: ProvisioningProbeRequest) -> ProvisioningProbeResult { requests.append(request); return response(request) }
}

private struct ProvisioningHarness: Sendable {
    let files = ProvisioningFakeFiles()
    let root: String
    var bin: String { root + "/bin" }
    var prefix: String { root + "/opt/ansible" }
    var keg: String { root + "/Cellar/ansible/14.5.0" }
    static let inventoryJSON = #"{"_meta":{"hostvars":{"fixture.invalid":{"ansible_local":{}}},"profile":"inventory_legacy"},"all":{"children":["ungrouped","provisioning_probe"]},"provisioning_probe":{"hosts":["fixture.invalid"]}}"#
    init(root: String = "/opt/homebrew", installed: Bool = true) {
        self.root = root
        for path in ["/bin/bash", "/usr/bin/ssh", "/usr/bin/scp", "/usr/bin/sftp", root + "/bin/brew", root + "/bin/gh"] { files.put(path) }
        if installed {
            files.putDirectory(prefix, resolved: keg)
            for name in ["ansible-playbook", "ansible-inventory"] {
                files.put(prefix + "/bin/" + name, resolved: keg + "/bin/" + name)
                files.put(bin + "/" + name, resolved: keg + "/bin/" + name)
            }
        }
    }
    func response(core: String = "2.21.5", inventoryCore: String? = nil) -> @Sendable (ProvisioningProbeRequest) -> ProvisioningProbeResult {
        { request in
            let name = URL(fileURLWithPath: request.executable.path).lastPathComponent
            let output: String
            switch name {
            case "brew":
                if request.arguments == ["--prefix"] { output = root + "\n" }
                else if request.arguments == ["--prefix", "--installed", "ansible"] { output = prefix + "\n" }
                else if request.arguments == ["--version"] { output = "Homebrew 7.0.11\n" }
                else { return .init(status: 99) }
            case "bash": output = "GNU bash, version 3.2.57(1)-release\n"
            case "ssh": return .init(standardError: Data("OpenSSH_10.3p1, LibreSSL\n".utf8))
            case "gh": output = "gh version 2.103.3\n"
            case "ansible-playbook", "ansible-inventory":
                guard request.environment["LC_ALL"] == "en_US.UTF-8" else { return .init(status: 1) }
                if request.arguments == ["--version"] {
                    output = name + " [core " + (name == "ansible-inventory" ? inventoryCore ?? core : core) + "]\n  python version = 3.99.0 (Homebrew-managed diagnostic only)\n"
                } else if name == "ansible-inventory", request.arguments.count == 3, request.arguments[0] == "-i", request.arguments[2] == "--list" {
                    output = Self.inventoryJSON
                } else if name == "ansible-playbook", request.arguments.count == 4, request.arguments[0] == "--syntax-check", request.arguments[1] == "-i" {
                    output = "\nplaybook: " + request.arguments[3] + "\n"
                } else { return .init(status: 99) }
            default: return .init(status: 99)
            }
            return .init(output: Data(output.utf8))
        }
    }
    func provider(_ probes: ProvisioningFakeProbes, overrides: [ProvisioningTool: String] = [:], homebrew: [String]? = nil,
                  path: [String] = []) -> HomebrewProvisioningDependencies {
        .init(configuration: .init(overrides: overrides, searchDirectories: path, homebrewDirectories: homebrew ?? [bin]), files: files, probes: probes)
    }
}

@Suite("Provisioning Homebrew Ansible CLI checks and schema 2 gates")
struct ProvisioningToolsTests {
    @Test("GUI discovery checks the coherent Ansible pair without finding or invoking Python")
    func guiDiscovery() async throws {
        let fixture = ProvisioningHarness(), probes = ProvisioningFakeProbes(ProvisioningHarness().response())
        let report = try await fixture.provider(probes).inspect()
        #expect(report.schemaVersion == 2 && report.tools.count == 8)
        #expect(report.tool(.ansiblePlaybook)?.status == .available)
        #expect(report.tool(.ansiblePlaybook)?.version == "2.21.5")
        #expect(report.tool(.ansibleInventory)?.installation?.path == fixture.prefix)
        #expect(report.features.first { $0.capability == .developerFeatures }?.toolsReady == true)
        #expect(report.features.allSatisfy { !$0.enabled && !$0.implemented })
        #expect(report.tool(.gh)?.status == .needsAuthentication)
        #expect(!fixture.files.queries.contains { $0.contains("python") || $0.contains("yaml") })
        let requests = await probes.requests
        let names = requests.map { URL(fileURLWithPath: $0.executable.path).lastPathComponent }
        #expect(Set(names).isSubset(of: ["brew", "bash", "ssh", "gh", "ansible-playbook", "ansible-inventory"]))
        #expect(!requests.contains { $0.arguments.contains("install") || $0.arguments.contains("auth") || $0.arguments.contains("-c") })
        #expect(requests.contains { $0.arguments.contains("--syntax-check") })
        for request in requests {
            #expect(request.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
            #expect(request.environment["GH_TOKEN"] == nil && request.environment["GITHUB_TOKEN"] == nil && request.environment["SSH_AUTH_SOCK"] == nil)
            #expect(request.environment["PYTHONPATH"] == nil && request.environment["DYLD_INSERT_LIBRARIES"] == nil)
            #expect(request.environment["HOME"] == request.workingDirectory)
            #expect(!FileManager.default.fileExists(atPath: request.workingDirectory))
        }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
        let tools = object["tools"] as! [[String: Any]]
        #expect(tools.allSatisfy { $0["interpreter"] == nil && !["python", "yaml"].contains($0["tool"] as? String ?? "") })
        #expect((object["features"] as! [[String: Any]]).allSatisfy { $0["enabled"] as? Bool == false })
    }

    @Test("data planning has no external blockers when every tool is absent but remains unimplemented")
    func noExternalTools() async throws {
        let files = ProvisioningFakeFiles(), probes = ProvisioningFakeProbes { _ in .init(status: 99) }
        let report = try await HomebrewProvisioningDependencies(configuration: .init(homebrewDirectories: []), files: files, probes: probes).inspect()
        for capability in [ProvisioningCapability.jsonPlanning, .yamlPlanning] {
            let gate = try #require(report.features.first { $0.capability == capability })
            #expect(gate.toolsReady && gate.blockers.isEmpty && !gate.enabled && !gate.implemented)
        }
        #expect(report.features.first { $0.capability == .developerFeatures }?.toolsReady == false)
        #expect((await probes.requests).isEmpty)
    }

    @Test("prefix discovery, PATH fallback and explicit aliases support paths containing spaces")
    func discoveryPaths() async throws {
        let fixture = ProvisioningHarness(root: "/custom brew"), probes = ProvisioningFakeProbes(ProvisioningHarness(root: "/custom brew").response())
        fixture.files.put("/known/brew")
        fixture.files.put("/chosen alias/ansible-playbook", resolved: fixture.keg + "/bin/ansible-playbook")
        let report = try await fixture.provider(probes, overrides: [.brew: "/known/brew", .ansiblePlaybook: "/chosen alias/ansible-playbook"], homebrew: []).inspect()
        #expect(report.tool(.ansiblePlaybook)?.status == .available)
        #expect(report.tool(.ansiblePlaybook)?.provider == "override")
        let fallback = try await fixture.provider(probes, homebrew: [], path: [fixture.bin]).inspect()
        #expect(fallback.tool(.ansibleInventory)?.status == .available)
    }

    @Test("missing Homebrew or an uninstalled formula never falls back to unrelated PATH commands", arguments: ["brew", "formula"])
    func missingInstallation(_ scenario: String) async throws {
        let fixture = ProvisioningHarness(), normal = fixture.response()
        let probes = ProvisioningFakeProbes { request in
            if scenario == "formula", request.arguments == ["--prefix", "--installed", "ansible"] { return .init(status: 1) }
            return normal(request)
        }
        let report = try await fixture.provider(probes, overrides: scenario == "brew" ? [.brew: "/missing/brew"] : [:]).inspect()
        #expect(report.tool(.ansiblePlaybook)?.status != .available)
        #expect(!(await probes.requests).contains { $0.executable.path.contains("ansible-") })
        #expect(report.features.first { $0.capability == .basicProvisioning }?.toolsReady == true)
        #expect(report.features.first { $0.capability == .yamlPlanning }?.toolsReady == true)
    }

    @Test("invalid formula prefixes and absent directory metadata fail closed", arguments: ["relative", "newline", "missing", "timeout"])
    func invalidPrefix(_ scenario: String) async throws {
        let fixture = ProvisioningHarness(), normal = fixture.response()
        let probes = ProvisioningFakeProbes { request in
            if request.arguments == ["--prefix", "--installed", "ansible"] {
                if scenario == "timeout" { return .failed(.timeout) }
                return .init(output: Data((scenario == "relative" ? "relative" : scenario == "newline" ? "/one\n/two\n" : "/absent/prefix").utf8))
            }
            return normal(request)
        }
        let report = try await fixture.provider(probes).inspect()
        #expect(report.tool(.ansibleInventory)?.status == .checkFailed)
        #expect(!(await probes.requests).contains { $0.executable.path.contains("ansible-") })
    }

    @Test("wrong installation targets and invalid explicit overrides are never executed", arguments: ["outside", "mixed", "missing"])
    func wrongCommand(_ scenario: String) async throws {
        let fixture = ProvisioningHarness(), probes = ProvisioningFakeProbes(ProvisioningHarness().response())
        let path = "/other/bin/ansible-inventory"
        if scenario != "missing" { fixture.files.put(path, resolved: scenario == "mixed" ? fixture.root + "/Cellar/ansible/other/bin/ansible-inventory" : "/outside/bin/ansible-inventory") }
        let report = try await fixture.provider(probes, overrides: [.ansibleInventory: path]).inspect()
        #expect(report.tool(.ansibleInventory)?.status == (scenario == "missing" ? .checkFailed : .incompatible))
        #expect(report.tool(.ansiblePlaybook)?.status == .incompatible)
        #expect(!(await probes.requests).contains { $0.executable.path == path || $0.arguments.contains("--list") })
    }

    @Test("missing companion and version mismatches block pair readiness", arguments: ["missing", "mismatch", "old", "future", "prerelease"])
    func versionPolicy(_ scenario: String) async throws {
        let fixture = ProvisioningHarness()
        if scenario == "missing" { fixture.files.remove(fixture.prefix + "/bin/ansible-inventory") }
        let core = scenario == "old" ? "2.20.9" : scenario == "future" ? "2.22.0" : scenario == "prerelease" ? "2.21.5rc1" : "2.21.5"
        let probes = ProvisioningFakeProbes(fixture.response(core: core, inventoryCore: scenario == "mismatch" ? "2.21.4" : nil))
        let report = try await fixture.provider(probes).inspect()
        #expect(report.tool(.ansiblePlaybook)?.status == .incompatible)
        #expect(report.tool(.ansibleInventory)?.status == (scenario == "missing" ? .missing : .incompatible))
        #expect(!(await probes.requests).contains { $0.arguments.contains("--list") || $0.arguments.contains("--syntax-check") })
    }

    @Test("inventory self-check admits only the fixed fixture and never runs syntax after failure", arguments: ["exit", "json", "host", "vars", "facts", "timeout", "limit"])
    func inventoryFailures(_ scenario: String) async throws {
        let fixture = ProvisioningHarness(), normal = fixture.response()
        let probes = ProvisioningFakeProbes { request in
            if request.arguments.contains("--list") {
                if scenario == "exit" { return .init(status: 1, output: Data("synthetic-secret".utf8)) }
                if scenario == "timeout" { return .failed(.timeout) }
                if scenario == "limit" { return .failed(.outputLimit) }
                if scenario == "vars" { return .init(output: Data(ProvisioningHarness.inventoryJSON.replacingOccurrences(of: #""ansible_local":{}"#, with: #""unexpected":true"#).utf8)) }
                if scenario == "facts" { return .init(output: Data(ProvisioningHarness.inventoryJSON.replacingOccurrences(of: #""ansible_local":{}"#, with: #""ansible_local":{"unexpected":true}"#).utf8)) }
                return .init(output: Data((scenario == "json" ? "synthetic-secret" : ProvisioningHarness.inventoryJSON.replacingOccurrences(of: "fixture.invalid", with: "unexpected.invalid")).utf8))
            }
            return normal(request)
        }
        let report = try await fixture.provider(probes).inspect()
        #expect(report.tool(.ansibleInventory)?.status == .checkFailed && report.tool(.ansiblePlaybook)?.status == .checkFailed)
        #expect(!(await probes.requests).contains { $0.arguments.contains("--syntax-check") })
        #expect(!String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("synthetic-secret"))
    }

    @Test("syntax self-check failure and surprising success output do not count as readiness", arguments: ["exit", "output", "timeout"])
    func syntaxFailures(_ scenario: String) async throws {
        let fixture = ProvisioningHarness(), normal = fixture.response()
        let probes = ProvisioningFakeProbes { request in
            if request.arguments.contains("--syntax-check") {
                if scenario == "timeout" { return .failed(.timeout) }
                return .init(status: scenario == "exit" ? 1 : 0, output: Data("synthetic-secret".utf8))
            }
            return normal(request)
        }
        let report = try await fixture.provider(probes).inspect()
        #expect(report.tool(.ansiblePlaybook)?.status == .checkFailed && report.tool(.ansibleInventory)?.status == .checkFailed)
        #expect(!String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("synthetic-secret"))
    }

    @Test("only fixed private inventory/config/playbook inputs are used for the local checks")
    func fixedFixtures() async throws {
        let fixture = ProvisioningHarness(), normal = fixture.response()
        let probes = ProvisioningFakeProbes { request in
            if request.arguments.contains("--list") || request.arguments.contains("--syntax-check") {
                let root = URL(fileURLWithPath: request.workingDirectory)
                let inventory = root.appendingPathComponent("inventory.ini")
                #expect(request.arguments[request.arguments.firstIndex(of: "-i")! + 1] == inventory.path)
                #expect(try! String(contentsOf: inventory, encoding: .utf8) == "[provisioning_probe]\nfixture.invalid\n")
                let playbook = try! String(contentsOf: root.appendingPathComponent("syntax.yml"), encoding: .utf8)
                #expect(playbook.contains("gather_facts: false") && playbook.contains("ansible.builtin.debug:"))
                #expect(!playbook.contains("lookup(") && !playbook.contains("shell:") && !playbook.contains("command:"))
                for name in ["inventory.ini", "syntax.yml", "ansible.cfg"] {
                    let attributes = try! FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)
                    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
                }
            }
            return normal(request)
        }
        let report = try await fixture.provider(probes).inspect()
        #expect(report.tool(.ansiblePlaybook)?.status == .available)
    }

    @Test("successful prefix and inventory stdout remains usable when stderr contains a warning")
    func separateDiagnostics() async throws {
        let fixture = ProvisioningHarness(), normal = fixture.response()
        let probes = ProvisioningFakeProbes { request in
            var result = normal(request)
            result.standardError += Data("synthetic-diagnostic-canary".utf8)
            return result
        }
        let report = try await fixture.provider(probes).inspect()
        #expect(report.tool(.ansiblePlaybook)?.status == .available)
        #expect(!String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("synthetic-diagnostic-canary"))
    }

    @Test("upgrades to either command, Homebrew or its active keg invalidate the whole pair", arguments: ["command", "brew", "keg"])
    func replacedAfterChecks(_ scenario: String) async throws {
        let fixture = ProvisioningHarness(), normal = fixture.response()
        let probes = ProvisioningFakeProbes { request in
            if request.executable.path.hasSuffix("/gh") {
                if scenario == "keg" { fixture.files.putDirectory(fixture.prefix, resolved: fixture.keg + "-new", fingerprint: "changed") }
                else if scenario == "brew" { fixture.files.put(fixture.bin + "/brew", fingerprint: "changed") }
                else { fixture.files.put(fixture.prefix + "/bin/ansible-playbook", resolved: fixture.keg + "/bin/ansible-playbook", fingerprint: "changed") }
            }
            return normal(request)
        }
        let report = try await fixture.provider(probes).inspect()
        #expect(report.tool(.ansiblePlaybook)?.status == .checkFailed && report.tool(.ansibleInventory)?.status == .checkFailed)
    }

    @Test("schema 2 command rejects retired Python/PyYAML overrides with migration guidance")
    func commandParsing() throws {
        #expect(try ProvisioningToolsInvocation.parse(["list"]) == nil)
        let invocation = try #require(try ProvisioningToolsInvocation.parse(["setup", "tools", "--tool", "ansible-playbook=/custom path/ansible-playbook"]))
        #expect(invocation.overrides[.ansiblePlaybook] == "/custom path/ansible-playbook")
        for key in ["python", "python3", "yaml", "pyyaml"] {
            do { _ = try ProvisioningToolsInvocation.parse(["setup", "tools", "--tool", key + "=/some/path"]); Issue.record("Retired override accepted") }
            catch let error as VMFailure { #expect(error.code == "retired-tool-override" && error.message.contains("schema 2")) }
        }
        for arguments in [["setup"], ["setup", "apply"], ["setup", "preview", UUID().uuidString], ["setup", "capabilities"]] {
            #expect(try ProvisioningToolsInvocation.parse(arguments) == nil)
        }
        for arguments in [["setup", "tools", "--install"],
                          ["setup", "tools", "--tool", "brew=relative"], ["setup", "tools", "--tool", "ssh=/bin/other"],
                          ["setup", "tools", "--tool", "brew=/one", "--tool", "brew=/two"]] {
            #expect(throws: VMFailure.self) { try ProvisioningToolsInvocation.parse(arguments) }
        }
        #expect(ProvisioningToolConfiguration(searchDirectories: [".", "relative", "/good", "/bad\n", "/parent/../escape"]).searchDirectories == ["/good"])
    }
}

@Suite("Provisioning bounded local process probes")
struct ProvisioningProcessTests {
    private func script(_ source: String, fixture: RegistryFixture) throws -> ProvisioningToolIdentity {
        let path = fixture.support.appendingPathComponent("fake tool")
        try Data(("#!/bin/bash\n" + source).utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return try #require(LocalProvisioningToolFiles().executable(path.path)?.identity)
    }
    private func request(_ executable: ProvisioningToolIdentity, fixture: RegistryFixture, timeout: TimeInterval = 1,
                         limit: Int = 32768) -> ProvisioningProbeRequest {
        .init(executable: executable, arguments: [], environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.support.path],
              workingDirectory: fixture.support.path, timeout: timeout, outputLimit: limit)
    }
    @Test("real fixture streams stay separate, stdin is closed and the inherited environment is absent")
    func processIO() async throws {
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        let executable = try script("printf 'out'; printf 'err' >&2; read input && exit 9; test -z \"$SSH_AUTH_SOCK\"\n", fixture: fixture)
        let result = await LocalProvisioningToolProbe().run(request(executable, fixture: fixture))
        #expect(result.failure == nil && result.status == 0)
        #expect(String(decoding: result.output, as: UTF8.self) == "out")
        #expect(String(decoding: result.standardError, as: UTF8.self) == "err")
    }
    @Test("a hanging tool and a flooding tool stop within bounds")
    func bounds() async throws {
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        let hanging = try script("trap '' TERM; /bin/sleep 30 & wait\n", fixture: fixture)
        let start = ContinuousClock.now
        let timeout = await LocalProvisioningToolProbe().run(request(hanging, fixture: fixture, timeout: 0.15))
        #expect(timeout.failure == .timeout)
        #expect(start.duration(to: .now) < .seconds(3))
        let noisy = try script("while :; do printf '012345678901234567890123456789'; done\n", fixture: fixture)
        let limited = await LocalProvisioningToolProbe().run(request(noisy, fixture: fixture, limit: 128))
        #expect(limited.failure == .outputLimit && limited.output.isEmpty)
        let errorNoisy = try script("while :; do printf '012345678901234567890123456789' >&2; done\n", fixture: fixture)
        let errorLimit = await LocalProvisioningToolProbe().run(request(errorNoisy, fixture: fixture, limit: 128))
        #expect(errorLimit.failure == .outputLimit && errorLimit.standardError.isEmpty)
    }

    @Test("real shell wrappers pass the full Homebrew CLI contract without a Python probe")
    func localWrapperInstallation() async throws {
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        let root = fixture.support.appendingPathComponent("brew fixture"), bin = root.appendingPathComponent("bin")
        let prefix = root.appendingPathComponent("opt/ansible"), ansibleBin = prefix.appendingPathComponent("bin")
        for directory in [bin, ansibleBin] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func save(_ directory: URL, _ name: String, _ source: String) throws {
            let path = directory.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + source).utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        try save(bin, "brew", """
        case "$*" in
          --version) printf 'Homebrew 7.0.11\\n' ;;
          --prefix) printf '%s\\n' \(quote(root.path)) ;;
          '--prefix --installed ansible') printf '%s\\n' \(quote(prefix.path)); printf 'fixture warning\\n' >&2 ;;
          *) exit 99 ;;
        esac
        """)
        try save(ansibleBin, "ansible-inventory", """
        if [ "$*" = '--version' ]; then printf 'ansible-inventory [core 2.21.5]\\n'; exit 0; fi
        test "$#" = 3 && test "$1" = '-i' && test "$3" = '--list' || exit 99
        printf '%s\\n' \(quote(ProvisioningHarness.inventoryJSON))
        """)
        try save(ansibleBin, "ansible-playbook", """
        if [ "$*" = '--version' ]; then printf 'ansible-playbook [core 2.21.5]\\n'; exit 0; fi
        test "$#" = 4 && test "$1" = '--syntax-check' && test "$2" = '-i' || exit 99
        printf 'playbook: %s\\n' "$4"
        """)
        let report = try await HomebrewProvisioningDependencies(configuration: .init(overrides: [.gh: "/missing/gh"], homebrewDirectories: [bin.path])).inspect()
        #expect(report.schemaVersion == 2)
        #expect(report.tool(.ansiblePlaybook)?.status == .available)
        #expect(report.tool(.ansibleInventory)?.status == .available)
        #expect(report.features.allSatisfy { !$0.enabled })
    }
    @Test("replacement and cancellation prevent stale or lingering probe results")
    func changedAndCancelled() async throws {
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        let stale = try script("exit 0\n", fixture: fixture)
        let current = try script("/bin/sleep 30\n", fixture: fixture)
        let changed = await LocalProvisioningToolProbe().run(request(stale, fixture: fixture))
        #expect(changed.failure == .changed)
        let probe = request(current, fixture: fixture, timeout: 5)
        let task = Task { await LocalProvisioningToolProbe().run(probe) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        #expect(await task.value.failure == .cancelled)
    }
    @Test("Homebrew wrapper alias preserves the invocation path and canonical target")
    func symlinkEntry() throws {
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        let target = try script("exit 0\n", fixture: fixture)
        let link = fixture.support.appendingPathComponent("ansible-playbook")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: target.path))
        let entry = try #require(LocalProvisioningToolFiles().executable(link.path))
        #expect(entry.identity.path == link.path)
        #expect(entry.resolvedPath == URL(fileURLWithPath: target.path).resolvingSymlinksInPath().path)
    }
}
