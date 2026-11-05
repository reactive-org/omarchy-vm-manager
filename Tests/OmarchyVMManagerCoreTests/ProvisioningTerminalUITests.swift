import AppKit
import Darwin
@testable import DevVMProvisioningCore
import Foundation
import OmarchyProvisioningTerminalUI
@testable import OmarchyVMManagerCore
import Testing

private struct TerminalUIFixtureService: ProvisioningObserving {
    let client: ProvisioningTerminalClient
    var executionEnabled: Bool { false }
    func statuses() async -> [ProvisioningWorkflowSnapshot] { [] }
    func status(_ id: UUID) async -> ProvisioningWorkflowSnapshot? { nil }
    func jobStatus(_ id: UUID) async -> ProvisioningJobSnapshot? { nil }
    func cancel(_ id: UUID) async throws { throw ProvisioningServiceFailure.disabled }
    func attachTerminal(_ id: UUID) async throws -> ProvisioningTerminalAttachment {
        try await .attach(client: client)
    }
}

@Suite("Provisioning terminal UI — fake terminal and local socket only", .serialized)
@MainActor struct ProvisioningTerminalUITests {
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
        guard condition() else { throw ProvisioningTerminalDenial.unavailable }
    }
    private func click(_ screen: ProvisioningTerminalScreen) throws {
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 10, y: 10),
            modifierFlags: [], timestamp: 0, windowNumber: screen.view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        screen.view.mouseDown(with: event)
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: event.locationInWindow,
            modifierFlags: [], timestamp: 0, windowNumber: event.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        screen.view.mouseUp(with: up)
    }
    @Test func clickClaimsInputWithoutStealingAndRequiresFreshClickAfterRelease() async throws {
        _ = NSApplication.shared
        let f = try TerminalFixture(lifetime: .seconds(15)), credentials = try terminalCredentials(), (parent, child) = try sessionFixtureSockets()
        let server = ProvisioningTerminalServer(socket: child, credentials: credentials, hub: f.hub)
        let serving = Task { await server.serve() }
        let client = ProvisioningTerminalClient(socket: parent, credentials: credentials, jobID: f.request.jobID)
        defer { client.disconnect(); serving.cancel() }
        let service = TerminalUIFixtureService(client: client)
        let invocation = try f.invocation() // Never executed: the fake terminal only exposes its typed state.
        let initial = try f.terminal.begin(invocation)
        #expect(initial.rows == 30 && initial.columns == 120)
        let first = ProvisioningTerminalScreen(), second = ProvisioningTerminalScreen()
        await first.attach(service: service, workflowID: f.request.jobID)
        await second.attach(service: service, workflowID: f.request.jobID)
        #expect(first.connected && second.connected)
        #expect(first.follow && second.follow && !first.ownsInput && !second.ownsInput)
        first.scrolled(source: first.view, position: 0)
        #expect(first.follow) // Output/resize scroll notifications cannot disable the default.
        try click(first)
        try await wait { first.ownsInput && first.acceptsInput }
        var master: Int32 = -1, slave: Int32 = -1
        try #require(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { close(master); close(slave) }
        #expect(fcntl(slave, F_SETFL, O_NONBLOCK) == 0)
        first.send(source: first.view, data: Array("x".utf8)[...])
        var received = false
        try await wait {
            _ = f.terminal.flushInput(invocation.id, fd: master)
            var byte: UInt8 = 0
            if read(slave, &byte, 1) == 1 { received = byte == 120 }
            return received
        }

        try click(second)
        try await wait { second.message.contains("refused") }
        #expect(!second.ownsInput && first.ownsInput)
        await first.releaseInput()
        #expect(!first.ownsInput)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!second.ownsInput) // No automatic retry or ownership transfer.
        try click(second)
        try await wait { second.ownsInput && second.acceptsInput }
        await first.detach(); await second.detach()
        #expect(!f.terminal.snapshot().acceptsInput)
        f.terminal.end(invocation.id)
        client.disconnect(); await serving.value
    }
}
