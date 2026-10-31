import Darwin
import Foundation

public struct GuestHibernationCapability: Codable, Equatable, Sendable {
    public enum KernelSupport: String, Codable, Sendable { case supported, unsupported, unknown }
    public let kernel: String
    public let kernelSupport: KernelSupport
    public let diskStateAvailable: Bool
    public let persistentSwap: Bool
    public let resumeConfigured: Bool
    public let nonInteractivePermission: Bool
    public init(kernel: String, kernelSupport: KernelSupport, diskStateAvailable: Bool, persistentSwap: Bool, resumeConfigured: Bool, nonInteractivePermission: Bool) {
        self.kernel = kernel; self.kernelSupport = kernelSupport; self.diskStateAvailable = diskStateAvailable
        self.persistentSwap = persistentSwap; self.resumeConfigured = resumeConfigured; self.nonInteractivePermission = nonInteractivePermission
    }
    public var canAttempt: Bool { kernelSupport == .supported && diskStateAvailable && persistentSwap && resumeConfigured && nonInteractivePermission }
    public var label: String {
        switch kernelSupport {
        case .unsupported: "Kernel lacks hibernation"
        case .unknown: "Kernel support unknown"
        case .supported: canAttempt ? "Ready for experimental attempt" : "Kernel supports hibernation"
        }
    }
    public var detail: String {
        if kernelSupport == .unsupported { return "The running kernel does not provide suspend-to-disk." }
        if kernelSupport == .unknown { return "The running kernel’s hibernation support could not be determined." }
        if !diskStateAvailable { return "Hibernation is disabled by the guest’s current security or boot policy." }
        if !persistentSwap { return "Configure persistent disk swap inside the guest; zram cannot hold a saved session." }
        if !resumeConfigured { return "Configure the guest’s resume device and boot/initramfs recovery before attempting suspension." }
        if !nonInteractivePermission { return "A guest administrator must allow non-interactive logind hibernation for this account. The manager does not grant privileges." }
        return "Experimental: saving or restoring may fail. Kernel support does not prove session restoration works."
    }
}

public struct GuestSuspendProof: Codable, Equatable, Sendable {
    public let token: UUID
    public let bootID: UUID
    public let kernel: String
    public init(token: UUID, bootID: UUID, kernel: String) { self.token = token; self.bootID = bootID; self.kernel = kernel }
}
public enum GuestRestoreResult: Sendable { case restored, coldBoot }
public protocol GuestHibernating: Sendable {
    func capability(_ request: VMStartRequest, user: String) async throws -> GuestHibernationCapability
    func prepare(_ request: VMStartRequest, user: String, token: UUID) async throws -> GuestSuspendProof
    func hibernate(_ request: VMStartRequest, user: String) async throws
    func verifyRestore(_ request: VMStartRequest, user: String, origin: UUID, proof: GuestSuspendProof) async throws -> GuestRestoreResult
}

