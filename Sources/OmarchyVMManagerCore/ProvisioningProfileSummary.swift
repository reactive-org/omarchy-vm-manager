import DevVMProvisioningCore
import Foundation

/// Presentation extracted from the admitted shared resolver, not a second
/// feature catalogue. These are expected inclusions, not guest observations.
public struct ProvisioningProfileSummary: Identifiable, Sendable {
    public let id: String
    public let includedFeatures: [String]
    public let additionalFeatures: [String]
    public let includesDeveloper: Bool
    public let tools: [String]
    public let databaseClients: [String]
}
extension BundledProvisioning {
    public static func profileSummaries() throws -> [ProvisioningProfileSummary] {
        let baseline = Set(try FeaturePlanner.resolve(profiles: ["developer"]).features)
        return try presets.map { id in
            let resolved = try FeaturePlanner.resolve(profiles: [id])
            let inherited = id != "developer" && baseline.isSubset(of: Set(resolved.features))
            let options = resolved.options
            let tools = profileObject(profileObject(options["languages"])["tools"]).keys.sorted()
            let clients = profileStrings(profileObject(options["databases"])["clients"])
            return .init(id: id, includedFeatures: resolved.features,
                additionalFeatures: resolved.features.filter { !inherited || !baseline.contains($0) },
                includesDeveloper: inherited, tools: tools, databaseClients: clients)
        }
    }
}

private func profileObject(_ value: ManifestValue?) -> [String: ManifestValue] {
    if case .object(let fields) = value { return fields }; return [:]
}
private func profileStrings(_ value: ManifestValue?) -> [String] {
    guard case .array(let items) = value else { return [] }
    return items.compactMap { if case .string(let text) = $0 { return text }; return nil }
}
