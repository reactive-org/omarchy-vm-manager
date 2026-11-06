import DevVMProvisioningCore
import Foundation

public extension FactoryBuildFailure {
    /// Fixed explanations only. Raw process output is confined to the live terminal.
    var explanation: String {
        switch self {
        case .dockerMissing: "Docker is not installed. Install a Docker CLI and local ARM64 Linux engine separately, then check again."
        case .dockerUnavailable: "Docker is unavailable. Start your local Docker engine, then check again."
        case .remoteEngine: "Choose a local Docker context with a Unix socket. Remote engines are not supported."
        case .wrongArchitecture: "An Apple Silicon Mac and an ARM64 Linux Docker engine are required."
        case .engineChanged: "Docker or its selected engine changed. Check readiness again."
        case .insufficientSpace: "More free space is needed on the build volume."
        case .busy: "Another build is active, or cleanup needs to be verified."
        case .cleanupRequired: "Build cleanup has not been confirmed. Verify this job’s owned resources before building again."
        case .inputsChanged: "The reviewed build inputs changed. Use a complete verified Dev app."
        case .invalidRequest: "The build selection or command is invalid. Check the name, size and review identifier."
        case .downloadFailed: "A reviewed download failed its accessibility, size or checksum checks. No factory was added."
        case .commandFailed, .invalidArtifact: "The build could not finish. Its output was preserved; inspect the live terminal and build details."
        case .cancelled: "The build was cancelled."
        }
    }
}

public struct FactoryBuildRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case plan, start, status, logs, cancel, cleanup }
    public var operation: Operation
    public var name: String?
    public var sizeGiB: Int?
    public var id: UUID?
    public var cursor: UInt64?
    public init(operation: Operation, name: String? = nil, sizeGiB: Int? = nil, id: UUID? = nil, cursor: UInt64? = nil) {
        self.operation = operation; self.name = name; self.sizeGiB = sizeGiB; self.id = id; self.cursor = cursor
    }
    public func validate() throws {
        guard operation == .plan || (name == nil && sizeGiB == nil),
              operation == .logs || cursor == nil, cursor == nil || cursor! < UInt64(Int64.max),
              operation != .plan || id == nil,
              [.plan, .status].contains(operation) || id != nil else { throw FactoryBuildFailure.invalidRequest }
        if operation == .plan { _ = try FactoryBuildPlan(name: name ?? "Lean Omarchy", sizeGiB: sizeGiB ?? 20) }
    }
}
public struct FactoryBuildReply: Codable, Sendable {
    public var review: FactoryBuildReview?
    public var jobs: [FactoryBuildJob]?
    public var bytes: Data?
    public var sequence: UInt64?
    public var reset: Bool?
}
extension FactoryBuildControlling {
    func execute(_ request: FactoryBuildRequest) async throws -> FactoryBuildReply {
        guard enabled else { throw commandFailure("factory-build-disabled", "Factory building is available in Dev.") }
        try request.validate()
        var reply = FactoryBuildReply()
        switch request.operation {
        case .plan: reply.review = try await review(name: request.name ?? "Lean Omarchy", sizeGiB: request.sizeGiB ?? 20)
        case .start: reply.jobs = [try await start(reviewID: request.id!)]
        case .status: reply.jobs = try await jobs().filter { request.id == nil || $0.id == request.id }
        case .cancel: try await cancel(request.id!); reply.jobs = try await jobs().filter { $0.id == request.id }
        case .cleanup: try await recover(request.id!); reply.jobs = try await jobs().filter { $0.id == request.id }
        case .logs:
            let page = try await output(request.id!, after: request.cursor ?? 0)
            reply.bytes = page.bytes; reply.sequence = page.sequence; reply.reset = page.reset
            reply.jobs = try await jobs().filter { $0.id == request.id }
        }
        return reply
    }
}
public enum FactoryBuildCLI {
    public static let help = """
    factory-build plan [--name NAME] [--size-gib 20..128]
    factory-build start REVIEW_UUID
    factory-build status [JOB_UUID]
    factory-build logs JOB_UUID [--follow]
    factory-build cancel JOB_UUID
    factory-build cleanup JOB_UUID
    Planning checks existing Docker readiness. Start explicitly authorizes downloads
    and an owned privileged build container. No VM is created or launched.
    """
    public static func parse(_ args: [String]) throws -> (FactoryBuildRequest, follow: Bool)? {
        guard args.first == "factory-build" else { return nil }
        guard args.count >= 2, let op = FactoryBuildRequest.Operation(rawValue: args[1]) else { throw FactoryBuildFailure.invalidRequest }
        var request = FactoryBuildRequest(operation: op), follow = false
        if op == .plan {
            var index = 2, seen = Set<String>()
            while index < args.count {
                let key = args[index]; guard seen.insert(key).inserted, index + 1 < args.count else { throw FactoryBuildFailure.invalidRequest }
                if key == "--name" { request.name = args[index+1] }
                else if key == "--size-gib", let size = Int(args[index+1]) { request.sizeGiB = size }
                else { throw FactoryBuildFailure.invalidRequest }
                index += 2
            }
        } else if op == .status, args.count == 2 { }
        else {
            guard (3...4).contains(args.count), let id = UUID(uuidString: args[2]) else { throw FactoryBuildFailure.invalidRequest }
            request.id = id
            if args.count == 4 { guard op == .logs, args[3] == "--follow" else { throw FactoryBuildFailure.invalidRequest }; follow = true }
        }
        try request.validate(); return (request, follow)
    }
}
