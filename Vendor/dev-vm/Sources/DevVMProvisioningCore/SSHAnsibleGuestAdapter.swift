import Foundation

/// Concrete command construction, materialization and result interpretation.
/// Launch requires an explicitly injected runner; CLI execution stays disabled.
public actor SSHAnsibleGuestAdapter: ProvisioningGuestAdapter {
    private let connection: ProvisioningSSHConnection
    private let tools: ProvisioningTransportTools
    private let authority: any ProvisioningSessionAuthority
    private let runner: any ProvisioningProcessRunner
    private let workspace: TransportWorkspace
    private let helper: Data
    private var context: GuestJobContext?
    private var active: (command: UUID, invocation: UUID)?
    private var runningCommand: GuestCommand?
    private var interruptedCommandID: UUID?
    private var busy = false
    private var seen = Set<UUID>()
    private var staged = false
    private var stageAttempted = false

    public init(connection: ProvisioningSSHConnection, tools: ProvisioningTransportTools,
                authority: any ProvisioningSessionAuthority, runner: any ProvisioningProcessRunner) throws {
        self.connection = connection; self.tools = tools; self.authority = authority; self.runner = runner
        workspace = try TransportWorkspace()
        try workspace.resources()
        helper = try Data(contentsOf: workspace.url("kit/omarchy/guest/provisioning-job.py"))
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let config = """
        Host \(connection.alias)
         HostName 127.0.0.1
         Port \(connection.port)
         User \(connection.binding.owner)
         IdentityFile \(quoted(connection.identity.url.path))
         UserKnownHostsFile \(quoted(workspace.url("known_hosts").path))
         GlobalKnownHostsFile /dev/null
         HostKeyAlias \(connection.alias)
         HostKeyAlgorithms ssh-ed25519
         StrictHostKeyChecking yes
         CheckHostIP no
         UpdateHostKeys no
         IdentitiesOnly yes
         IdentityAgent none
         ForwardAgent no
         ForwardX11 no
         ClearAllForwardings yes
         ProxyCommand none
         ProxyJump none
         PermitLocalCommand no
         CanonicalizeHostname no
         ControlMaster no
         ControlPersist no
         ControlPath none
         PasswordAuthentication no
         KbdInteractiveAuthentication no
         BatchMode yes
         EscapeChar none
         ConnectTimeout 3
         ConnectionAttempts 1
        """
        try workspace.write("ssh_config", Data((config + "\n").utf8))
        try workspace.write("known_hosts", Data((connection.alias + " ssh-ed25519 " + connection.hostKey.base64EncodedString() + "\n").utf8))
        let ansible = "[defaults]\ninject_facts_as_vars=false\nretry_files_enabled=false\nroles_path=kit/roles\nlocal_tmp=tmp\n[ssh_connection]\nssh_args=-o ControlMaster=no -o ControlPersist=no -o ControlPath=none\npipelining=false\n"
        try workspace.write("ansible.cfg", Data(ansible.utf8))
    }

    public func perform(_ command: GuestCommand) async throws -> GuestReply {
        guard !busy, seen.count < 512, seen.insert(command.id).inserted else { throw SequencingFailure.alreadyUsed }
        guard command.context.target == connection.binding, command.mode == command.context.mode else { throw SequencingFailure.identityMismatch }
        if let context { guard context == command.context else { throw SequencingFailure.identityMismatch } }
        else { context = command.context }
        if command.mode == .check, [.resetGrant, .clearAuthenticationCache, .requestPersistentGrant, .verifyGrantActive,
                                    .installManifestPackages, .configureDockerOwnerAccess, .revokeGrant, .verifyGrantInactive].contains(command.operation) {
            throw SequencingFailure.invalidRequest
        }
        if command.plan == nil, ![.verifyIdentity, .quiesceOwnedWork, .revokeGrant, .clearAuthenticationCache,
                                 .verifyGrantInactive, .removePayload, .verifyOwnerDockerAccess].contains(command.operation) {
            throw SequencingFailure.invalidRequest
        }
        guard !command.operation.interactive || command.inputLeaseID != nil else { throw SequencingFailure.authorizationRequired }
        busy = true; runningCommand = command
        defer { busy = false; runningCommand = nil; interruptedCommandID = nil }
        do {
            try await admit(command)
            switch command.operation {
            case .verifyIdentity:
                let result = try await ssh(command, purpose: .identity, argv: ["/usr/bin/python3", "-I", "-c", Self.identityScript])
                let object = try controlObject(result.stdout)
                guard Set(object.keys) == ["uid", "owner", "system", "architecture"],
                      object["uid"] == .integer(Int64(connection.binding.ownerUID)), object["owner"] == .string(connection.binding.owner),
                      object["system"] == .string("Linux"), object["architecture"] == .string("aarch64") else { throw SequencingFailure.identityMismatch }
            case .stagePayload: try await stage(command)
            case .configureFeatures: try await ansible(command, setup: false)
            case .configureRepository: try await ansible(command, setup: true)
            case .installManifestPackages: try await packages(command)
            case .quiesceOwnedWork, .removePayload:
                let action = command.operation == .quiesceOwnedWork ? "quiesce" : "remove"
                let result = try await control(command, purpose: action == "quiesce" ? .quiesce : .remove, action: action)
                try receipt(result.stdout, command: command, state: action == "quiesce" ? "quiescent" : "absent")
            default:
                guard let invocation = command.operation.nativeInvocation else { throw SequencingFailure.invalidRequest }
                let cleanup = command.plan == nil
                guard cleanup || staged else { throw SequencingFailure.invalidRequest }
                let result = try await control(command, purpose: .native, action: cleanup ? "cleanup-run" : "run",
                                      arguments: invocation.arguments, streaming: invocation.requiresInteractiveTerminal,
                                      interactive: invocation.requiresInteractiveTerminal)
                if command.operation == .verifyOwnerDockerAccess, result.stdout.isEmpty { throw SequencingFailure.adapterFailed }
            }
            try checkpoint(command)
            return GuestReply(commandID: command.id, jobID: command.context.jobID, target: connection.binding,
                              dependencyDigest: command.context.dependencyDigest, proof: command.operation.expectedProof)
        } catch let failure as SequencingFailure { throw failure }
        catch is CancellationError { throw SequencingFailure.cancelled }
        catch { throw SequencingFailure.adapterFailed }
    }
    public func interrupt(commandID: UUID, context: GuestJobContext) async {
        guard self.context == context, runningCommand?.id == commandID, runningCommand?.plan != nil else { return }
        interruptedCommandID = commandID
        if let active, active.command == commandID { await runner.interrupt(invocationID: active.invocation) }
    }
    private func checkpoint(_ command: GuestCommand) throws {
        if command.plan != nil, Task.isCancelled || interruptedCommandID == command.id { throw SequencingFailure.cancelled }
    }
    private var remoteRoot: String { "/tmp/dev-vm-provisioning-" + context!.payloadID.uuidString.lowercased() }
    private func admit(_ command: GuestCommand) async throws {
        try await authority.revalidate(command.context.target, dependencyDigest: command.context.dependencyDigest)
        try connection.identity.verify(); try tools.verify(); try workspace.verify()
    }
    private func environment() -> [String: String] {
        ["PATH": tools.playbook.target.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin",
         "HOME": workspace.url("home").path, "TMPDIR": workspace.url("tmp").path,
         "TERM": "xterm-256color",
         "LANG": "en_US.UTF-8", "LC_CTYPE": "en_US.UTF-8", "ANSIBLE_CONFIG": workspace.url("ansible.cfg").path,
         "ANSIBLE_LOCAL_TEMP": workspace.url("tmp").path, "ANSIBLE_COLLECTIONS_PATH": workspace.url("collections").path,
         "ANSIBLE_LIBRARY": workspace.url("plugins").path, "ANSIBLE_CALLBACK_PLUGINS": workspace.url("plugins").path,
         "ANSIBLE_STDOUT_CALLBACK": "default", "ANSIBLE_LOAD_CALLBACK_PLUGINS": "False",
         "ANSIBLE_HOST_KEY_CHECKING": "True", "ANSIBLE_FORCE_COLOR": "1"]
    }
    private func run(_ command: GuestCommand, purpose: ProvisioningProcessPurpose, executable: ProvisioningExecutablePin,
                     arguments: [String], input: ProvisioningProcessInput = .closed,
                     output: ProvisioningProcessOutput = .boundedCapture, accepted: Set<Int32> = [0]) async throws -> ProvisioningProcessResult {
        try checkpoint(command)
        try await admit(command)
        try checkpoint(command)
        let invocation = ProvisioningProcessInvocation(id: UUID(), commandID: command.id, context: command.context,
            purpose: purpose, executable: try executable.verify(), arguments: arguments, environment: environment(),
            workingDirectory: workspace.root, input: input, output: output, timeoutSeconds: command.timeoutSeconds)
        active = (command.id, invocation.id)
        defer { if active?.invocation == invocation.id { active = nil } }
        let result = await runner.run(invocation)
        guard result.invocationID == invocation.id, result.stdout.count + result.stderr.count <= invocation.maximumCapturedBytes else { throw SequencingFailure.protocolViolation }
        if case .terminalStream = output, !result.stdout.isEmpty || !result.stderr.isEmpty { throw SequencingFailure.protocolViolation }
        switch result.termination {
        case .notStarted, .cleanupUnconfirmed: throw SequencingFailure.adapterFailed
        case .exited(let status, let reason):
            switch reason {
            case .cancelled: throw SequencingFailure.cancelled
            case .timedOut: throw SequencingFailure.timedOut
            case .outputLimit, .ioFailure: throw SequencingFailure.adapterFailed
            case .normal: guard accepted.contains(status) else { throw SequencingFailure.adapterFailed }
            }
        }
        return result
    }
    private func ssh(_ command: GuestCommand, purpose: ProvisioningProcessPurpose, argv: [String],
                     input: ProvisioningProcessInput = .closed, streaming: Bool = false, interactive: Bool = false,
                     accepted: Set<Int32> = [0]) async throws -> ProvisioningProcessResult {
        let stdin: ProvisioningProcessInput
        if interactive { guard let lease = command.inputLeaseID else { throw SequencingFailure.authorizationRequired }; stdin = .terminalLease(lease) }
        else { stdin = input }
        return try await run(command, purpose: purpose, executable: tools.ssh,
            arguments: ["-F", workspace.url("ssh_config").path, interactive ? "-tt" : "-T", connection.alias, shellJoin(argv)],
            input: stdin, output: streaming ? .terminalStream : .boundedCapture, accepted: accepted)
    }
    private func control(_ command: GuestCommand, purpose: ProvisioningProcessPurpose, action: String,
                         arguments: [String] = [], streaming: Bool = false, interactive: Bool = false,
                         accepted: Set<Int32> = [0]) async throws -> ProvisioningProcessResult {
        var args = arguments
        if args.first == "bash" { args[0] = "/bin/bash" }
        return try await ssh(command, purpose: purpose, argv: ["/usr/bin/python3", "-I", "-c", Self.helperVerifier,
            remoteRoot + "/control.py", digest(helper), command.context.jobID.uuidString.lowercased(),
            command.context.payloadID.uuidString.lowercased(), action] + args,
            streaming: streaming, interactive: interactive, accepted: accepted)
    }
    private func stage(_ command: GuestCommand) async throws {
        guard !stageAttempted, let plan = command.plan else { throw SequencingFailure.invalidRequest }
        stageAttempted = true // A lost reply must never lead to an automatic second stage.
        for (path, file) in plan.snapshot.files { try workspace.write("repository/" + path, file.data, mode: mode_t(file.mode)) }
        for path in plan.snapshot.directories.keys { try workspace.directory("repository/" + path) }
        try workspace.directory("repository")
        let wrapper = "#!/bin/bash\nexec " + shellJoin(["/usr/bin/python3", "-I", "-c", Self.helperVerifier, remoteRoot + "/control.py", digest(helper),
            command.context.jobID.uuidString.lowercased(), command.context.payloadID.uuidString.lowercased(), "shell"]) + " \"$@\"\n"
        let bootstrap: ManifestValue = .object(["protocol": .integer(1), "job": .string(command.context.jobID.uuidString.lowercased()),
            "payload": .string(command.context.payloadID.uuidString.lowercased()), "uid": .integer(Int64(connection.binding.ownerUID)),
            "helper": .string(helper.base64EncodedString()), "wrapper": .string(Data(wrapper.utf8).base64EncodedString())])
        let result = try await ssh(command, purpose: .bootstrap, argv: ["/usr/bin/python3", "-I", "-c", Self.bootstrapScript], input: .bytes(try canonicalData(bootstrap)))
        try receipt(result.stdout, command: command, state: "staged")
        _ = try await run(command, purpose: .copyPayload, executable: tools.scp,
            arguments: ["-S", try tools.ssh.verify().path, "-F", workspace.url("ssh_config").path, "-p", "-r", workspace.url("kit").path,
                        workspace.url("repository").path, connection.alias + ":" + remoteRoot + "/data/"])
        let ready = try await control(command, purpose: .preparePayload, action: "prepare")
        try receipt(ready.stdout, command: command, state: "ready")
        staged = true
    }
    private func ansible(_ command: GuestCommand, setup: Bool) async throws {
        guard staged, let plan = command.plan else { throw SequencingFailure.invalidRequest }
        let prefix = command.id.uuidString.lowercased()
        let fixed = try AnsibleVariables.connection(connection, tools: tools, workspace: workspace, remoteRoot: remoteRoot, setup: setup)
        let host: ManifestValue = .object(["all": .object(["children": .object(["omarchy": .object(["hosts": .object(["workstation": .object(fixed)])])])])])
        let variables = try setup ? AnsibleVariables.repository(command, workspace: workspace) : AnsibleVariables.features(plan, workspace: workspace, check: command.mode == .check)
        try workspace.write(prefix + "-inventory.json", canonicalData(host))
        try workspace.write(prefix + "-vars.json", canonicalData(ManifestValue.object(variables)))
        try workspace.write(prefix + "-connection.json", canonicalData(ManifestValue.object(fixed)))
        let tags = setup ? ["dotfiles", "setup-record"] + command.tasks.map { "setup." + $0 } : plan.document.object!["features"]!.object!["features"]!.array!.map { $0.string! }
        var args = ["-i", workspace.url(prefix + "-inventory.json").path, workspace.url(setup ? "kit/setup.yml" : "kit/site.yml").path,
                    "--tags", tags.joined(separator: ","), "--extra-vars", "@" + workspace.url(prefix + "-vars.json").path,
                    "--extra-vars", "@" + workspace.url(prefix + "-connection.json").path]
        if command.mode == .check { args.append("--check") }
        _ = try await run(command, purpose: setup ? .repository : .features, executable: tools.playbook,
                          arguments: args, output: .terminalStream)
    }
    private func controlObject(_ data: Data) throws -> [String: ManifestValue] {
        do { guard let object = try PlainDataParser.parse(data, format: .json).object else { throw SequencingFailure.protocolViolation }; return object }
        catch { throw SequencingFailure.protocolViolation }
    }
    private func packages(_ command: GuestCommand) async throws {
        guard staged, command.mode == .apply, let values = command.plan?.document.object?["vm"]?.object?["packages"]?.array else { throw SequencingFailure.invalidRequest }
        var selected: [(String, String)] = []
        func succeeded(_ script: String) async throws -> Bool {
            let result = try await control(command, purpose: .packages, action: "run", arguments: ["bash", "-lc", script], accepted: [0, 1])
            if case .exited(let status, _) = result.termination { return status == 0 }; return false
        }
        for value in values {
            guard let raw = value.string else { throw SequencingFailure.invalidRequest }
            let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let split = item.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(split.last!)
            guard matches(name, "[A-Za-z0-9][A-Za-z0-9._+@/-]*") else { throw SequencingFailure.invalidRequest }
            let source: String
            if split.count == 2 { source = String(split[0]); guard ["pkg", "mise"].contains(source) else { throw SequencingFailure.invalidRequest } }
            else {
                source = try await succeeded("if command -v mise >/dev/null 2>&1; then " + shellJoin(["mise", "ls", "--json", name]) + " >/dev/null 2>&1; else exit 1; fi") ? "mise" : "pkg"
            }
            selected.append((source, name))
        }
        let nativePackages = Set(selected.filter { $0.0 == "pkg" }.map { $0.1 })
        var handled = Set<String>()
        func install(_ argv: [String]) async throws {
            _ = try await control(command, purpose: .packages, action: "run", arguments: ["bash", "-lc", shellJoin(argv)], streaming: true, interactive: true)
        }
        for browser in ["chromium", "firefox"] where nativePackages.contains(browser) {
            if try await !succeeded(shellJoin(["pacman", "-Qq", "--", browser])) { try await install(["omarchy", "install", "browser", browser]) }
            handled.insert(browser)
        }
        if nativePackages.contains("claude-desktop") {
            if try await !succeeded(shellJoin(["pacman", "-Qq", "--", "claude-desktop"])) { try await install(["omarchy", "install", "ai", "claude"]) }
            handled.insert("claude-desktop")
        }
        if Set(["1password", "1password-cli"]).isSubset(of: nativePackages) {
            let desktop = try await succeeded(shellJoin(["pacman", "-Qq", "--", "1password"]))
            let cli = try await succeeded(shellJoin(["pacman", "-Qq", "--", "1password-cli"]))
            if !desktop || !cli { try await install(["omarchy", "install", "service", "1password"]) }
            handled.formUnion(["1password", "1password-cli"])
        }
        for (source, name) in selected {
            if source == "pkg", !handled.contains(name) {
                if try await !succeeded(shellJoin(["pacman", "-Qq", "--", name])) { try await install(["omarchy-pkg-add", name]) }
            } else if source == "mise" {
                if try await !succeeded(shellJoin(["mise", "where", name]) + " >/dev/null 2>&1") { try await install(["mise", "install", name]) }
            }
        }
        if let plan = command.plan, plan.document.object?["vm"]?.object?["lean_developer"] == .bool(true) {
            let keep = LeanDeveloperPolicy.keep(vmPackages: values.compactMap(\.string), features: plan.document.object!["features"]!)
            let arguments = ["/usr/bin/python3", "-I", remoteRoot + "/data/kit/omarchy/guest/apply-lean-developer.py"]
                + keep.flatMap { ["--keep", $0] }
            _ = try await control(command, purpose: .packages, action: "run", arguments: ["bash", "-lc", shellJoin(arguments)], streaming: true, interactive: true)
        }
    }
    private func receipt(_ data: Data, command: GuestCommand, state: String) throws {
        let object = try controlObject(data)
        guard object == ["protocol": .integer(1), "job": .string(command.context.jobID.uuidString.lowercased()),
                         "payload": .string(command.context.payloadID.uuidString.lowercased()),
                         "uid": .integer(Int64(connection.binding.ownerUID)), "state": .string(state)] else { throw SequencingFailure.protocolViolation }
    }
    static let identityScript = "import os,pwd,platform,json; print(json.dumps({'uid':os.getuid(),'owner':pwd.getpwuid(os.getuid()).pw_name,'system':platform.system(),'architecture':platform.machine()}))"
    static let helperVerifier = """
    import os,sys,stat,hashlib
    def require(v):
      if not v: sys.exit(1)
    p=sys.argv[1]; f=os.open(p,os.O_RDONLY|os.O_NOFOLLOW); s=os.fstat(f)
    require(stat.S_ISREG(s.st_mode) and s.st_uid==os.getuid() and s.st_size<=65536)
    data=os.read(f,65537); os.close(f); require(hashlib.sha256(data).hexdigest()==sys.argv[2])
    os.execv('/usr/bin/python3',['python3','-I',p]+sys.argv[3:])
    """
    static let bootstrapScript = """
    import os,sys,stat,json,uuid,platform,base64
    def require(v):
      if not v: sys.exit(1)
    data=sys.stdin.buffer.read(65537); require(len(data)<=65536)
    v=json.loads(data); require(set(v)=={'protocol','job','payload','uid','helper','wrapper'})
    require(v['protocol']==1 and os.getuid()==v['uid']!=0 and platform.system()=='Linux' and platform.machine()=='aarch64')
    job=str(uuid.UUID(v['job'])); payload=str(uuid.UUID(v['payload'])); root='/tmp/dev-vm-provisioning-'+payload
    os.mkdir(root,0o700)
    f=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    lease={'protocol':1,'job':job,'payload':payload,'uid':os.getuid()}
    for name,content,mode in [('lease.json',json.dumps(lease).encode(),0o600),('control.py',base64.b64decode(v['helper'],validate=True),0o600),('managed-shell',base64.b64decode(v['wrapper'],validate=True),0o700)]:
      fd=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,mode,dir_fd=f)
      with os.fdopen(fd,'wb') as stream: stream.write(content)
    for name in ['data','tmp','ansible-tmp']: os.mkdir(name,0o700,dir_fd=f)
    os.close(f); print(json.dumps(dict(lease,state='staged')))
    """
}
