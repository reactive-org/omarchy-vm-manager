import DevVMProvisioningCore
import Foundation

/// Explicit configuration and reviewed theme/layout selections. Remote setup
/// retrieval and guest discovery are unsupported. Never a VM launch request.
public struct ProvisioningSetupSource: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let preset: String?
    public let directory: String?
    public let features: ProvisioningFeatureSelection?
    public let bundled: Bool?
    /// Additional bundled profiles. A local manifest's profiles stay included.
    public let profiles: [String]?
    /// nil preserves a local manifest; native controls pass an explicit choice.
    public let trimOptionalApps: Bool?
    public let appearance: ProvisioningAppearanceSelection?
    public init(preset: String, profiles: [String]? = nil, features: ProvisioningFeatureSelection? = nil, trimOptionalApps: Bool? = nil, appearance: ProvisioningAppearanceSelection? = nil) {
        self.preset = preset; directory = nil; bundled = nil; self.profiles = profiles; self.features = features; self.trimOptionalApps = trimOptionalApps; self.appearance = appearance
    }
    public init(directory: String, profiles: [String]? = nil, features: ProvisioningFeatureSelection? = nil, trimOptionalApps: Bool? = nil, appearance: ProvisioningAppearanceSelection? = nil) {
        preset = nil; self.directory = directory; bundled = nil; self.profiles = profiles; self.features = features; self.trimOptionalApps = trimOptionalApps; self.appearance = appearance
    }
    public init(profiles: [String], trimOptionalApps: Bool? = nil, appearance: ProvisioningAppearanceSelection? = nil) {
        preset = nil; directory = nil; bundled = true; self.profiles = profiles; features = nil; self.trimOptionalApps = trimOptionalApps; self.appearance = appearance
    }
    public var description: String { "ProvisioningSetupSource(redacted)" }
    public var debugDescription: String { description }
    func validate() throws {
        try features?.validate(); try appearance?.validate()
        guard [preset != nil, directory != nil, bundled == true].filter({ $0 }).count == 1,
              bundled == nil || bundled == true else { throw ProvisioningReviewFailure.invalid }
        if let profiles {
            guard profiles.count <= BundledProvisioning.presets.count, Set(profiles).count == profiles.count,
                  profiles.allSatisfy(BundledProvisioning.presets.contains) else { throw ProvisioningReviewFailure.invalid }
        }
        if bundled == true, profiles?.isEmpty != false { throw ProvisioningReviewFailure.invalid }
        if let preset { guard BundledProvisioning.presets.contains(preset) else { throw ProvisioningReviewFailure.invalid } }
        if let directory {
            guard directory.hasPrefix("/"), directory.utf8.count <= 4096,
                  !directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !directory.contains("//"), !directory.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw ProvisioningReviewFailure.invalid }
        }
    }
}
public enum ProvisioningReviewFailure: String, Error, Sendable {
    case invalid, unavailable, quota, changed, consentRequired, taskTrustRequired, conflictingConsent, conflictingProfiles
}
public struct ProvisioningTaskReview: Codable, Equatable, Sendable {
    public let name: String, file: String, sha256: String
}
/// Reviewed proposal and receipts, without source-file contents or host paths.
/// Full task bytes require a separate explicit task-source request.
public struct ProvisioningPlanPreview: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID, vmID: UUID
    public let sessionID: UUID?
    public let planDigest: String, inputDigest: String, engineDigest: String
    public let proposal: Data
    public let tasks: [ProvisioningTaskReview]
    public let restartRequired: Bool
    public var description: String { "ProvisioningPlanPreview(redacted)" }
    public var debugDescription: String { description }
    func validate() throws {
        guard [planDigest, inputDigest, engineDigest].allSatisfy(provisioningDigest), proposal.count <= 48 * 1024, tasks.count <= 64,
              Set(tasks.map(\.name)).count == tasks.count,
              tasks.allSatisfy({ $0.name.utf8.count <= 64 && $0.file.utf8.count <= 256 && provisioningDigest($0.sha256) }),
              case .object(let document) = try PlainDataParser.parse(proposal, format: .json), document["plan_digest"] == .string(planDigest),
              document["input_digest"] == .string(inputDigest) else { throw ProvisioningReviewFailure.invalid }
    }
}
public struct ProvisioningApplyReview: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let previewID: UUID, vmID: UUID, sessionID: UUID
    public let planDigest: String, inputDigest: String, dependencyDigest: String, reviewIdentity: String
    public let taskTrustIdentity: String?
    public let persistentGrantRequired: Bool, dockerRootAccessRequired: Bool
    public var description: String { "ProvisioningApplyReview(redacted)" }
    public var debugDescription: String { description }
    func validate() throws {
        guard [planDigest, inputDigest, dependencyDigest, reviewIdentity].allSatisfy(provisioningDigest),
              taskTrustIdentity.map(provisioningDigest) ?? true, persistentGrantRequired else { throw ProvisioningReviewFailure.invalid }
    }
}
public struct ProvisioningApplyConsent: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let reviewIdentity: String
    public let taskTrustIdentity: String?
    public let persistentGrantAcknowledged: Bool, dockerRootAccessAcknowledged: Bool
    public init(reviewIdentity: String, taskTrustIdentity: String? = nil, persistentGrantAcknowledged: Bool = false, dockerRootAccessAcknowledged: Bool = false) {
        self.reviewIdentity = reviewIdentity; self.taskTrustIdentity = taskTrustIdentity
        self.persistentGrantAcknowledged = persistentGrantAcknowledged; self.dockerRootAccessAcknowledged = dockerRootAccessAcknowledged
    }
    public var description: String { "ProvisioningApplyConsent(redacted)" }
    public var debugDescription: String { description }
    func validate() throws {
        guard provisioningDigest(reviewIdentity), taskTrustIdentity.map(provisioningDigest) ?? true else { throw ProvisioningReviewFailure.invalid }
    }
}
public struct ProvisioningTaskSource: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let previewID: UUID
    public let name: String, sha256: String
    public let offset: Int, total: Int
    public let bytes: Data
    public var description: String { "ProvisioningTaskSource(redacted)" }
    public var debugDescription: String { description }
}
public protocol ProvisioningReviewing: ProvisioningObserving {
    func preview(id: UUID, vmID: UUID, source: ProvisioningSetupSource) async throws -> ProvisioningPlanPreview
    func preview(_ id: UUID) async throws -> ProvisioningPlanPreview
    func taskSource(_ id: UUID, name: String, offset: Int) async throws -> ProvisioningTaskSource
    func prepareApply(_ id: UUID) async throws -> ProvisioningApplyReview
    func apply(_ id: UUID, consent: ProvisioningApplyConsent) async throws -> ProvisioningWorkflowSnapshot
}

struct ProvisioningDraft: Sendable {
    let selection: ProvisioningSetupSource
    let preview: ProvisioningPlanPreview
    let storage: ProvisioningPrivateInputTree
    let plan: SetupPlan
}
