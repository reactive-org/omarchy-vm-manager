import Darwin
import Foundation

final class TransportWorkspace {
    let root: URL
    private let fd: Int32
    private let inode: ino_t
    private var hashes: [String: String] = [:]
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dev-vm-job-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0 else {
            if fd >= 0 { close(fd) }
            try? FileManager.default.removeItem(at: root)
            throw SequencingFailure.adapterFailed
        }
        inode = info.st_ino
        for path in ["home", "tmp", "plugins", "collections"] { try directory(path) }
    }
    deinit {
        close(fd)
        var info = stat()
        // This is our own ephemeral UUID directory, never VM storage. Refuse
        // cleanup if its identity/ownership has changed under a trusted task.
        if lstat(root.path, &info) == 0, info.st_ino == inode, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR {
            try? FileManager.default.removeItem(at: root)
        }
    }
    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    func directory(_ path: String) throws {
        let parent = try parentFD(path + "/placeholder"); close(parent)
    }
    private func parentFD(_ path: String, create: Bool = true) throws -> Int32 {
        try relativePath(path)
        var current = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw SequencingFailure.adapterFailed }
        do {
            for part in path.split(separator: "/").dropLast() {
                if create, mkdirat(current, String(part), 0o700) != 0, errno != EEXIST { throw SequencingFailure.adapterFailed }
                let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw SequencingFailure.adapterFailed }
                close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }
    func write(_ path: String, _ data: Data, mode: mode_t = 0o600) throws {
        let parent = try parentFD(path); defer { close(parent) }
        let file = openat(parent, URL(fileURLWithPath: path).lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard file >= 0 else { throw SequencingFailure.adapterFailed }
        defer { close(file) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw SequencingFailure.adapterFailed }; offset += n
            }
        }
        guard fsync(file) == 0, fchmod(file, mode) == 0 else { throw SequencingFailure.adapterFailed }
        hashes[path] = digest(data)
    }
    func verify() throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_ino == inode, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700
        else { throw SequencingFailure.sourceChanged }
        for (path, hash) in hashes {
            let parent = try parentFD(path, create: false); defer { close(parent) }
            let file = openat(parent, URL(fileURLWithPath: path).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { throw SequencingFailure.sourceChanged }
            defer { close(file) }
            var s = stat()
            guard fstat(file, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_size <= SourceSnapshot.maximumBytes
            else { throw SequencingFailure.sourceChanged }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
            let data = try handle.read(upToCount: SourceSnapshot.maximumBytes + 1) ?? Data()
            guard digest(data) == hash else { throw SequencingFailure.sourceChanged }
        }
    }
    func resources() throws {
        _ = try SetupPlanner.engine()
        guard let base = Bundle.module.url(forResource: "Provisioning", withExtension: nil, subdirectory: "Resources") else { throw SequencingFailure.adapterFailed }
        let inventory = try PlainDataParser.read(base.appendingPathComponent("inventory.json")).object!
        for name in inventory.keys.sorted() {
            try relativePath(name)
            let data = try Data(contentsOf: base.appendingPathComponent(name))
            guard inventory[name] == .string(digest(data)) else { throw SequencingFailure.sourceChanged }
            try write("kit/" + name, data)
        }
    }
}

