import Darwin
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private final class ProvisioningFakeFiles: ProvisioningToolFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: ProvisioningExecutable] = [:]
    func executable(_ path: String) -> ProvisioningExecutable? { lock.withLock { entries[path] } }
    func put(_ path: String, line: String? = nil, fingerprint: String = "original") {
        lock.withLock { entries[path] = .init(identity: .init(path: path, fingerprint: fingerprint), firstLine: line) }
    }
}

private actor ProvisioningFakeProbes: ProvisioningToolProbing {
    private(set) var requests: [ProvisioningProbeRequest] = []
    let response: @Sendable (ProvisioningProbeRequest) -> ProvisioningProbeResult
    init(_ response: @escaping @Sendable (ProvisioningProbeRequest) -> ProvisioningProbeResult) { self.response = response }
    func run(_ request: ProvisioningProbeRequest) -> ProvisioningProbeResult { requests.append(request); return response(request) }
}

private struct ProvisioningHarness {
    let files = ProvisioningFakeFiles()
    let bin: String
    let python: String
    init(bin: String = "/opt/homebrew/bin", python: String? = nil, ansible: Bool = true, shebang: String? = nil) {
        self.bin = bin; self.python = python ?? bin + "/python3"
        for path in ["/bin/bash", "/usr/bin/ssh", "/usr/bin/scp", "/usr/bin/sftp", bin + "/brew", bin + "/gh", self.python] { files.put(path) }
        if ansible {
            files.put(bin + "/ansible-playbook", line: shebang ?? "#!" + self.python)
            files.put(bin + "/ansible-inventory", line: shebang ?? "#!" + self.python)
        }
    }
    func probes(pythonVersion: [Int] = [3, 14, 10], yaml: String? = "6.0.3", core: String? = "2.21.5",
                dependencies: Bool = true, launcherCore: String = "2.21.5") -> ProvisioningFakeProbes {
        let python = self.python, bin = self.bin
        return ProvisioningFakeProbes { request in
            let name = URL(fileURLWithPath: request.executable.path).lastPathComponent
            let output: String
            switch name {
            case "brew": output = request.arguments == ["--prefix"] ? String(bin.dropLast(4)) + "\n" : "Homebrew 5.0.0\n"
            case "bash": output = "GNU bash, version 3.2.57(1)-release\n"
            case "ssh": output = "OpenSSH_10.0p2, LibreSSL\n"
            case "gh": output = "gh version 2.82.0 (date)\n"
            case "ansible-playbook", "ansible-inventory": output = name + " [core " + launcherCore + "]\n"
            default:
                // Ansible's CLI imports reject a non-UTF-8 controller locale.
                guard request.environment["LC_ALL"] == "en_US.UTF-8" else { return .init(status: 1) }
                let data = try! JSONSerialization.data(withJSONObject: ["python": pythonVersion, "releaselevel": "final", "executable": python,
                    "yaml": yaml as Any? ?? NSNull(), "ansible": core as Any? ?? NSNull(), "dependencies": dependencies])
                return .init(output: data)
            }
            return .init(output: Data(output.utf8))
        }
    }
    func provider(_ probes: ProvisioningFakeProbes, overrides: [ProvisioningTool: String] = [:], homebrew: [String]? = nil,
                  path: [String] = []) -> HomebrewProvisioningDependencies {
        .init(configuration: .init(overrides: overrides, searchDirectories: path, homebrewDirectories: homebrew ?? [bin]), files: files, probes: probes)
    }
}

