import AppKit
import Darwin
@testable import DevVMProvisioningCore
import Foundation
@testable import OmarchyProvisioningTerminalUI
@testable import OmarchyVMManagerCore
import SwiftTerm
import Testing

private final class DisplayDelegate: TerminalDelegate {
    var actions = 0
    func send(source: Terminal, data: ArraySlice<UInt8>) { actions += 1 }
    func clipboardCopy(source: Terminal, content: Data) { actions += 1 }
    func setTerminalTitle(source: Terminal, title: String) { actions += 1 }
    func hostCurrentDirectoryUpdate(source: Terminal, directory: String?) { actions += 1 }
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { actions += 1; return nil }
}
private actor SurfaceService: ProvisioningObserving {
    nonisolated let executionEnabled = false
    let f: TerminalFixture
    let client: ProvisioningTerminalClient
    var cancellations = 0
    init(_ f: TerminalFixture, client: ProvisioningTerminalClient) { self.f = f; self.client = client }
    func statuses() -> [ProvisioningWorkflowSnapshot] { [snapshot()] }
    func status(_ id: UUID) -> ProvisioningWorkflowSnapshot? { id == f.request.jobID ? snapshot() : nil }
    func jobStatus(_ id: UUID) -> ProvisioningJobSnapshot? { nil }
    func snapshot() -> ProvisioningWorkflowSnapshot {
        .init(id: f.request.jobID, vmID: f.request.target.vmID, originalSessionID: f.request.target.sessionID,
              sequence: UInt64(cancellations + 1), stage: cancellations == 0 ? .running : .cancelled,
              cleanupRequired: false, failure: nil, applyJobID: f.request.jobID, checkJobID: nil, restartID: nil, newSessionID: nil)
    }
    func cancel(_ id: UUID) async throws {
        guard id == f.request.jobID else { throw ProvisioningServiceFailure.unknownWorkflow }
        cancellations += 1; await f.hub.finish()
    }
    func attachTerminal(_ id: UUID) async throws -> ProvisioningTerminalAttachment {
        guard id == f.request.jobID else { throw ProvisioningServiceFailure.unknownWorkflow }
        return try await .attach(client: client)
    }
}
private final class SurfaceFixture {
    let f: TerminalFixture
    let service: SurfaceService
    let terminalClient: ProvisioningTerminalClient
    let server: ProvisioningTerminalServer
    let task: Task<Void, Never>
    let endpoint: ManagerCommandEndpoint
    init(capacity: Int = 256 * 1024) throws {
        f = try TerminalFixture(capacity: capacity)
        let credentials = try terminalCredentials(), (parent, child) = try sessionFixtureSockets()
        server = ProvisioningTerminalServer(socket: child, credentials: credentials, hub: f.hub)
        let server = server
        task = Task { await server.serve() }
        terminalClient = .init(socket: parent, credentials: credentials, jobID: f.request.jobID)
        service = .init(f, client: terminalClient)
        endpoint = .init(directory: f.root.appendingPathComponent("ipc"))
    }
    deinit { server.stop(); terminalClient.disconnect(); task.cancel() }
}

@MainActor private func surfaceEventually(_ predicate: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if predicate() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
    }
    return false
}

