import Foundation

/// Measured result of one Reclaim space request. Allocation is the same
/// clone-aware figure the app shows as "used" for the guest's whole root.
public struct GuestReclaimResult: Codable, Equatable, Sendable {
    public let beforeBytes: Int64
    public let afterBytes: Int64
    public var reclaimedBytes: Int64 { max(0, beforeBytes - afterBytes) }
    public let filesystems: [String]
    public init(beforeBytes: Int64, afterBytes: Int64, filesystems: [String]) {
        self.beforeBytes = beforeBytes; self.afterBytes = afterBytes; self.filesystems = filesystems
    }
    enum CodingKeys: String, CodingKey { case beforeBytes, afterBytes, reclaimedBytes, filesystems }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        beforeBytes = try container.decode(Int64.self, forKey: .beforeBytes)
        afterBytes = try container.decode(Int64.self, forKey: .afterBytes)
        filesystems = try container.decode([String].self, forKey: .filesystems)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(beforeBytes, forKey: .beforeBytes)
        try container.encode(afterBytes, forKey: .afterBytes)
        try container.encode(reclaimedBytes, forKey: .reclaimedBytes)
        try container.encode(filesystems, forKey: .filesystems)
    }
}

public enum GuestReclaimState: Equatable, Sendable {
    case idle, working, completed(GuestReclaimResult), failed(String)
    public var isBusy: Bool { self == .working }
}

public protocol GuestSpaceReclaiming: Sendable {
    /// Trims the running guest's own filesystems. Returns the trimmed
    /// filesystem names ("root", optionally "home"); never measures the host.
    func reclaim(_ request: VMStartRequest, user: String, operationID: UUID) async throws -> [String]
}

public struct SSHGuestReclaim: GuestSpaceReclaiming {
    public init() {}
    /// Bounded: a full trim of a large, mostly free disk is far quicker.
    static let timeout: TimeInterval = 30 * 60
    /// Fixed guest steps. Only these names leave the guest; never stderr.
    static let failureStages: Set<String> = ["prerequisites", "unsupported", "trim"]
    static let filesystemNames: Set<String> = ["root", "home"]

    static func failure(stage: String? = nil, errno code: Int32? = nil) -> VMFailure {
        let stage = stage.flatMap { failureStages.contains($0) ? $0 : nil }
        if stage == "unsupported" {
            return VMFailure(code: "reclaim-unsupported-guest", message: "This guest doesn't have the reclaim helper yet. Restart the guest so it installs the current guest integration package, then try again.", diagnostics: "stage=unsupported")
        }
        let label = stage.map { " (\($0))" } ?? ""
        let diagnostics = stage.map { "stage=\($0)" + (code.map { " errno=\($0)" } ?? "") } ?? ""
        return VMFailure(code: "reclaim-failed", message: "Unused space could not be reclaimed\(label). The guest and its data are unchanged; try again once the guest is idle.", diagnostics: diagnostics)
    }

    /// Decodes the guest's bounded `{"failure": stage, "errno": n}` report.
    static func failure(report data: Data) -> VMFailure {
        struct Report: Decodable { let failure: String; let errno: Int? }
        guard data.count <= 4096, let report = try? JSONDecoder().decode(Report.self, from: data),
              failureStages.contains(report.failure) else { return failure() }
        if let code = report.errno {
            guard (1...4095).contains(code) else { return failure(stage: report.failure) }
            return failure(stage: report.failure, errno: Int32(code))
        }
        return failure(stage: report.failure)
    }

    public func reclaim(_ request: VMStartRequest, user: String, operationID: UUID) async throws -> [String] {
        guard request.profile.ssh != nil, ManagedSSHProbe.validUser(user) else { throw Self.failure() }
        try Task.checkCancellation()
        let storage = ManagedSSHStorage(root: request.storageRoot)
        try storage.validate(request.profile)
        guard let url = ManagerResources.bundle.url(forResource: "GuestReclaim", withExtension: "py") else { throw Self.failure() }
        let script = try String(contentsOf: url, encoding: .utf8)
        // Only validated owner/UUID literals enter the fixed program.
        let program = script + "\nmain('\(request.profile.id.uuidString)', '\(request.sessionID.uuidString)', '\(user)', '\(operationID.uuidString)')\n"
        var arguments = storage.arguments(profile: request.profile, user: user)
        arguments.insert(contentsOf: ["-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"], at: 0)
        arguments[arguments.count - 1] = "/usr/bin/python3 -I -c '" + program.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let launchArguments = arguments, process = HomeBackupSSHProcess()
        let data = try await withTaskCancellationHandler {
            try await Task.detached {
                try process.run(arguments: launchArguments, timeout: Self.timeout, failure: { $0.map(Self.failure(report:)) ?? Self.failure() })
            }.value
        } onCancel: { process.cancel() }
        try Task.checkCancellation()
        return try Self.decode(data, request: request, operationID: operationID)
    }

    static func decode(_ data: Data, request: VMStartRequest, operationID: UUID) throws -> [String] {
        struct Report: Decodable { let vmID: UUID; let sessionID: UUID; let operationID: UUID; let filesystems: [String] }
        guard data.count <= 4096, let report = try? JSONDecoder().decode(Report.self, from: data),
              report.vmID == request.profile.id, report.sessionID == request.sessionID, report.operationID == operationID,
              report.filesystems.first == "root", Set(report.filesystems).isSubset(of: filesystemNames),
              Set(report.filesystems).count == report.filesystems.count else { throw failure() }
        return report.filesystems
    }
}
