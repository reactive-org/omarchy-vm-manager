import DevVMProvisioningCore
import Foundation

/// Where a run's frozen choices live, recorded when the run is accepted (issue #14).
/// The private input tree already holds the choices (the projected selection
/// manifest and layout); this record names that tree and its manifest so a retry
/// can rebuild the plan with the current engine without rereading the live source
/// folder, and orders a guest's runs so Change setup can show the latest one.
/// No host path, credential or file content is recorded.
struct ProvisioningPlanRecord: Codable, Equatable, Sendable {
    let id: UUID, vmID: UUID
    /// `inputs-<UUID>` directly inside the service's private `sources` directory.
    let tree: String
    /// Manifest path relative to that tree.
    let manifest: String
    let planDigest: String, inputDigest: String, engineDigest: String
    /// Resolved feature names, so a retry under a changed engine can say what changed.
    let features: [String]
    func validate() throws {
        guard tree.hasPrefix("inputs-"), UUID(uuidString: String(tree.dropFirst(7))) != nil, manifest.utf8.count <= 512,
              [planDigest, inputDigest, engineDigest].allSatisfy(provisioningDigest), features.count <= 128,
              features.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw ProvisioningJobFailure.journalUnavailable }
        _ = try frozenRelativeComponents(manifest)
    }
}

/// Small private index beside the job and workflow journals. It is a separate
/// file so the workflow journal's schema, which earlier builds read strictly, is
/// unchanged. A damaged file is preserved and refuses new records (fail closed),
/// so a run is never accepted without the record its retry needs.
final class ProvisioningPlanHistory: @unchecked Sendable {
    private struct Document: Codable { let schemaVersion: Int; let plans: [ProvisioningPlanRecord] }
    static let limit = 128
    let directory: URL
    private var records: [ProvisioningPlanRecord] = []
    private var damaged = false
    private var file: URL { directory.appendingPathComponent("plans.json") }
    init(directory: URL) {
        self.directory = directory
        do {
            try PrivateFiles.directory(directory, create: true)
            guard PrivateFiles.exists(file) else { return }
            let data = try PrivateFiles.read(file, maximum: 512 * 1024)
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.schemaVersion == 1, document.plans.count <= Self.limit, Set(document.plans.map(\.id)).count == document.plans.count else { throw ProvisioningJobFailure.journalUnavailable }
            try document.plans.forEach { try $0.validate() }
            records = document.plans
        } catch { damaged = true; records = [] }
    }
    func record(_ id: UUID) -> ProvisioningPlanRecord? { records.first { $0.id == id } }
    /// The most recently accepted plan for a guest, if this history has one.
    func latest(vmID: UUID) -> ProvisioningPlanRecord? { records.last { $0.vmID == vmID } }
    /// Idempotent for an existing ID: a repeated submission keeps its place.
    func append(_ value: ProvisioningPlanRecord) throws {
        try value.validate()
        guard !damaged else { throw ProvisioningJobFailure.journalUnavailable }
        if let existing = record(value.id) { guard existing == value else { throw ProvisioningJobFailure.jobConflict }; return }
        var updated = records + [value]
        // Drop the oldest record that isn't some guest's latest, then the oldest.
        while updated.count > Self.limit {
            let latestIDs = Set(Dictionary(grouping: updated, by: \.vmID).values.compactMap { $0.last?.id })
            updated.remove(at: updated.firstIndex { !latestIDs.contains($0.id) } ?? 0)
        }
        do { try PrivateFiles.write(try helperJSON(Document(schemaVersion: 1, plans: updated)), name: file.lastPathComponent, in: directory) }
        catch { damaged = true; throw ProvisioningJobFailure.journalUnavailable }
        records = updated
    }
    /// Tests only (internal; optimized test builds use it too): replace a record,
    /// e.g. to stand in for a run made by an older engine.
    func replaceForTesting(_ value: ProvisioningPlanRecord) throws {
        guard let index = records.firstIndex(where: { $0.id == value.id }) else { throw ProvisioningJobFailure.jobConflict }
        records[index] = value
        try PrivateFiles.write(try helperJSON(Document(schemaVersion: 1, plans: records)), name: file.lastPathComponent, in: directory)
    }
}
