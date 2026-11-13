import Foundation
import Testing
@testable import OmarchyVMManagerCore

@Suite("Desktop defaults — disposable temp roots only")
struct DesktopDefaultsTests {
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/desktop-defaults-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test func missingFileMeansNoDefaults() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try DesktopDefaultsStore(applicationSupport: root, channel: .development).load() == nil)
    }

    @Test func roundTripsAndClearsEmptySelections() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopDefaultsStore(applicationSupport: root, channel: .development)
        let value = ProvisioningAppearanceSelection(theme: "random", minimumStars: 25, layoutExample: .vscodeBrowser)
        try store.save(value)
        #expect(try store.load() == value)
        try store.save(ProvisioningAppearanceSelection())
        #expect(try store.load() == nil)
    }

    @Test func refusesInvalidSelections() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopDefaultsStore(applicationSupport: root, channel: .development)
        #expect(throws: (any Error).self) { try store.save(ProvisioningAppearanceSelection(removeLayout: true, layoutExample: .fourTerminals)) }
        #expect(try store.load() == nil)
    }
}
