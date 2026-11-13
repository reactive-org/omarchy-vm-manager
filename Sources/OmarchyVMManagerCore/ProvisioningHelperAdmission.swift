import Darwin
import Foundation
import Security

/// Fixture policy is explicit and internal. Stable and signed Dev prereleases
/// require non-ad-hoc signatures with the application's same Team ID. Local Dev
/// builds (compiled without SIGNED_PRERELEASE) also admit a matching ad-hoc
/// app/helper pair so setup can be tested without a signing identity; a team-signed
/// app still needs its same-team helper, and mixed pairs are always refused.
/// The policy is fixed at compile time: no environment, metadata or wire switch.
enum ProvisioningHelperSigningPolicy: Sendable {
    case sameApplicationTeam, adHocFixture, sameApplicationTeamOrLocalAdHoc

    static var product: Self {
        #if DEVELOPMENT_CHANNEL && !SIGNED_PRERELEASE
        .sameApplicationTeamOrLocalAdHoc
        #else
        .sameApplicationTeam
        #endif
    }

    /// Pure signature-pair decision; the bundle hash, file and running-child
    /// cdHash checks still apply under every policy.
    func admits(outer: ProvisioningHelperCodeIdentity, helper: ProvisioningHelperCodeIdentity) -> Bool {
        switch self {
        case .sameApplicationTeam:
            guard !outer.adHoc, !helper.adHoc, let team = outer.team, !team.isEmpty else { return false }
            return helper.team == team
        case .adHocFixture:
            return outer.adHoc && helper.adHoc && outer.team == nil && helper.team == nil
        case .sameApplicationTeamOrLocalAdHoc:
            return Self.sameApplicationTeam.admits(outer: outer, helper: helper) || Self.adHocFixture.admits(outer: outer, helper: helper)
        }
    }
}
struct ProvisioningHelperCodeIdentity: Sendable, Equatable {
    let cdHash: Data
    let team: String?
    let adHoc: Bool
}
final class ProvisioningHelperLaunchAdmission: @unchecked Sendable {
    let layout: ProvisioningPackageLayout
    let executable: URL
    let executableSHA256: String
    let codeIdentity: ProvisioningHelperCodeIdentity
    private let policy: ProvisioningHelperSigningPolicy
    private var fd: Int32
    private let stamp: Stamp
    private struct Stamp: Equatable {
        let device: dev_t, inode: ino_t, size: off_t, mode: mode_t
        let modified: Int, nanos: Int, changed: Int, changedNanos: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size; mode = value.st_mode
            modified = value.st_mtimespec.tv_sec; nanos = value.st_mtimespec.tv_nsec
            changed = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
    }
    init(layout: ProvisioningPackageLayout, policy: ProvisioningHelperSigningPolicy) throws {
        self.layout = layout; self.policy = policy
        executable = layout.binaries.appendingPathComponent("OmarchyVMProvisioningHelper")
        _ = try BundledProvisioning.inspect(layout)
        codeIdentity = try Self.verifySignatures(layout, policy: policy)
        executableSHA256 = try BundledProvisioning.helperExecutableSHA256(layout)
        fd = open(executable.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0, info.st_nlink == 1 else {
            if fd >= 0 { Darwin.close(fd) }; throw ProvisioningHelperIPCFailure.authentication
        }
        stamp = Stamp(info)
        do { try revalidate() } catch { Darwin.close(fd); fd = -1; throw error }
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    func revalidate() throws {
        _ = try BundledProvisioning.inspect(layout)
        var held = stat(), path = stat()
        guard fstat(fd, &held) == 0, lstat(executable.path, &path) == 0,
              Stamp(held) == stamp, Stamp(path) == stamp,
              executableSHA256 == (try BundledProvisioning.helperExecutableSHA256(layout)),
              codeIdentity == (try Self.verifySignatures(layout, policy: policy)) else { throw ProvisioningHelperIPCFailure.authentication }
    }
    /// PID comes only from this launch's owned child handle. It is not read from
    /// disk or used as an ownership proof. Authentication still needs its private
    /// inherited channel and exact registration receipt.
    func verifyOwnedChild(_ pid: pid_t) throws {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { throw ProvisioningHelperIPCFailure.authentication }
        var information: CFDictionary?
        var staticCode: SecStaticCode?
        let hash = codeIdentity.cdHash.map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(("cdhash H\"" + hash + "\"") as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], values[kSecCodeInfoUnique as String] as? Data == codeIdentity.cdHash,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw ProvisioningHelperIPCFailure.authentication }
    }
    private static func verifySignatures(_ layout: ProvisioningPackageLayout, policy: ProvisioningHelperSigningPolicy) throws -> ProvisioningHelperCodeIdentity {
        let app = layout.contents.deletingLastPathComponent()
        guard app.pathExtension == "app", layout.contents.lastPathComponent == "Contents" else { throw ProvisioningHelperIPCFailure.authentication }
        let outer = try staticIdentity(app, nested: true)
        let helper = try staticIdentity(layout.binaries.appendingPathComponent("OmarchyVMProvisioningHelper"), nested: false)
        guard policy.admits(outer: outer, helper: helper) else { throw ProvisioningHelperIPCFailure.authentication }
        return helper
    }
    private static func staticIdentity(_ url: URL, nested: Bool) throws -> ProvisioningHelperCodeIdentity {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | (nested ? kSecCSCheckNestedCode : 0)), nil) == errSecSuccess else { throw ProvisioningHelperIPCFailure.authentication }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let hash = values[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty,
              let flags = values[kSecCodeInfoFlags as String] as? NSNumber else { throw ProvisioningHelperIPCFailure.authentication }
        return .init(cdHash: hash, team: values[kSecCodeInfoTeamIdentifier as String] as? String, adHoc: flags.uint32Value & 2 != 0)
    }
}
