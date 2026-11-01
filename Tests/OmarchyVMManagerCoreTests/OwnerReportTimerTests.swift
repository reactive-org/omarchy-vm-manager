import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

@Suite("Owner completion report after real host cleanup — isolated guests")
struct OwnerReportTimerTests {
    @Test("both contracts report across host finish and repeated fresh reporter processes", arguments: [VMOwnerSetupContract.official, VMOwnerSetupContract.lean])
    func hostCleanup(_ contract: String) throws {
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        var profile = fixture.profile(name: "Isolated owner reporter")
        profile.ownerSetup = try OwnerDefaults(enabled: true, configuration: OwnerConfiguration(username: "owner"), credentialReference: UUID()).snapshot(for: profile.id)
        let token = UUID()
        let root = try fixture.storage.prepare(profile, sessionID: token, ownerPassword: Data("synthetic-password".utf8), ownerContract: contract)
        let request = VMStartRequest(profile: profile, storageRoot: root, sessionID: token)
        let owner = ManagedOwnerStorage(root: root)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = repository.appendingPathComponent(".build/runtime-source").resolvingSymlinksInPath()
        func report(_ mode: String) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [repository.appendingPathComponent("Tests/Fixtures/owner_report_driver.py").path, mode, root.path, source.path]
            process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
            let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let diagnostics = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            #expect(process.terminationStatus == 0, "Isolated reporter: \(String(decoding: diagnostics, as: UTF8.self))")
            return data
        }
        let first = try report("complete")
        try owner.finish(profile)
        #expect(try owner.completed(profile))
        for path in [owner.bootstrap.appendingPathComponent("owner-setup.json"), owner.bootstrap.appendingPathComponent("manifest.json"), root.appendingPathComponent(ManagedOwnerStorage.launchName)] {
            #expect(!FileManager.default.fileExists(atPath: path.path))
        }
        let shell = root.appendingPathComponent("shell"); try PrivateFiles.directory(shell, create: true)
        for _ in 0..<3 {
            let data = try report("report")
            #expect(try JSONSerialization.jsonObject(with: data) as? NSDictionary == JSONSerialization.jsonObject(with: first) as? NSDictionary)
            let payload = try JSONSerialization.jsonObject(with: data)
            let record: [String: Any] = ["receivedAt": ISO8601DateFormatter().string(from: Date()), "report": ["managedSetup": payload]]
            try PrivateFiles.write(JSONSerialization.data(withJSONObject: record), name: "guest-status.json", in: shell)
            #expect(try OwnerSetupGuestReport.read(request)?.state == "configured")
            let other = VMStartRequest(profile: profile, storageRoot: root, sessionID: UUID())
            #expect(try OwnerSetupGuestReport.read(other) == nil)
            for (field, wrong) in [("vmID", UUID().uuidString), ("fingerprint", String(repeating: "b", count: 64)), ("owner", "another")] {
                var changed = payload as! [String: Any]; changed[field] = wrong
                let invalid: [String: Any] = ["receivedAt": ISO8601DateFormatter().string(from: Date()), "report": ["managedSetup": changed]]
                try PrivateFiles.write(JSONSerialization.data(withJSONObject: invalid), name: "guest-status.json", in: shell)
                #expect(try OwnerSetupGuestReport.read(request) == nil)
            }
            try owner.finish(profile); try owner.clearSeed()
        }
    }
}
