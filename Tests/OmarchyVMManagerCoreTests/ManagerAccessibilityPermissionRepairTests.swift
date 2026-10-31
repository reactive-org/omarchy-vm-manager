import Foundation
import Testing
@testable import OmarchyVMManagerCore

private struct PermissionRepairFixture {
    let root: URL
    let tool: URL
    var arguments: URL { URL(fileURLWithPath: tool.path + ".args") }

    init(exitCode: Int = 0) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("manager-permission-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        tool = root.appendingPathComponent("fake tccutil")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\nexit \(exitCode)\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Manager-only Accessibility repair")
struct ManagerAccessibilityPermissionRepairTests {
    @Test("unknown and personal app identifiers cannot invoke the permission tool")
    func refusesOtherApps() throws {
        let fixture = try PermissionRepairFixture(); defer { fixture.cleanup() }
        for identifier: String? in [nil, "", "dev.tryomarchy.native", "dev.tryomarchy.native.development", "dev.omarchy.vm-manager.other"] {
            #expect(!ManagerAccessibilityPermissionRepair.resetStaleEntry(bundleIdentifier: identifier, tccutilURL: fixture.tool))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.arguments.path))
    }

    @Test("the mock tool receives only the current manager's Accessibility reset")
    func exactScope() throws {
        let fixture = try PermissionRepairFixture(); defer { fixture.cleanup() }
        #expect(ManagerAccessibilityPermissionRepair.resetStaleEntry(
            bundleIdentifier: ManagerAccessibilityPermissionRepair.bundleIdentifier, tccutilURL: fixture.tool))
        #expect(try String(contentsOf: fixture.arguments, encoding: .utf8) == "reset\nAccessibility\ndev.omarchy.vm-manager\n")
    }

    @Test("failed or unavailable mock tools cannot report a successful repair")
    func failure() throws {
        let fixture = try PermissionRepairFixture(exitCode: 9); defer { fixture.cleanup() }
        #expect(!ManagerAccessibilityPermissionRepair.resetStaleEntry(
            bundleIdentifier: ManagerAccessibilityPermissionRepair.bundleIdentifier, tccutilURL: fixture.tool))
        #expect(!ManagerAccessibilityPermissionRepair.resetStaleEntry(
            bundleIdentifier: ManagerAccessibilityPermissionRepair.bundleIdentifier, tccutilURL: fixture.root.appendingPathComponent("missing")))
    }
}
