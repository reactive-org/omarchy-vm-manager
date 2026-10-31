import Darwin
import Foundation
import Testing
@testable import OmarchyVMManagerCore

@Suite("Private same-user command transport")
struct CommandSocketTests {
    @Test("bounded requests round-trip with matching IDs and private socket permissions")
    func roundTrip() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let endpoint = ManagerCommandEndpoint(directory: f.support.appendingPathComponent("ipc"))
        let manager = VMManager(runtime: FakeRuntime(), profiles: [], applicationSupport: f.support)
        let service = GuestCommandService(manager: manager, applicationSupport: f.support)
        let server = try ManagerCommandServer(endpoint: endpoint) { await service.execute($0) }; defer { server.stop() }
        var info = stat(); #expect(lstat(endpoint.socket.path, &info) == 0 && info.st_mode & 0o7777 == 0o600)
        #expect(lstat(endpoint.directory.path, &info) == 0 && info.st_mode & 0o7777 == 0o700)
        let client = ManagerCommandClient(endpoint: endpoint)
        for _ in 0..<30 {
            let request = GuestCommandRequest(command: .list)
            let response = try await Task.detached { try client.send(request) }.value
            #expect(response.ok && response.requestID == request.requestID && response.guests?.isEmpty == true)
        }
        #expect(throws: VMFailure.self) { try ManagerCommandServer(endpoint: endpoint) { await service.execute($0) } }
        let request = GuestCommandRequest(command: .list)
        #expect(try await Task.detached { try client.send(request) }.value.ok)
    }
    @Test("unsafe or symlinked endpoints are refused without overwriting them")
    func unsafe() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let endpoint = ManagerCommandEndpoint(directory: f.support.appendingPathComponent("ipc"))
        try PrivateFiles.directory(endpoint.directory, create: true)
        try PrivateFiles.write(Data("preserve".utf8), name: "control.sock", in: endpoint.directory)
        let client = ManagerCommandClient(endpoint: endpoint)
        #expect(throws: VMFailure.self) { try client.send(GuestCommandRequest(command: .list)) }
        #expect(throws: VMFailure.self) { try ManagerCommandServer(endpoint: endpoint) { GuestCommandResponse(requestID: $0.requestID, ok: true) } }
        #expect(try PrivateFiles.read(endpoint.socket) == Data("preserve".utf8))
        let linked = f.support.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: endpoint.directory)
        #expect(throws: VMFailure.self) { try ManagerCommandServer(endpoint: ManagerCommandEndpoint(directory: linked)) { GuestCommandResponse(requestID: $0.requestID, ok: true) } }
    }
    @Test("client disconnect cancels a waiter while the lifecycle owner keeps the guest")
    func disconnect() async throws {
        let f = try RegistryFixture(); defer { f.cleanup() }
        let runtime = FakeRuntime()
        let profile = f.profile()
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: f.support)
        try await manager.start(profile.id)
        let service = GuestCommandService(manager: manager, applicationSupport: f.support)
        let endpoint = ManagerCommandEndpoint(directory: f.support.appendingPathComponent("ipc"))
        let server = try ManagerCommandServer(endpoint: endpoint) { await service.execute($0) }; defer { server.stop() }
        var request = GuestCommandRequest(command: .wait, selector: profile.id.uuidString); request.waitFor = .running
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); #expect(fd >= 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(endpoint.socket.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(connected == 0)
        let data = try JSONEncoder().encode(request) + Data([10])
        _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        Darwin.close(fd)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await manager.activeSessionCount == 1)
        #expect(runtime.startedHandles[0].shutdownCount == 0 && runtime.startedHandles[0].terminationCount == 0)
        runtime.startedHandles[0].emit(.exited(status: 0))
        #expect(await eventually { await manager.activeSessionCount == 0 })
    }
    @Test("unknown schemas and fields cannot reach the command handler")
    func strictRequests() throws {
        var request = GuestCommandRequest(command: .list)
        request.version = 2
        #expect(throws: VMFailure.self) { try GuestCommandRequest.decodeStrict(JSONEncoder().encode(request)) }
        request.version = 1
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        object["storageRoot"] = "/outside"
        #expect(throws: VMFailure.self) { try GuestCommandRequest.decodeStrict(JSONSerialization.data(withJSONObject: object)) }
    }
}
