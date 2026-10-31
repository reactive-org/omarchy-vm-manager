import Darwin
import Foundation

public struct GuestCLIInvocation: Sendable {
    public let request: GuestCommandRequest?
    public let help: Bool
    public static let usage = """
    omarchy-vm <command> [UUID | exact-name] [options]

      factories                    List verified imported factories and official
      factory-import PATH          Import a prepared, reviewed factory bundle
      list                         List guests
      get ID                       Show config, state and SSH/network details
      create NAME [options]        Create a guest with saved owner defaults
      update ID [options]          Change a stopped guest; applies next start
      delete ID                    Move a stopped guest to Trash
      start ID [--wait [ssh|running]]
      pause ID                     Pause and wait for runtime acknowledgement
      resume ID                    Resume and wait for runtime acknowledgement
      stop ID [--force] [--wait]
      restart ID [--wait [ssh|running]]
      wait ID [--for ssh|running|stopped|paused]

    Config: --config FILE.json, --name NAME, --memory 4GiB (or MiB),
            --memory-mib 4096, --cpus 4, --disk 64GiB, --disk-gib 64,
            --clipboard on|off, --immersive on|off
    Creation only: --factory official|MANIFEST_SHA256, --ssh on|off, --owner-defaults on|off, --public-key FILE.pub
    Lifecycle: --start (create), --wait [ssh|running|stopped|paused], --timeout SECONDS

    JSON replies go to stdout. Exit 0: success; 1: failure; 124: wait timeout.
    Wait timeout or closing this CLI leaves the guest in its current state.
    NAT guests may share a guest IP. Connect through ssh.host:ssh.port using
    ssh.command for the managed key and pinned host identity.
    """
    public static func parse(_ arguments: [String]) throws -> Self {
        if arguments.isEmpty || arguments.contains("--help") || arguments == ["help"] || arguments == ["-h"] { return Self(request: nil, help: true) }
        let aliases = ["show": "get", "configure": "update", "shutdown": "stop"]
        guard let command = GuestCommand(rawValue: aliases[arguments[0]] ?? arguments[0]) else { throw commandFailure("usage", "Unknown command. Run omarchy-vm --help.") }
        var config = GuestConfigurationPatch(), selector: String?, positional: String?
        var values: [String: String] = [:], flags: Set<String> = [], index = 1
        let options: Set<String> = ["--config", "--name", "--memory", "--memory-mib", "--cpus", "--disk", "--disk-gib", "--clipboard", "--immersive", "--ssh", "--owner-defaults", "--public-key", "--factory", "--timeout", "--for"]
        while index < arguments.count {
            let key = arguments[index]; index += 1
            if key == "--wait" {
                guard flags.insert(key).inserted else { throw commandFailure("usage", "Duplicate option.") }
                if index < arguments.count, GuestWaitCondition(rawValue: arguments[index]) != nil { values[key] = arguments[index]; index += 1 }
            } else if ["--start", "--force"].contains(key) {
                guard flags.insert(key).inserted else { throw commandFailure("usage", "Duplicate option.") }
            } else if options.contains(key) {
                guard index < arguments.count, !arguments[index].hasPrefix("--"), values[key] == nil else { throw commandFailure("usage", "An option is duplicated or missing its value.") }
                values[key] = arguments[index]; index += 1
            } else if !key.hasPrefix("-"), positional == nil { positional = key }
            else { throw commandFailure("usage", "Unknown option or extra argument. Run omarchy-vm --help.") }
        }
        if let path = values["--config"] { config = try GuestConfigurationPatch.decodeStrict(readFile(path, suffix: nil, maximum: 32768)) }
        if let name = values["--name"] { config.name = name }
        if command == .create {
            guard positional == nil || values["--name"] == nil else { throw commandFailure("usage", "Specify a name once.") }
            if let positional { config.name = positional }
        } else { selector = positional }
        if let memory = values["--memory"] {
            guard values["--memory-mib"] == nil else { throw commandFailure("usage", "Choose --memory or --memory-mib.") }
            config.memoryMiB = try memoryMiB(memory)
        }
        if let value = values["--memory-mib"] { config.memoryMiB = try positiveInteger(value) }
        if let value = values["--cpus"] { config.cpus = try positiveInteger(value) }
        if let disk = values["--disk"] {
            guard values["--disk-gib"] == nil else { throw commandFailure("usage", "Choose --disk or --disk-gib.") }
            config.diskGiB = try diskGiB(disk)
        }
        if let value = values["--disk-gib"] { config.diskGiB = try positiveInteger(value) }
        if let value = values["--clipboard"] { config.clipboard = try boolean(value) }
        if let value = values["--immersive"] { config.immersive = try boolean(value) }
        if let value = values["--factory"] { config.factory = value }
        if command == .importFactory, let path = positional { selector = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path }
        if let value = values["--ssh"] { config.ssh = try boolean(value) }
        if let value = values["--owner-defaults"] { config.ownerDefaults = try boolean(value) }
        if let value = values["--public-key"] { config.publicKey = try SSHPublicKey.canonical(String(decoding: readFile(value, suffix: "pub", maximum: 16384), as: UTF8.self)) }
        let configOptions = Set(values.keys).subtracting(["--timeout", "--for", "--wait"])
        guard configOptions.isEmpty || command == .create || command == .update else { throw commandFailure("usage", "Configuration options apply only to create or update.") }
        var request = GuestCommandRequest(command: command, selector: selector, config: command == .create || command == .update ? config : nil)
        request.start = flags.contains("--start"); request.force = flags.contains("--force")
        request.details = command == .get
        if let timeout = values["--timeout"] { request.timeoutSeconds = try positiveInteger(timeout) }
        guard values["--for"] == nil || command == .wait else { throw commandFailure("usage", "Use --for with wait.") }
        if command == .wait { request.waitFor = try condition(values["--for"] ?? "ssh") }
        if flags.contains("--wait") { request.waitFor = try condition(values["--wait"] ?? (command == .stop ? "stopped" : (command == .create && config.ssh == false ? "running" : "ssh"))) }
        try request.validate()
        return Self(request: request, help: false)
    }
    private static func positiveInteger(_ value: String) throws -> Int {
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let number = Int(value), number > 0 else { throw commandFailure("usage", "Use a positive integer for CPU, memory and timeout values.") }
        return number
    }
    private static func memoryMiB(_ value: String) throws -> Int {
        let text = value.lowercased()
        let suffix = ["gib", "mib"].first { text.hasSuffix($0) }
        let raw = suffix.map { String(text.dropLast($0.count)) } ?? text
        let number = try positiveInteger(raw), multiplier = suffix == "gib" ? 1024 : 1
        let (result, overflow) = number.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { throw commandFailure("usage", "The memory value is too large.") }
        return result
    }
    private static func diskGiB(_ value: String) throws -> Int {
        let text = value.lowercased()
        let raw = text.hasSuffix("gib") ? String(text.dropLast(3)) : text
        guard !raw.hasSuffix("mib") else { throw commandFailure("usage", "Disk capacity is specified in GiB.") }
        return try positiveInteger(raw)
    }
    private static func boolean(_ value: String) throws -> Bool {
        switch value.lowercased() {
        case "on", "true": true
        case "off", "false": false
        default: throw commandFailure("usage", "Use on or off for boolean options.")
        }
    }
    private static func condition(_ value: String) throws -> GuestWaitCondition {
        guard let result = GuestWaitCondition(rawValue: value) else { throw commandFailure("usage", "Wait for ssh, running, paused or stopped.") }
        return result
    }
    private static func readFile(_ path: String, suffix: String?, maximum: Int) throws -> Data {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard suffix == nil || url.pathExtension.lowercased() == suffix else { throw commandFailure("public-key-required", "Choose a .pub file; private keys are never imported.") }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw commandFailure("file-unavailable", "Cannot safely open the selected configuration or public-key file.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximum else { throw commandFailure("invalid-file", "The selected file must be a bounded regular file.") }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw commandFailure("invalid-file", "The selected file exceeds its size limit.") }
        return data
    }
}