@Suite("Provisioning host tool discovery and feature gates")
struct ProvisioningToolsTests {
    @Test("GUI discovery ignores an empty PATH and exposes prerequisites without enabling unimplemented execution")
    func guiDiscovery() async throws {
        let fixture = ProvisioningHarness(), probes = fixture.probes()
        let report = try await fixture.provider(probes).inspect()
        #expect(report.tool(.python)?.version == "3.14.10")
        #expect(report.tool(.ansiblePlaybook)?.status == .available)
        #expect(report.features.first { $0.capability == .developerFeatures }?.toolsReady == true)
        #expect(report.features.allSatisfy { !$0.enabled && !$0.implemented })
        #expect(report.tool(.gh)?.status == .needsAuthentication)
        #expect(report.features.first { $0.capability == .githubStarThemes }?.toolsReady == false)
        let requests = await probes.requests
        #expect(!requests.contains { $0.arguments.contains("install") || $0.arguments.contains("auth") || $0.arguments.contains("info") })
        #expect(!requests.contains { ["scp", "sftp", "git", "docker"].contains(URL(fileURLWithPath: $0.executable.path).lastPathComponent) })
        for request in requests {
            #expect(request.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
            #expect(request.environment["GH_TOKEN"] == nil && request.environment["GITHUB_TOKEN"] == nil && request.environment["SSH_AUTH_SOCK"] == nil)
            #expect(request.environment["PYTHONPATH"] == nil && request.environment["DYLD_INSERT_LIBRARIES"] == nil)
            #expect(request.environment["HOME"] == request.workingDirectory)
            #expect(!FileManager.default.fileExists(atPath: request.workingDirectory))
        }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
        let features = object["features"] as! [[String: Any]]
        #expect(features.allSatisfy { $0["enabled"] as? Bool == false })
        #expect((object["tools"] as! [[String: Any]]).contains { $0["installCommand"] as? String == "brew install ansible" })
    }

    @Test("Homebrew prefix, controlled PATH fallback and explicit overrides support paths containing spaces")
    func discoveryPaths() async throws {
        let fixture = ProvisioningHarness(bin: "/custom prefix/bin"), probes = fixture.probes()
        fixture.files.put("/known/brew")
        let report = try await fixture.provider(probes, overrides: [.brew: "/known/brew"], homebrew: [], path: []).inspect()
        #expect(report.tool(.python)?.executable?.path == "/custom prefix/bin/python3")
        #expect(report.tool(.brew)?.provider == "override")
        let fallback = try await fixture.provider(probes, homebrew: [], path: [fixture.bin]).inspect()
        #expect(fallback.tool(.python)?.status == .available)
    }

    @Test("explicit invalid overrides never fall back to a discovered tool")
    func missingOverride() async throws {
        let fixture = ProvisioningHarness(), probes = fixture.probes()
        let report = try await fixture.provider(probes, overrides: [.python: "/missing/python3"]).inspect()
        #expect(report.tool(.python)?.status == .checkFailed)
        #expect(report.tool(.ansiblePlaybook)?.status == .incompatible)
        #expect(report.features.first { $0.capability == .jsonPlanning }?.toolsReady == false)
    }

    @Test("missing dependencies disable only their dependent capabilities")
    func partialInstallation() async throws {
        let fixture = ProvisioningHarness(ansible: false), probes = fixture.probes(yaml: nil, core: nil)
        let report = try await fixture.provider(probes).inspect()
        #expect(report.features.first { $0.capability == .jsonPlanning }?.toolsReady == true)
        #expect(report.features.first { $0.capability == .basicProvisioning }?.toolsReady == true)
        #expect(report.features.first { $0.capability == .yamlPlanning }?.toolsReady == false)
        #expect(report.tool(.ansibleInventory)?.status == .missing)
        #expect(report.features.first { $0.capability == .imageBuilding }?.toolsReady == false)
    }

    @Test("unsupported Python and prerelease or new Ansible lines fail closed", arguments: ["old-python", "future-python", "old-core", "future-core", "prerelease", "missing-dependency"])
    func compatibility(_ scenario: String) async throws {
        let fixture = ProvisioningHarness()
        let version = scenario == "old-python" ? [3, 10, 12] : scenario == "future-python" ? [3, 15, 0] : [3, 14, 10]
        let core = scenario == "old-core" ? "2.20.9" : scenario == "future-core" ? "2.22.0" : scenario == "prerelease" ? "2.21.5rc1" : "2.21.5"
        let report = try await fixture.provider(fixture.probes(pythonVersion: version, core: core, dependencies: scenario != "missing-dependency")).inspect()
        #expect(report.tool(.ansiblePlaybook)?.status == .incompatible)
        #expect(report.features.first { $0.capability == .developerFeatures }?.toolsReady == false)
    }

