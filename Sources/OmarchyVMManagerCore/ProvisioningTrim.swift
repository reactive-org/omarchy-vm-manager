import DevVMProvisioningCore
import Foundation

/// The native trim option is limited to the exact admitted official factory.
/// The manifest flag alone never establishes a VM's provenance.
public enum ProvisioningTrim {
    public static func isAvailable(for factory: FactoryIdentity?) -> Bool { factory == .official }
    public static func isRequested(in proposal: Data) -> Bool {
        guard let document = try? PlainDataParser.parse(proposal, format: .json), case .object(let fields) = document,
              case .object(let vm) = fields["vm"] else { return false }
        return vm["lean_developer"] == .bool(true)
    }
    static func admit(_ plan: SetupPlan, factory: FactoryIdentity?) throws {
        guard case .object(let fields) = plan.document, case .object(let vm) = fields["vm"] else { throw ProvisioningReviewFailure.invalid }
        if vm["lean_developer"] == .bool(true), !isAvailable(for: factory) { throw ProvisioningReviewFailure.invalid }
    }
}