enum AnsibleVariables {
    static func connection(_ connection: ProvisioningSSHConnection, tools: ProvisioningTransportTools,
                           workspace: TransportWorkspace, remoteRoot: String, setup: Bool) throws -> [String: ManifestValue] {
        let ssh = try tools.ssh.verify().path, scp = try tools.scp.verify().path, sftp = try tools.sftp.verify().path
        var values: [String: ManifestValue] = [
            "ansible_host": .string(connection.alias), "ansible_user": .string(connection.binding.owner),
            "ansible_port": .integer(Int64(connection.port)), "ansible_connection": .string("ssh"),
            "ansible_ssh_executable": .string(ssh), "ansible_scp_executable": .string(scp), "ansible_sftp_executable": .string(sftp),
            "ansible_ssh_args": .string("-C -o ControlMaster=no -o ControlPersist=no -o StrictHostKeyChecking=yes -o BatchMode=yes"),
            "ansible_ssh_common_args": .string(shellJoin(["-F", workspace.url("ssh_config").path])),
            "ansible_ssh_extra_args": .string(""), "ansible_scp_extra_args": .string(""), "ansible_sftp_extra_args": .string(""),
            "ansible_host_key_checking": .bool(true), "ansible_ssh_host_key_checking": .bool(true),
            "ansible_private_key_file": .string(""), "ansible_ssh_private_key_file": .string(""),
            "ansible_python_interpreter": .string("/usr/bin/python3"),
            "ansible_shell_executable": .string(remoteRoot + "/managed-shell"), "ansible_remote_tmp": .string(remoteRoot + "/ansible-tmp")]
        if !setup { values["ansible_become"] = .bool(false) }
        return values
    }
    static func features(_ plan: SetupPlan, workspace: TransportWorkspace, check: Bool) throws -> [String: ManifestValue] {
        let resolved = plan.document.object!["features"]!.object!, names = resolved["features"]!.array!.map { $0.string! }
        let definitions = try SelectionSchema.resource("catalogue").object!["features"]!.object!
        var configs = resolved["options"]!.object!
        if var workstation = configs["workstation"]?.object, let layout = workstation["layout"]?.string, !layout.isEmpty {
            workstation["layout"] = .string(workspace.url("repository/" + layout).path); configs["workstation"] = .object(workstation)
        }
        let fields: [String: (String, String)] = [
            "browsers": ("omarchy_browsers", "browsers"), "languages": ("omarchy_languages", "tools"),
            "agents": ("omarchy_agents", "tools"), "credentials": ("omarchy_credential_packages", "packages")]
        let workstationFields = ["shell": "omarchy_shell", "oh_my_zsh": "omarchy_oh_my_zsh", "starship": "omarchy_starship",
            "oh_my_zsh_plugins": "omarchy_oh_my_zsh_plugins", "oh_my_zsh_update_mode": "omarchy_oh_my_zsh_update_mode",
            "starship_config": "omarchy_starship_config", "font_size": "omarchy_foot_font_size", "idle_mode": "omarchy_idle_mode",
            "theme": "omarchy_theme", "layout": "omarchy_layout_file", "remove_layout": "omarchy_remove_layout"]
        var result: [String: ManifestValue] = ["omarchy_features": resolved["features"]!]
        var extensions: [ManifestValue] = [], effective: [ManifestValue] = []
        for name in names {
            let config = configs[name]!, ext = definitions[name] == nil
            effective.append(.object(["feature": .string(name), "config": config, "extension": .bool(ext)]))
            if ext { extensions.append(.object(["name": .string(name), "config": config])) }
            else if let (variable, field) = fields[name] { result[variable] = config.object![field]! }
            else if name == "workstation" { for (field, variable) in workstationFields { result[variable] = config.object![field]! } }
            else { result["omarchy_" + name] = config }
        }
        result["omarchy_extensions"] = .array(extensions); result["omarchy_resolved_plan"] = .array(effective)
        result["omarchy_defer_docker_access"] = .bool(!check && configs["docker"]?.object?["access"] == .string("sudoless"))
        return result
    }
    static func repository(_ command: GuestCommand, workspace: TransportWorkspace) throws -> [String: ManifestValue] {
        guard let plan = command.plan else { throw SequencingFailure.invalidRequest }
        var files = plan.document.object!["dotfiles"]!.array!
        files = files.map { value in
            var item = value.object!; item["source"] = .string(workspace.url("repository/" + item["source"]!.string!).path); return .object(item)
        }
        let tasks = plan.document.object!["tasks"]!.array!.filter { command.tasks.contains($0.object!["name"]!.string!) }.map { value -> ManifestValue in
            var item = value.object!; item["file"] = .string(workspace.url("repository/" + item["file"]!.string!).path); return .object(item)
        }
        guard let bytes = plan.snapshot.data(for: plan.manifestPath) else { throw SequencingFailure.invalidRequest }
        let manifest = try PlainDataParser.parse(bytes, format: sourceFormat(plan.manifestPath)).object!
        return ["omarchy_setup_id": plan.document.object!["id"]!, "omarchy_setup_files": .array(files), "omarchy_setup_tasks": .array(tasks),
            "omarchy_setup_dir": .string(workspace.url("repository").path), "omarchy_setup_vars": manifest["vars"] ?? .object([:]),
            "omarchy_setup_conflict": .string(command.conflictPolicy.rawValue),
            "omarchy_setup_record": .object(["id": plan.document.object!["id"]!, "engine": plan.document.object!["engine"]!,
                "inputs": plan.document.object!["inputs"]!, "tasks": .array(command.tasks.map(ManifestValue.string)),
                "features": plan.document.object!["features"]!, "vm": plan.document.object!["vm"]!])]
    }
}
