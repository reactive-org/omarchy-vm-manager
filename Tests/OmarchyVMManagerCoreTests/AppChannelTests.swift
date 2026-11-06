import Darwin
import Foundation
import Testing
@testable import OmarchyVMManagerCore

@Suite("Stable and Dev isolation — disposable metadata only")
struct AppChannelTests {
    @Test("stable preserves the existing paths, endpoint and credential services")
    func stableCompatibility() {
        let support = URL(fileURLWithPath: "/private/tmp/channel-compatibility")
        let stable = AppChannel.stable
        #expect(stable.directory(in: support).path == support.path + "/Omarchy VM Manager")
        let hash = KitVerifier.sha256(Data(support.path.utf8)).prefix(16)
        #expect(ManagerCommandEndpoint(applicationSupport: support, channel: stable).socket.path == "/private/tmp/omarchy-manager-\(getuid())-\(hash)/control.sock")
        #expect(stable.bundleIdentifier == "dev.omarchy.vm-manager")
        #expect(stable.activationNotification == "dev.omarchy.vm-manager.activate")
        #expect(stable.credentialService == "dev.omarchy.vm-manager.unattended.biometric.v1")
        #expect(stable.legacyCredentialService == "dev.omarchy.vm-manager.unattended")
        #expect(stable.sshPorts == 2222...49151)
        #expect(!stable.sshPorts.overlaps(AppChannel.development.sshPorts))
        #expect(stable.guestName("Work") == "Work")
    }

    @Test("Setup sockets are isolated by channel while stable keeps its endpoint")
    func setupSocketIsolation() {
        let support = URL(fileURLWithPath: "/private/tmp/setup-channel-fixture")
        let stable = ManagerCommandEndpoint(applicationSupport: support, channel: .stable)
        let dev = ManagerCommandEndpoint(applicationSupport: support, channel: .development)
        #expect(stable.provisioning.socket != dev.provisioning.socket)
        #expect(stable.provisioning.directory == stable.directory)
        #expect(dev.provisioning.directory == dev.directory)
        #expect(stable.provisioning.socket.lastPathComponent == "setup-v1.sock")
        #expect(dev.provisioning.socket.lastPathComponent == "setup-v1.sock")
    }