/// Read-only capability checks and fixed, opt-in guest operations over pinned SSH.
/// No sudo, password prompts, policy installation or arbitrary guest commands.
public struct SSHGuestHibernation: GuestHibernating {
    public init() {}
    static let capabilityProgram = #"""
    import gzip,json,pathlib,subprocess
    identity=json.loads(subprocess.check_output(['/usr/lib/try-omarchy/managed-ssh-identity'],timeout=3))
    kernel=pathlib.Path('/proc/sys/kernel/osrelease').read_text().strip()
    enabled=None
    try:
        with gzip.open('/proc/config.gz','rt') as stream: config=stream.read(1048577)
        if len(config)<=1048576:
            if 'CONFIG_HIBERNATION=y' in config.splitlines(): enabled=True
            elif '# CONFIG_HIBERNATION is not set' in config.splitlines(): enabled=False
    except (OSError,EOFError): pass
    state_path=pathlib.Path('/sys/power/state')
    states=state_path.read_text().split() if state_path.exists() else []
    disk='disk' in states
    support='supported' if disk or enabled is True else 'unsupported' if enabled is False else 'unknown'
    persistent=False
    free_swap=0
    swap_is_file=False
    for line in pathlib.Path('/proc/swaps').read_text().splitlines()[1:]:
        fields=line.split()
        if len(fields)>=5 and not fields[0].startswith('/dev/zram'):
            free_swap+=max(0,int(fields[2])-int(fields[3]))*1024
            swap_is_file=swap_is_file or fields[1]=='file'
    size=pathlib.Path('/sys/power/image_size')
    required=int(size.read_text()) if size.exists() else 0
    persistent=required>0 and free_swap>=required
    device=pathlib.Path('/sys/power/resume')
    cmdline=pathlib.Path('/proc/cmdline').read_text().split()
    resume=device.exists() and device.read_text().strip()!='0:0' and any(p.startswith('resume=') for p in cmdline) and (not swap_is_file or any(p.startswith('resume_offset=') for p in cmdline))
    try:
        permission=subprocess.run(['/usr/bin/busctl','call','org.freedesktop.login1','/org/freedesktop/login1','org.freedesktop.login1.Manager','CanHibernate'],capture_output=True,text=True,timeout=3).stdout.strip()=='s "yes"'
    except subprocess.SubprocessError: permission=False
    print(json.dumps({'identity':identity,'capability':{'kernel':kernel,'kernelSupport':support,'diskStateAvailable':disk,'persistentSwap':persistent,'resumeConfigured':resume,'nonInteractivePermission':permission}},separators=(',',':')))
    """#
    private static let identityProgram = "import json,subprocess; identity=json.loads(subprocess.check_output(['/usr/lib/try-omarchy/managed-ssh-identity'],timeout=3))\n"
    static let markerProgram = #"""
    import os,pathlib,stat,uuid
    runtime=pathlib.Path('/run/user')/str(os.getuid())
    info=runtime.lstat()
    assert stat.S_ISDIR(info.st_mode) and info.st_uid==os.getuid() and info.st_mode&0o077==0
    device=str(os.major(info.st_dev))+':'+str(os.minor(info.st_dev))
    filesystems=[]
    for line in pathlib.Path('/proc/self/mountinfo').read_text().splitlines():
        before,after=line.split(' - ',1)
        if before.split()[2]==device: filesystems.append(after.split()[0])
    assert filesystems and all(fs in ('tmpfs','ramfs') for fs in filesystems)
    marker=runtime/('omarchy-manager-suspend-'+TOKEN+'.json')
    """#
    private func run(_ request: VMStartRequest, user: String, program: String) async throws -> Data {
        guard request.profile.ssh != nil, ManagedSSHProbe.validUser(user) else { throw Self.failure() }
        let storage = ManagedSSHStorage(root: request.storageRoot); try storage.validate(request.profile)
        var args = storage.arguments(profile: request.profile, user: user)
        args[args.count - 1] = "/usr/bin/python3 -c '" + program.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let arguments = args, process = SSHProbeProcess()
        let result = try await withTaskCancellationHandler {
            try await Task.detached { try process.run(arguments: arguments) }.value
        } onCancel: { process.cancel() }
        try Task.checkCancellation()
        guard result.status == 0, !result.hostKeyMismatch else { throw Self.failure() }
        return result.output
    }
    struct Identity: Decodable { let vmID: UUID; let sessionToken: UUID; let user: String; let uid: Int }
    static func valid(_ identity: Identity, request: VMStartRequest, user: String, origin: UUID? = nil) -> Bool {
        identity.vmID == request.profile.id && identity.user == user && (1000..<60000).contains(identity.uid) &&
        (identity.sessionToken == request.sessionID || identity.sessionToken == origin)
    }
    static func decodeCapability(_ data: Data, request: VMStartRequest, user: String) throws -> GuestHibernationCapability {
        struct Report: Decodable { let identity: Identity; let capability: GuestHibernationCapability }
        guard data.count <= 4096, let report = try? JSONDecoder().decode(Report.self, from: data),
              valid(report.identity, request: request, user: user), validKernel(report.capability.kernel),
              !report.capability.diskStateAvailable || report.capability.kernelSupport == .supported else { throw failure() }
        return report.capability
    }
    static func validKernel(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9._+\\-]{1,128}$", options: .regularExpression) != nil }
    public func capability(_ request: VMStartRequest, user: String) async throws -> GuestHibernationCapability {
        try Self.decodeCapability(await run(request, user: user, program: Self.capabilityProgram), request: request, user: user)
    }
    public func prepare(_ request: VMStartRequest, user: String, token: UUID) async throws -> GuestSuspendProof {
        let program = Self.identityProgram + Self.markerProgram.replacingOccurrences(of: "TOKEN", with: "'" + token.uuidString + "'") + #"""

        proof={'token':str(uuid.UUID(TOKEN)), 'bootID':pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip(),'kernel':pathlib.Path('/proc/sys/kernel/osrelease').read_text().strip()}
        fd=os.open(marker,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'w') as stream: json.dump(proof,stream)
        print(json.dumps({'identity':identity,'proof':proof}))
        """#.replacingOccurrences(of: "TOKEN", with: "'" + token.uuidString + "'")
        struct Report: Decodable { let identity: Identity; let proof: GuestSuspendProof }
        let data = try await run(request, user: user, program: program)
        guard let value = try? JSONDecoder().decode(Report.self, from: data), Self.valid(value.identity, request: request, user: user),
              value.proof.token == token, Self.validKernel(value.proof.kernel) else { throw Self.failure() }
        return value.proof
    }
    public func hibernate(_ request: VMStartRequest, user: String) async throws {
        // Recheck identity in the same SSH command that requests the fixed action.
        let program = Self.identityProgram + "assert identity['vmID']=='\(request.profile.id.uuidString)' and identity['sessionToken']=='\(request.sessionID.uuidString)'\n" +
        "r=subprocess.run(['/usr/bin/systemctl','hibernate','--no-ask-password']); assert r.returncode==0; print('{}')\n"
        _ = try await run(request, user: user, program: program)
    }
    public func verifyRestore(_ request: VMStartRequest, user: String, origin: UUID, proof: GuestSuspendProof) async throws -> GuestRestoreResult {
        let program = Self.identityProgram + Self.markerProgram.replacingOccurrences(of: "TOKEN", with: "'" + proof.token.uuidString + "'") + #"""