    @Test("basic Python 3.11 remains usable while Ansible requires Python 3.12 or newer")
    func python311() async throws {
        let fixture = ProvisioningHarness()
        let report = try await fixture.provider(fixture.probes(pythonVersion: [3, 11, 9])).inspect()
        #expect(report.tool(.python)?.status == .available)
        #expect(report.tool(.ansiblePlaybook)?.status == .incompatible)
    }

    @Test("supported Python boundary versions and the PyYAML major gate are explicit", arguments: [11, 12, 13, 14])
    func versionBoundaries(_ minor: Int) async throws {
        let fixture = ProvisioningHarness()
        let report = try await fixture.provider(fixture.probes(pythonVersion: [3, minor, 0])).inspect()
        #expect(report.tool(.python)?.status == .available)
        #expect(report.tool(.ansibleInventory)?.status == (minor >= 12 ? .available : .incompatible))
        let wrongYaml = try await fixture.provider(fixture.probes(pythonVersion: [3, minor, 0], yaml: "5.4.1")).inspect()
        #expect(wrongYaml.tool(.yaml)?.status == .incompatible)
        #expect(wrongYaml.features.first { $0.capability == .developerFeatures }?.toolsReady == false)
    }

    @Test("Apple's Python stub is never executed even with an explicit override")
    func applePython() async throws {
        let fixture = ProvisioningHarness(), probes = fixture.probes()
        fixture.files.put("/usr/bin/python3")
        let report = try await fixture.provider(probes, overrides: [.python: "/usr/bin/python3"]).inspect()
        #expect(report.tool(.python)?.status == .incompatible)
        #expect(!(await probes.requests).contains { $0.executable.path == "/usr/bin/python3" })
        let env = ProvisioningHarness(shebang: "#!/usr/bin/env python3"), envProbes = env.probes()
        env.files.put("/usr/bin/python3")
        let first = try await env.provider(envProbes, overrides: [.brew: "/missing/brew"], homebrew: [], path: ["/usr/bin", env.bin]).inspect()
        #expect(first.tool(.python)?.status == .incompatible)
        #expect(!(await envProbes.requests).contains { $0.executable.path == "/usr/bin/python3" })
    }

    @Test("use the Ansible virtualenv entry path rather than resolving away pyvenv.cfg")
    func coherentEnvironment() async throws {
        let fixture = ProvisioningHarness(python: "/opt/homebrew/Cellar/ansible/libexec/bin/python3")
        fixture.files.put(fixture.bin + "/python3", fingerprint: "different-python")
        let probes = fixture.probes()
        let report = try await fixture.provider(probes).inspect()
        #expect(report.tool(.python)?.executable?.path == fixture.python)
        #expect(report.tool(.yaml)?.interpreter?.path == fixture.python)
        #expect(report.tool(.ansibleInventory)?.status == .available)
        let mismatched = try await fixture.provider(probes, overrides: [.python: fixture.bin + "/python3"]).inspect()
        #expect(mismatched.tool(.ansiblePlaybook)?.status == .incompatible)
    }

    @Test("ambiguous launchers and different inventory interpreters are refused")
    func launchers() async throws {
        for line in ["#!/bin/sh", "#!/usr/bin/env -S python3 -I", "#!/usr/bin/python3 -s"] {
            let fixture = ProvisioningHarness(shebang: line)
            let report = try await fixture.provider(fixture.probes()).inspect()
            #expect(report.tool(.ansiblePlaybook)?.status == .incompatible)
        }
        let fixture = ProvisioningHarness(shebang: "#!/usr/bin/env python3")
        let env = try await fixture.provider(fixture.probes()).inspect()
        #expect(env.tool(.ansiblePlaybook)?.status == .available)
        fixture.files.put("/other/python3")
        fixture.files.put(fixture.bin + "/ansible-inventory", line: "#!/other/python3")
        let mismatch = try await fixture.provider(fixture.probes()).inspect()
        #expect(mismatch.tool(.ansibleInventory)?.status == .incompatible)
    }