    @Test("both managers can hold their own locks; Dev deletion preserves stable registry and root")
    func storageIsolation() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let stable = ManagerStorage(applicationSupport: f.support, channel: .stable)
        let dev = ManagerStorage(applicationSupport: f.support, channel: .development)
        let profile = f.profile()
        let stableStore = try RegistryStore(applicationSupport: f.support, channel: .stable)
        #expect(try stableStore.load().isEmpty)
        try stableStore.save([profile])
        let stableRoot = try stable.prepare(profile)
        let beforeRegistry = try PrivateFiles.read(stable.directory.appendingPathComponent("registry.json"))
        let beforeSettings = try PrivateFiles.read(stableRoot.appendingPathComponent("settings.json"))
        let devStore = try RegistryStore(applicationSupport: f.support, channel: .development)
        #expect(try devStore.load().isEmpty)
        try devStore.save([profile])
        let devRoot = try dev.prepare(profile)
        #expect(devRoot != stableRoot)
        #expect(!stable.matchesRoot(devRoot, profile: profile))
        #expect(!dev.matchesRoot(stableRoot, profile: profile))
        let stableLock = try #require(try ManagerInstanceLock.acquire(in: stable.directory))
        let devLock = try #require(try ManagerInstanceLock.acquire(in: dev.directory))
        defer { withExtendedLifetime((stableLock, devLock)) {} }
        #expect(try ManagerInstanceLock.acquire(in: stable.directory) == nil)
        #expect(try ManagerInstanceLock.acquire(in: dev.directory) == nil)
        let identity = try dev.deletionIdentity(profile)
        try dev.trash(profile, expectedIdentity: identity) { root in
            #expect(root.path == devRoot.path)
            try FileManager.default.moveItem(at: root, to: f.support.appendingPathComponent("simulated-trash"))
        }
        #expect(try PrivateFiles.read(stableRoot.appendingPathComponent("settings.json")) == beforeSettings)
        #expect(try PrivateFiles.read(stable.directory.appendingPathComponent("registry.json")) == beforeRegistry)
        try stableStore.checkRevision()
    }

    @Test("Dev commands fail when only stable is serving; stopping Dev's server leaves stable available")
    func commandIsolation() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let stable = ManagerCommandEndpoint(applicationSupport: f.support, channel: .stable)
        let dev = ManagerCommandEndpoint(applicationSupport: f.support, channel: .development)
        defer {
            try? FileManager.default.removeItem(at: stable.directory)
            try? FileManager.default.removeItem(at: dev.directory)
        }
        let server = try ManagerCommandServer(endpoint: stable) {
            GuestCommandResponse(requestID: $0.requestID, ok: false, error: GuestCommandFailure(code: "stable-fixture", message: "fixture"))
        }
        defer { server.stop() }
        #expect(stable.socket != dev.socket)
        #expect(throws: VMFailure.self) { try ManagerCommandClient(endpoint: dev).send(GuestCommandRequest(command: .list)) }
        let devServer = try ManagerCommandServer(endpoint: dev) {
            GuestCommandResponse(requestID: $0.requestID, ok: false, error: GuestCommandFailure(code: "dev-fixture", message: "fixture"))
        }
        for (endpoint, expected) in [(stable, "stable-fixture"), (dev, "dev-fixture")] {
            let response = try await Task.detached { try ManagerCommandClient(endpoint: endpoint).send(GuestCommandRequest(command: .list)) }.value
            #expect(response.error?.code == expected)
        }
        devServer.stop()
        let response = try await Task.detached { try ManagerCommandClient(endpoint: stable).send(GuestCommandRequest(command: .list)) }.value
        #expect(response.error?.code == "stable-fixture")
    }

    @Test("Dev starts with empty defaults and edits preserve stable defaults")
    func defaultsIsolation() throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let stable = OwnerDefaultsStore(applicationSupport: f.support, vault: MemoryOwnerVault(), channel: .stable)
        _ = try stable.save(configuration: OwnerConfiguration(username: "work"), password: Data("synthetic-password".utf8))
        let stableFile = AppChannel.stable.directory(in: f.support).appendingPathComponent("guest-defaults.json")
        let before = try PrivateFiles.read(stableFile)
        let dev = OwnerDefaultsStore(applicationSupport: f.support, vault: MemoryOwnerVault(), channel: .development)
        #expect(try !dev.load().enabled)
        _ = try dev.save(configuration: OwnerConfiguration(username: "testing"), password: Data("synthetic-dev-password".utf8))
        #expect(try PrivateFiles.read(stableFile) == before)
        let stableDisks = DiskDefaultsStore(applicationSupport: f.support, channel: .stable)
        let devDisks = DiskDefaultsStore(applicationSupport: f.support, channel: .development)
        var disks = DiskDefaults(); disks.systemDiskGiB = 128
        try stableDisks.save(disks)
        #expect(try devDisks.load().systemDiskGiB == 64)
        var devSettings = DiskDefaults(); devSettings.systemDiskGiB = 256
        try devDisks.save(devSettings)
        #expect(try stableDisks.load().systemDiskGiB == 128)
    }

    @Test("mismatched app identities and old Dev runtimes fail closed")
    func identities() throws {
        for channel in AppChannel.allCases {
            try channel.validateBundle(identifier: channel.bundleIdentifier)
            for identifier in [nil, "unknown", channel == .stable ? AppChannel.development.bundleIdentifier : AppChannel.stable.bundleIdentifier] {
                #expect(throws: VMFailure.self) { try channel.validateBundle(identifier: identifier) }
            }
        }
        try AppChannel.stable.validateRuntimeChannels(nil)
        try AppChannel.development.validateRuntimeChannels(1)
        #expect(throws: VMFailure.self) { try AppChannel.development.validateRuntimeChannels(nil) }
        #expect(throws: VMFailure.self) { try AppChannel.development.validateRuntimeChannels(2) }
        #expect(AppChannel.development.guestName(String(repeating: "界", count: 64)).count == 64)
    }

    @Test("Dev display branding preserves the runtime's character, byte and whitespace limits")
    func longGuestNames() throws {
        let names = [String(repeating: "界", count: 64), String(repeating: "a", count: 57) + "      B",
                     "a" + String(repeating: "\u{0301}", count: 125)]
        for name in names {
            let profile = VMProfile(id: UUID(), name: name)
            try RegistryStore.validate(profile)
            let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(profile.id.uuidString)
            let configuration = try TryOmarchyRuntime.configuration(for: VMStartRequest(profile: profile, storageRoot: root), guestIcon: nil)
            try configuration.validate()
            #expect(configuration.productName == AppChannel.current.guestName(name))
            #expect(AppChannel.stable.guestName(name) == name)
        }
    }
}
