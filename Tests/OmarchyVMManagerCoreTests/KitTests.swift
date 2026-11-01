import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

struct KitFixture {
    let folder: URL
    let kit: TryOmarchyKit
    var lock: RuntimeProvenance
    var data: Data { get throws { try JSONEncoder().encode(lock) } }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = folder.appendingPathComponent("TryOmarchyKit.bundle")
        kit = TryOmarchyKit(bundleURL: bundle)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let helper = bundle.appendingPathComponent(TryOmarchyKit.helperPath)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try Data(#"{"format":1,"version":"development","runProtocolVersion":1,"buildDate":"2026-10-31T00:00:00Z"}"#.utf8).write(to: kit.manifestURL)
        lock = RuntimeProvenance(format: 1, upstreamBase: UpstreamBaseline.commit,
                                 patchCommit: String(repeating: "a", count: 40),
                                 patchSHA256: String(repeating: "b", count: 64),
                                 referenceKitSHA256: UpstreamBaseline.stockSHA256,
                                 kitSHA256: String(repeating: "c", count: 64), kitVersion: "development",
                                 runProtocolVersion: 1, buildDate: "2026-10-31T00:00:00Z", focusAwareClipboard: true,
                                 composition: "test protocol fixture", files: try KitVerifier.inventory(at: bundle))
    }
    func cleanup() { try? FileManager.default.removeItem(at: folder) }
    func inspect(policy: KitBuildPolicy = .debugPOC) throws -> KitDiagnostics {
        let bytes = try data
        return try KitVerifier.inspect(kit: kit, lockData: bytes, expectedLockSHA256: KitVerifier.sha256(bytes),
                                       policy: policy, preflight: { nil })
    }
}

@Suite("Kit provenance")
struct KitTests {
    @Test("signed fork provenance requires a distinct runtime, source pin and signing team")
    func signedPrereleasePolicy() throws {
        var fixture = try KitFixture(); defer { fixture.cleanup() }
        #expect(throws: VMFailure.self) { try KitVerifier.validate(fixture.lock, policy: .signedPrerelease) }
        fixture.lock.signingTeamID = "ABC1234567"
        fixture.lock.sourceKitSHA256 = String(repeating: "d", count: 64)
        fixture.lock.sourceLockSHA256 = String(repeating: "e", count: 64)
        try KitVerifier.validate(fixture.lock, policy: .signedPrerelease)
        #expect(throws: VMFailure.self) { try KitVerifier.validate(fixture.lock, policy: .debugPOC) }
        #expect(throws: VMFailure.self) { try KitVerifier.validate(fixture.lock, policy: .release) }
        fixture.lock.sourceKitSHA256 = fixture.lock.kitSHA256
        #expect(throws: VMFailure.self) { try KitVerifier.validate(fixture.lock, policy: .signedPrerelease) }
        fixture.lock.sourceKitSHA256 = String(repeating: "d", count: 64)
        fixture.lock.signingTeamID = "unknown"
        #expect(throws: VMFailure.self) { try KitVerifier.validate(fixture.lock, policy: .signedPrerelease) }
    }
    @Test("locked development kit is allowed only in a private debug build")
    func developmentPolicy() throws {
        let fixture = try KitFixture(); defer { fixture.cleanup() }
        let result = try fixture.inspect()
        #expect(result.supported && result.focusAwareClipboard)
        #expect(result.preflightFailure == nil)
        #expect(throws: VMFailure.self) { try fixture.inspect(policy: .release) }
    }

    @Test("missing kit and missing helper fail without creating storage")
    func missingKit() throws {
        let fixture = try KitFixture(); defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.kit.bundleURL.appendingPathComponent(TryOmarchyKit.helperPath))
        #expect(throws: (any Error).self) { try fixture.inspect() }
        try FileManager.default.removeItem(at: fixture.kit.bundleURL)
        #expect(throws: (any Error).self) { try fixture.inspect() }
    }

    @Test("manifest protocol and version mismatch are rejected", arguments: ["protocol", "version", "date"])
    func incompatibleManifest(field: String) throws {
        let fixture = try KitFixture(); defer { fixture.cleanup() }
        var value: [String: Any] = ["format": 1, "version": "development", "runProtocolVersion": 1, "buildDate": "2026-10-31T00:00:00Z"]
        if field == "protocol" { value["runProtocolVersion"] = 2 }
        if field == "version" { value["version"] = "v1.3.0" }
        if field == "date" { value["buildDate"] = "2026-10-30T00:00:00Z" }
        try JSONSerialization.data(withJSONObject: value).write(to: fixture.kit.manifestURL)
        #expect(throws: VMFailure.self) { try fixture.inspect() }
    }

    @Test("damaged files, extra files and symlinks are rejected", arguments: ["changed", "extra", "symlink"])
    func damagedPayload(mode: String) throws {
        let fixture = try KitFixture(); defer { fixture.cleanup() }
        let file = fixture.kit.bundleURL.appendingPathComponent(mode == "changed" ? TryOmarchyKit.helperPath : "unexpected")
        if mode == "symlink" { try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "/private/tmp") }
        else { try Data("changed".utf8).write(to: file) }
        #expect(throws: VMFailure.self) { try fixture.inspect() }
    }

    @Test("lock changes cannot self-assert capability")
    func lockTampering() throws {
        let fixture = try KitFixture(); defer { fixture.cleanup() }
        #expect(throws: VMFailure.self) {
            try KitVerifier.inspect(kit: fixture.kit, lockData: fixture.data,
                                    expectedLockSHA256: String(repeating: "0", count: 64), policy: .debugPOC)
        }
    }

    @Test("stock clipboard capability is refused even for the first session", arguments: [0, 1, 2])
    func stockClipboard(active: Int) throws {
        #expect(throws: VMFailure.self) {
            try ClipboardCapabilityPolicy.validate(focusAware: false, clipboardEnabled: true, activeClipboardSessions: active)
        }
        try ClipboardCapabilityPolicy.validate(focusAware: false, clipboardEnabled: false, activeClipboardSessions: active)
        try ClipboardCapabilityPolicy.validate(focusAware: true, clipboardEnabled: true, activeClipboardSessions: active)
    }

    @Test("host preflight failure is visible without launching")
    func preflight() throws {
        let fixture = try KitFixture(); defer { fixture.cleanup() }
        let bytes = try fixture.data
        let result = try KitVerifier.inspect(kit: fixture.kit, lockData: bytes, expectedLockSHA256: KitVerifier.sha256(bytes), policy: .debugPOC,
                                            preflight: { VMRunError(code: .hypervisorUnavailable, message: "Test host unavailable") })
        #expect(result.preflightFailure == "Test host unavailable")
    }
}
