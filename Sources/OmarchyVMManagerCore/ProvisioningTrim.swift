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

/// How a reviewed plan asks Omarchy for passwordless sudo. Omarchy's own prompt is
/// full screen and fixed, so the manager says in its own surfaces what it means.
public enum ProvisioningSudoGrant {
    /// `vm.sudo_grant: timed`; an absent field is dev-vm's permanent default.
    public static func isTimed(in proposal: Data) -> Bool {
        guard let document = try? PlainDataParser.parse(proposal, format: .json), case .object(let fields) = document,
              case .object(let vm) = fields["vm"] else { return false }
        return vm["sudo_grant"] == .string("timed")
    }
    public static func reviewStep(timed: Bool) -> String {
        timed ? "Omarchy asks for 60 minutes of passwordless sudo; setup renews it while it runs and turns it off when it finishes."
              : "Omarchy asks once for passwordless sudo and calls it permanent; setup turns it off when it finishes."
    }
    /// Shown while Omarchy's prompt is up, in either mode.
    public static let promptNote = "Omarchy is asking for passwordless sudo. Setup turns it off when it finishes."
}