    @Test("different launcher version or malformed runtime output is not readiness")
    func malformedReports() async throws {
        let fixture = ProvisioningHarness()
        let report = try await fixture.provider(fixture.probes(launcherCore: "2.21.4")).inspect()
        #expect(report.tool(.ansiblePlaybook)?.status == .incompatible)
        let malformed = try await fixture.provider(ProvisioningFakeProbes { _ in .init(output: Data("synthetic-secret-output".utf8)) }).inspect()
        #expect(malformed.tool(.python)?.status == .checkFailed)
        let json = String(decoding: try JSONEncoder().encode(malformed), as: UTF8.self)
        #expect(!json.contains("synthetic-secret-output"))
    }

    @Test("timeout and output failures are bounded categories without raw output", arguments: [ProvisioningProbeResult.Failure.timeout, .outputLimit, .launch])
    func probeFailure(_ failure: ProvisioningProbeResult.Failure) async throws {
        let fixture = ProvisioningHarness()
        let report = try await fixture.provider(ProvisioningFakeProbes { _ in .failed(failure) }).inspect()
        #expect(report.tool(.python)?.status == .checkFailed)
        #expect(report.tool(.python)?.reason.contains(failure.rawValue) == true)
    }

    @Test("an executable replaced during a probe invalidates the report")
    func replacement() async throws {
        let fixture = ProvisioningHarness(), files = fixture.files, python = fixture.python
        let probes = ProvisioningFakeProbes { request in
            if request.executable.path == python { files.put(python, fingerprint: "upgraded") }
            return .init(output: Data("Homebrew 5.0.0\n".utf8))
        }
        let report = try await fixture.provider(probes).inspect()
        #expect(report.tool(.python)?.status == .checkFailed)
        #expect(report.tool(.python)?.reason.contains("changed") == true)
    }

    @Test("local tools command accepts only bounded absolute overrides and leaves legacy parsing alone")
    func commandParsing() throws {
        #expect(try ProvisioningToolsInvocation.parse(["list"]) == nil)
        let invocation = try #require(try ProvisioningToolsInvocation.parse(["setup", "tools", "--tool", "python=/custom path/python3"]))
        #expect(invocation.overrides[.python] == "/custom path/python3")
        for arguments in [["setup"], ["setup", "apply"], ["setup", "tools", "--install"],
                          ["setup", "tools", "--tool", "python=relative"], ["setup", "tools", "--tool", "ssh=/bin/other"],
                          ["setup", "tools", "--tool", "python=/one", "--tool", "python=/two"]] {
            #expect(throws: VMFailure.self) { try ProvisioningToolsInvocation.parse(arguments) }
        }
        let config = ProvisioningToolConfiguration(searchDirectories: [".", "relative", "/good", "/bad\n", "/parent/../escape"])
        #expect(config.searchDirectories == ["/good"])
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
    @Test("real fixture streams merge, stdin is closed and the inherited environment is absent")
    func processIO() async throws {
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        let executable = try script("printf 'out'; printf 'err' >&2; read input && exit 9; test -z \"$SSH_AUTH_SOCK\"\n", fixture: fixture)
        let result = await LocalProvisioningToolProbe().run(request(executable, fixture: fixture))
        #expect(result.failure == nil && result.status == 0)
        #expect(String(decoding: result.output, as: UTF8.self) == "outerr")
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
    @Test("Python virtualenv symlink entry remains the execution path")
    func symlinkEntry() throws {
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        let target = try script("exit 0\n", fixture: fixture)
        let link = fixture.support.appendingPathComponent("python3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: target.path))
        let entry = try #require(LocalProvisioningToolFiles().executable(link.path))
        #expect(entry.identity.path == link.path)
    }
}