        boot=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        saved=None
        if marker.exists():
            fd=os.open(marker,os.O_RDONLY|os.O_NOFOLLOW)
            with os.fdopen(fd) as stream: saved=json.loads(stream.read(1025))
        print(json.dumps({'identity':identity,'bootID':boot,'proof':saved}))
        """#
        return try Self.decodeRestore(await run(request, user: user, program: program), request: request, user: user, origin: origin, proof: proof)
    }
    static func decodeRestore(_ data: Data, request: VMStartRequest, user: String, origin: UUID, proof: GuestSuspendProof) throws -> GuestRestoreResult {
        struct Report: Decodable { let identity: Identity; let bootID: UUID; let proof: GuestSuspendProof? }
        guard data.count <= 4096, let value = try? JSONDecoder().decode(Report.self, from: data), valid(value.identity, request: request, user: user, origin: origin) else { throw failure() }
        if value.bootID == proof.bootID && value.proof == proof { return .restored }
        // An old launch nonce is allowed only as evidence of a real memory restore.
        if value.identity.sessionToken == request.sessionID, value.bootID != proof.bootID, value.proof == nil { return .coldBoot }
        throw failure()
    }
    static func failure() -> VMFailure { VMFailure(code: "hibernation-check-failed", message: "The pinned guest hibernation operation could not be verified. Review guest setup and retry; privileges and host-key pins were preserved.") }
}

public struct ExperimentalSuspension: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case requested, restorePending, restoring, recoveryRequired, coldBootDetected }
    let schemaVersion: Int
    let vmID: UUID
    let originSession: UUID
    let user: String
    let proof: GuestSuspendProof
    let profileDigest: String
    let runtimeDigest: String
    let diskIdentity: String
    var diskStamp: String?
    public var stage: Stage
    public var restoreAttempted = false
    public var label: String {
        switch stage {
        case .requested: "Suspending to disk (experimental)"
        case .restorePending: "Suspended · restore not yet verified"
        case .restoring: "Checking memory restoration…"
        case .recoveryRequired: "Experimental suspension needs recovery"
        case .coldBootDetected: "Cold boot detected · session was not restored"
        }
    }
}
struct ExperimentalSuspendStore {
    let root: URL
    private var path: URL { root.appendingPathComponent(".manager-suspension.json") }
    func load(vmID: UUID) throws -> ExperimentalSuspension? {
        guard PrivateFiles.exists(path) else { return nil }
        let value = try JSONDecoder().decode(ExperimentalSuspension.self, from: PrivateFiles.read(path, maximum: 4096))
        guard value.schemaVersion == 1, value.vmID == vmID, ManagedSSHProbe.validUser(value.user), SSHGuestHibernation.validKernel(value.proof.kernel) else { throw SSHGuestHibernation.failure() }
        return value
    }
    func save(_ record: ExperimentalSuspension, exclusively: Bool = false) throws {
        if !exclusively {
            guard let current = try load(vmID: record.vmID), current.originSession == record.originSession, current.proof == record.proof else {
                throw PrivateFiles.failure("Suspension metadata changed; the existing guard was preserved.")
            }
        }
        try PrivateFiles.write(JSONEncoder().encode(record), name: path.lastPathComponent, in: root, exclusively: exclusively)
    }
    func remove(_ record: ExperimentalSuspension) throws {
        guard let current = try load(vmID: record.vmID), current.originSession == record.originSession, current.proof == record.proof else {
            throw PrivateFiles.failure("Cannot clear changed suspension metadata.")
        }
        guard unlink(path.path) == 0 else { throw PrivateFiles.failure("Cannot clear suspension metadata; disk protection is retained.") }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw PrivateFiles.failure("Cannot flush suspension metadata.") }
        defer { close(fd) }; guard fsync(fd) == 0 else { throw PrivateFiles.failure("Cannot flush suspension metadata.") }
    }
    static func digest(_ profile: VMProfile) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; encoder.dateEncodingStrategy = .millisecondsSince1970
        return KitVerifier.sha256(try encoder.encode(profile))
    }
}