@Suite("Provisioning UI and CLI surfaces", .serialized) struct ProvisioningSurfaceTests {
    @Test func incrementalDisplayAllowsPresentationAndDropsEveryHostAction() {
        let safe = "\u{1b}[32mready €雪🙂\u{1b}[0m\rnext\n\u{1b}[2K\u{1b}[1;3H\u{1b}[?25l\u{1b}[?1049h"
        let hostile = "\u{1b}]52;c;c3ludGhldGljLXNlY3JldA==\u{7}\u{1b}]0;title\u{1b}\\\u{1b}]8;;https://example.invalid\u{7}\u{1b}]1337;File=payload\u{7}\u{1b}PqPAYLOAD\u{1b}\\\u{1b}_APC\u{1b}\\\u{1b}^PM\u{1b}\\\u{1b}[8;999;999t\u{1b}[6n\u{1b}[?1003h\u{7}"
        let bytes = Data((safe + hostile).utf8)
        for width in [1, 2, 3, 7, bytes.count] {
            var display = ProvisioningTerminalDisplay(), output = Data()
            for start in stride(from: 0, to: bytes.count, by: width) { output += display.consume(bytes.subdata(in: start..<min(start + width, bytes.count))) }
            #expect(output == Data(safe.utf8))
            #expect(!String(reflecting: display).contains("synthetic"))
        }
    }
    @Test func boundedMalformedStringsCSIAndUTF8CannotSmuggleHostEscapes() {
        var display = ProvisioningTerminalDisplay()
        #expect(display.consume(Data("\u{1b}]52;c;".utf8)).isEmpty)
        #expect(display.consume(Data(repeating: 65, count: 1_048_576)).isEmpty)
        #expect(display.consume(Data("\u{1b}\\tail".utf8)) == Data("tail".utf8))
        #expect(display.consume(Data(("\u{1b}[" + String(repeating: "9", count: 4096) + "mX").utf8)) == Data("X".utf8))
        #expect(display.consume(Data([0x9d, 65, 66, 0x9c, 67])) == Data([67]))
        _ = display.consume(Data([0xe2, 0x82])); display.reset()
        #expect(display.consume(Data([0xac, 65])) == Data([65]))
        #expect(display.consume(Data([0xc2, 0x9b])) == Data())
    }
    @Test func emulatorReceivesCursorColoursAndCarriageReturnWithoutHostActions() {
        let delegate = DisplayDelegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 24, scrollback: 500, enableSixelReported: false))
        terminal.silentLog = true
        var filter = ProvisioningTerminalDisplay()
        let data = Data("\u{1b}[32malpha\u{1b}[0m\rB\u{1b}]52;c;AA==\u{7}\u{1b}[6n".utf8)
        for byte in data { terminal.feed(buffer: Array(filter.consume(Data([byte])))[...]) }
        #expect(terminal.getLine(row: 0)?.translateToString(trimRight: true) == "Blpha")
        #expect(delegate.actions == 0)
        for _ in 0..<2000 { terminal.feed(text: "bounded\r\n") }
        #expect(terminal.getBufferAsData().count < 80 * 600)
    }
    @Test func rendererClusterBoundSurvivesCursorAndStyleChanges() {
        let delegate = DisplayDelegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 24, scrollback: 500))
        terminal.silentLog = true
        var display = ProvisioningTerminalDisplay()
        terminal.feed(text: "a")
        for _ in 0..<256 {
            let bytes = display.consume(Data("\u{1b}[2G\u{1b}[31m\u{301}".utf8))
            terminal.feed(buffer: Array(bytes)[...])
        }
        let text = terminal.getLine(row: 0)?.translateToString(trimRight: true) ?? ""
        #expect(text.unicodeScalars.count <= 16)
        #expect(delegate.actions == 0)
    }
    @Test @MainActor func nativeScreenSupportsSearchFontFollowAndResetWithoutOpeningAWindow() {
        _ = NSApplication.shared
        let screen = ProvisioningTerminalScreen()
        for byte in Data("\u{1b}[32mcolour €\u{1b}[0m\r\nsearchable\r\n".utf8) { screen.render(Data([byte])) }
        #expect(screen.view.getBufferAsData().contains(Data("colour €".utf8)))
        #expect(screen.search("SEARCHABLE") == 1 && !screen.follow)
        screen.jumpToLatest(); #expect(screen.follow)
        screen.fontSize = 18; #expect(screen.view.font.pointSize == 18)
        screen.resetScreen(); #expect(screen.search("searchable") == 0)
        #expect(!screen.connected && !screen.ownsInput)
    }
    @Test(arguments: ["duplicate", "unknown", "null", "version", "input", "dimension", "sequence", "operation"])
    func externalProtocolRejectsMalformedMessages(kind: String) throws {
        let request = ProvisioningExternalRequest(sequence: 1, operation: .status, workflowID: UUID())
        let data = try helperJSON(request)
        if kind == "duplicate" {
            let text = String(decoding: data, as: UTF8.self).dropLast() + ",\"version\":1}"
            #expect(throws: (any Error).self) { _ = try ProvisioningExternalRequest.decode(Data(text.utf8)) }; return
        }
        var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        switch kind {
        case "unknown": document["argv"] = []
        case "null": document["workflowID"] = NSNull()
        case "version": document["version"] = 2
        case "input": document["operation"] = "input"; document["invocationID"] = UUID().uuidString; document["bytes"] = Data(repeating: 65, count: 4097).base64EncodedString()
        case "dimension": document["operation"] = "claim"; document["rows"] = 501; document["columns"] = 80
        case "sequence": document["sequence"] = 0
        default: document["operation"] = "exec"
        }
        #expect(throws: (any Error).self) { _ = try ProvisioningExternalRequest.decode(JSONSerialization.data(withJSONObject: document)) }
    }
    @Test @MainActor func nativeViewerClaimsRendersReleasesAndDetachesWithoutCancelling() async throws {
        let f = try SurfaceFixture(), invocation = try f.f.invocation()
        _ = try f.f.terminal.begin(invocation)
        _ = NSApplication.shared
        let screen = ProvisioningTerminalScreen()
        await screen.attach(service: f.service, workflowID: f.f.request.jobID)
        #expect(screen.connected && !screen.ownsInput)
        await screen.takeInput()
        #expect(await surfaceEventually { screen.ownsInput && screen.acceptsInput })
        let payload = Data("native-real-fixture-output\u{1b}[32m €\u{1b}[0m".utf8)
        f.f.terminal.publish(invocation.id, channel: .pty, bytes: payload)
        #expect(await surfaceEventually { screen.view.getBufferAsData().contains(Data("native-real-fixture-output".utf8)) })
        screen.send(source: screen.view, data: Array("synthetic-native-keystrokes".utf8)[...])
        await screen.releaseInput()
        #expect(!screen.ownsInput)
        #expect(await surfaceEventually { !f.f.terminal.snapshot().acceptsInput })
        #expect(!screen.view.getBufferAsData().contains(Data("synthetic-native-keystrokes".utf8)))
        await screen.detach()
        #expect(!screen.connected && !screen.ownsInput)
        #expect(await f.service.cancellations == 0)
        #expect(f.f.terminal.snapshot().activeInvocationID == invocation.id)
        f.f.terminal.end(invocation.id)
    }
    @Test(arguments: ["null", "unknown", "correlation", "version", "sequence", "workflow", "nested", "failure"])
    func externalReplyCannotSmuggleUnknownOrMismatchedState(kind: String) throws {
        let request = ProvisioningExternalRequest(sequence: 1, operation: .capabilities)
        var reply = ProvisioningExternalReply(request); reply.executionEnabled = false
        var document = try #require(JSONSerialization.jsonObject(with: helperJSON(reply)) as? [String: Any])
        switch kind {
        case "null": document["executionEnabled"] = NSNull()
        case "unknown": document["token"] = "forbidden"
        case "correlation": document["requestID"] = UUID().uuidString
        case "version": document["version"] = 2
        case "sequence": document["sequence"] = 2
        case "workflow": document["workflows"] = []
        case "nested": document["page"] = ["bytes": "forbidden"]
        default: document["failure"] = "arbitrary diagnostic or credential"
        }
        #expect(throws: (any Error).self) { _ = try ProvisioningExternalReply.decode(JSONSerialization.data(withJSONObject: document), request: request) }
    }
    @Test func externalSocketAndNativeAttachmentShareOwnershipAndDetachIsNotCancel() async throws {
        let f = try SurfaceFixture()
        let server = try ProvisioningExternalServer(endpoint: f.endpoint, service: f.service); defer { server.stop() }
        let client = ProvisioningExternalClient(endpoint: f.endpoint)
        let id = f.f.request.jobID, invocation = try f.f.invocation()
        _ = try f.f.terminal.begin(invocation)
        #expect(try await client.request(.capabilities).executionEnabled == false)
        #expect(try await client.request(.status, workflowID: id).workflows?.first?.id == id)
        #expect(try await client.request(.attach, workflowID: id).failure == nil)
        #expect(try await client.request(.read, workflowID: id).page?.ownsInput == false)
        #expect(try await client.request(.claim, workflowID: id, rows: 32, columns: 100).failure == nil)
        let native = try await f.service.attachTerminal(id)
        do { try await native.claimInput(rows: 24, columns: 80); Issue.record("Second viewer took existing input") } catch { }
        let raw = Data("\u{1b}[32mactual-fixture €\u{1b}[0m\r\n".utf8)
        f.f.terminal.publish(invocation.id, channel: .pty, bytes: raw)
        #expect(try await client.request(.read, workflowID: id).page?.frames.first?.bytes == raw)
        #expect(try await client.request(.input, workflowID: id, invocationID: invocation.id, bytes: Data("synthetic-password\n".utf8)).failure == nil)
        #expect(try await client.request(.input, workflowID: UUID(), invocationID: invocation.id, bytes: Data([10])).failure == "denied")
        #expect(try await client.request(.detach, workflowID: id).failure == nil)
        try await native.claimInput(rows: 40, columns: 120)
        #expect(try await native.poll().ownsInput)
        #expect(await f.service.cancellations == 0)
        await native.detach(); await client.close()
        #expect(f.f.terminal.snapshot().activeInvocationID == invocation.id)
        let cancel = ProvisioningExternalClient(endpoint: f.endpoint)
        #expect(try await cancel.request(.cancel, workflowID: id).workflows?.first?.stage == .cancelled)
        #expect(await f.service.cancellations == 1)
        await cancel.close(); f.f.terminal.end(invocation.id)
    }
    @Test func connectionLossRevokesOnlyThatViewerAndGapsRequireExplicitReset() async throws {
        let f = try SurfaceFixture(capacity: 8192)
        let server = try ProvisioningExternalServer(endpoint: f.endpoint, service: f.service); defer { server.stop() }
        let client = ProvisioningExternalClient(endpoint: f.endpoint)
        let id = f.f.request.jobID, invocation = try f.f.invocation(); _ = try f.f.terminal.begin(invocation)
        _ = try await client.request(.attach, workflowID: id)
        _ = try await client.request(.claim, workflowID: id, rows: 24, columns: 80)
        for _ in 0..<3 { f.f.terminal.publish(invocation.id, channel: .pty, bytes: Data(repeating: 65, count: 8192)) }
        #expect(try await client.request(.read, workflowID: id).page?.resetRequired == true)
        #expect(try await client.request(.claim, workflowID: id, rows: 24, columns: 80).failure == "denied")
        #expect(try await client.request(.reset, workflowID: id).page?.ownsInput == false)
        #expect(try await client.request(.claim, workflowID: id, rows: 24, columns: 80).failure == nil)
        await client.close()
        #expect(await eventually { !f.f.terminal.snapshot().acceptsInput })
        #expect(await f.service.cancellations == 0)
        let second = ProvisioningExternalClient(endpoint: f.endpoint)
        _ = try await second.request(.attach, workflowID: id)
        #expect(try await second.request(.read, workflowID: id).page?.ownsInput == false)
        await second.close(); f.f.terminal.end(invocation.id)
    }
    @Test func connectionReplayAndSecondListenerAreRefused() async throws {
        let f = try SurfaceFixture()
        let session = ProvisioningExternalSession(service: f.service)
        let request = ProvisioningExternalRequest(sequence: 1, operation: .list)
        _ = try await session.handle(request)
        do { _ = try await session.handle(request); Issue.record("Replayed request accepted") } catch { }
        await session.close()
        let server = try ProvisioningExternalServer(endpoint: f.endpoint, service: f.service); defer { server.stop() }
        #expect(throws: (any Error).self) { _ = try ProvisioningExternalServer(endpoint: f.endpoint, service: f.service) }
        var info = stat(); #expect(lstat(f.endpoint.provisioning.socket.path, &info) == 0 && info.st_mode & 0o7777 == 0o600)
        #expect(f.endpoint.socket != f.endpoint.provisioning.socket)
    }
    @Test(arguments: ["detach", "disconnect", "cancel-task"])
    func cliAttachmentRestoresDisposableTTYAndNeverEchoesInput(kind: String) async throws {
        let f = try SurfaceFixture()
        let server = try ProvisioningExternalServer(endpoint: f.endpoint, service: f.service); defer { server.stop() }
        let client = ProvisioningExternalClient(endpoint: f.endpoint), id = f.f.request.jobID
        let invocation = try f.f.invocation(); _ = try f.f.terminal.begin(invocation)
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw ProvisioningTerminalDenial.unavailable }
        defer { close(master); close(slave); f.f.terminal.end(invocation.id) }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        var before = termios(); #expect(tcgetattr(slave, &before) == 0)
        let descriptor = slave, beforeFlags = fcntl(slave, F_GETFL)
        var signalBefore = sigaction(); #expect(sigaction(SIGTERM, nil, &signalBefore) == 0)
        let task = Task { () -> Bool in
            do { try await ProvisioningCLITerminal.attach(client: client, workflowID: id, interactive: true, input: descriptor, output: descriptor); return true }
            catch { return false }
        }
        #expect(await eventually {
            var raw = termios()
            return tcgetattr(descriptor, &raw) == 0 && raw.c_lflag & tcflag_t(ECHO | ICANON) == 0
        })
        let secret = Data("synthetic-local-typing-canary".utf8)
        _ = secret.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        f.f.terminal.publish(invocation.id, channel: .pty, bytes: Data("actual-colour-output\u{1b}[32m €\u{1b}[0m".utf8))
        try await Task.sleep(for: .milliseconds(100))
        if kind == "disconnect" { server.stop() }
        else if kind == "cancel-task" { task.cancel() }
        else { var key: UInt8 = 29; _ = Darwin.write(master, &key, 1) }
        let completed = await task.value
        if kind == "detach" { #expect(completed) }
        // XNU sets the kernel-only FWASWRITTEN bit after the first write.
        // Preserve every user flag, excluding only that observed status bit.
        // https://github.com/apple/darwin-xnu/blob/main/bsd/sys/fcntl.h
        #expect(fcntl(slave, F_GETFL) & ~Int32(0x00010000) == beforeFlags & ~Int32(0x00010000))
        var signalAfter = sigaction(); #expect(sigaction(SIGTERM, nil, &signalAfter) == 0)
        #expect(signalAfter.sa_mask == signalBefore.sa_mask && signalAfter.sa_flags == signalBefore.sa_flags)
        #expect(withUnsafeBytes(of: signalAfter.__sigaction_u) { Data($0) } == withUnsafeBytes(of: signalBefore.__sigaction_u) { Data($0) })
        var after = termios(); #expect(tcgetattr(slave, &after) == 0)
        #expect(before.c_iflag == after.c_iflag && before.c_oflag == after.c_oflag && before.c_cflag == after.c_cflag)
        #expect(before.c_lflag & ~tcflag_t(PENDIN) == after.c_lflag & ~tcflag_t(PENDIN))
        #expect(withUnsafeBytes(of: before.c_cc) { Data($0) } == withUnsafeBytes(of: after.c_cc) { Data($0) })
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<16 {
            let count = Darwin.read(master, &buffer, buffer.count)
            if count <= 0 { break }; output.append(contentsOf: buffer.prefix(count))
        }
        #expect(!output.contains(secret))
        #expect(output.contains(Data("actual-colour-output".utf8)))
        #expect(await f.service.cancellations == 0)
        #expect(await eventually { !f.f.terminal.snapshot().acceptsInput })
    }
    @Test func cliSelectionIsOfflineAndExecutionCommandsAreGated() throws {
        #expect(try ProvisioningSetupCLI.parse(["list"]) == nil)
        #expect(try ProvisioningSetupCLI.parse(["setup", "tools"]) == nil)
        if case .attach(_, let interactive) = try ProvisioningSetupCLI.parse(["setup", "attach", UUID().uuidString]) { #expect(!interactive) } else { Issue.record("Missing attachment") }
        if case .preset(let name) = try ProvisioningSetupCLI.parse(["setup", "plan", "--preset", "project-managed"]) { #expect(name == "project-managed") } else { Issue.record("Missing preset") }
        for args in [["setup", "apply", "guest"], ["setup", "check", "guest"], ["setup", "recover", "guest"], ["setup", "attach", UUID().uuidString, "--password", "never"], ["setup", "plan", "--from", "relative"]] {
            #expect(throws: VMFailure.self) { _ = try ProvisioningSetupCLI.parse(args) }
        }
    }
}
