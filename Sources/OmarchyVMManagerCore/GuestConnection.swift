import Darwin
import Foundation

public struct VerifiedGuestConnection: Sendable {
    public let vmID: UUID
    public let sessionID: UUID
    public let user: String
    public let addresses: [String]
    public init(vmID: UUID, sessionID: UUID, user: String, addresses: [String]) {
        self.vmID = vmID; self.sessionID = sessionID; self.user = user; self.addresses = addresses
    }
}
public protocol GuestConnectionChecking: Sendable {
    func check(_ request: VMStartRequest, user: String) async throws -> VerifiedGuestConnection
}
public struct SSHGuestConnectionProbe: GuestConnectionChecking {
    public init() {}
    private static let program = """
    import json,subprocess
    identity=json.loads(subprocess.check_output(['/usr/lib/try-omarchy/managed-ssh-identity'],timeout=3))
    links=json.loads(subprocess.check_output(['/usr/bin/ip','-j','address','show','up','scope','global'],timeout=3))
    addresses=sorted({a['local'] for link in links for a in link.get('addr_info',[]) if a.get('family') in ('inet','inet6') and isinstance(a.get('local'),str)})
    print(json.dumps({'identity':identity,'addresses':addresses[:64]},separators=(',',':')))
    """
    public func check(_ request: VMStartRequest, user: String) async throws -> VerifiedGuestConnection {
        let storage = ManagedSSHStorage(root: request.storageRoot)
        try storage.validate(request.profile)
        guard ManagedSSHProbe.validUser(user) else { throw commandFailure("invalid-ssh-owner", "The guest owner is invalid.") }
        var arguments = storage.arguments(profile: request.profile, user: user)
        arguments[arguments.count - 1] = "/usr/bin/python3 -c '" + Self.program.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let launchArguments = arguments
        let process = SSHProbeProcess()
        let result = try await withTaskCancellationHandler {
            try await Task.detached { try process.run(arguments: launchArguments) }.value
        } onCancel: { process.cancel() }
        try Task.checkCancellation()
        guard result.status == 0, !result.hostKeyMismatch else { throw commandFailure("ssh-connection-unavailable", "The pinned SSH connection could not be verified. The VM was left running.") }
        return try Self.decode(result.output, request: request, user: user)
    }
    static func decode(_ data: Data, request: VMStartRequest, user: String) throws -> VerifiedGuestConnection {
        struct Report: Decodable {
            struct Identity: Decodable { let vmID: UUID; let sessionToken: UUID; let user: String; let uid: Int }
            let identity: Identity; let addresses: [String]
        }
        guard data.count <= 4096, let value = try? JSONDecoder().decode(Report.self, from: data),
              value.identity.vmID == request.profile.id, value.identity.sessionToken == request.sessionID,
              value.identity.user == user, (1000..<60000).contains(value.identity.uid), value.addresses.count <= 64,
              value.addresses.allSatisfy(validAddress) else { throw commandFailure("invalid-connection-report", "The guest returned an invalid or stale connection report.") }
        return VerifiedGuestConnection(vmID: request.profile.id, sessionID: request.sessionID, user: user, addresses: Array(Set(value.addresses)).sorted())
    }
    static func validAddress(_ value: String) -> Bool {
        guard value.utf8.count <= 45, !value.isEmpty else { return false }
        var v4 = in_addr(), v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}
