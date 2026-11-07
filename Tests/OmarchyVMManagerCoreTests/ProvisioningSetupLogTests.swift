import Darwin
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private actor ScriptedTerminal: ProvisioningTerminalReading {
    enum Step { case frame(String, interactive: Bool = false), gap, busy, empty }
    private var steps: [Step]
    private(set) var detached = false
    private(set) var resets = 0
    private var sequence: UInt64 = 0
    init(_ steps: [Step]) { self.steps = steps }
    private func page(_ text: String? = nil, reset: Bool = false, interactive: Bool = false) -> ProvisioningTerminalPage {
        var frames: [ProvisioningTerminalBytes] = []
        if let text { sequence += 1; frames = [.init(sequence: sequence, invocationID: UUID(), channel: "stdout", bytes: Data(text.utf8))] }
        return .init(frames: frames, sequence: sequence, resetRequired: reset, activeInvocationID: nil, acceptsInput: interactive, ownsInput: false)
    }
    func poll() async throws -> ProvisioningTerminalPage {
        guard !steps.isEmpty else { return page() }
        switch steps.removeFirst() {
        case .frame(let text, let interactive): return page(text, interactive: interactive)
        case .gap: return page(reset: true)
        case .busy: throw ProvisioningTerminalDenial.busy
        case .empty: return page()
        }
    }
    func acknowledgeReset() async throws -> ProvisioningTerminalPage { resets += 1; return page() }
    func detach() async { detached = true }
}

@Suite("Saved setup log — disposable temp roots only")
struct ProvisioningSetupLogTests {
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/setup-log-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func text(_ root: URL) throws -> String { String(decoding: try ProvisioningSetupLog.read(root: root) ?? Data(), as: UTF8.self) }

    @Test func applyReplacesCheckAppendsWithPrivateModes() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try ProvisioningSetupLogWriter(root: root, replace: true, header: "run one")
        first.append(Data("old output".utf8)); first.finish("setup failed")
        let apply = try ProvisioningSetupLogWriter(root: root, replace: true, header: "run two")
        apply.append(Data("apply output".utf8)); apply.finish("setup restartRequired")
        let check = try ProvisioningSetupLogWriter(root: root, replace: false, header: "check")
        check.append(Data("check output".utf8)); check.finish("setup checked")
        let saved = try text(root)
        #expect(!saved.contains("old output") && saved.contains("apply output") && saved.contains("check output"))
        var info = stat()
        #expect(stat(ProvisioningSetupLog.directory(root: root).path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        #expect(stat(ProvisioningSetupLog.file(root: root).path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }

    @Test func missingRootIsNeverCreated() throws {
        let missing = URL(fileURLWithPath: "/private/tmp/setup-log-missing-" + UUID().uuidString)
        #expect(throws: ProvisioningSetupLogFailure.rootMissing) { try ProvisioningSetupLogWriter(root: missing, replace: true, header: "x") }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(try ProvisioningSetupLog.read(root: missing) == nil)
    }

    @Test func boundedHeadAndTailWithOmissionMarker() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = try ProvisioningSetupLogWriter(root: root, replace: true, header: "big")
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 65_536)
        for _ in 0..<80 { writer.append(chunk) }
        writer.append(Data("FINAL ERROR LINE".utf8)); writer.finish("setup failed")
        let data = try #require(try ProvisioningSetupLog.read(root: root))
        let saved = String(decoding: data, as: UTF8.self)
        #expect(data.count <= ProvisioningSetupLog.maximumBytes)
        #expect(saved.contains("bytes of output omitted") && saved.contains("FINAL ERROR LINE") && saved.hasSuffix("[setup failed]\r\n"))
    }

    @Test func readerRefusesLinksAndSharedFiles() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = try ProvisioningSetupLogWriter(root: root, replace: true, header: "h"); writer.finish("done")
        let file = ProvisioningSetupLog.file(root: root)
        chmod(file.path, 0o644)
        #expect(throws: ProvisioningSetupLogFailure.unsafe) { try ProvisioningSetupLog.read(root: root) }
        chmod(file.path, 0o600); unlink(file.path)
        symlink("/etc/hosts", file.path)
        #expect(throws: ProvisioningSetupLogFailure.unsafe) { try ProvisioningSetupLog.read(root: root) }
    }

    @Test func recorderSavesOutputMarksGapsAndOmitsInteractiveSections() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let terminal = ScriptedTerminal([.frame("first "), .busy, .frame("second "), .gap, .frame("typed-secret-echo", interactive: true), .frame("after "), .empty, .frame("tail line")])
        let recorder = ProvisioningSetupRecorder(reader: terminal, writer: try ProvisioningSetupLogWriter(root: root, replace: true, header: "apply"))
        await recorder.start()
        try await Task.sleep(for: .milliseconds(300))
        await recorder.finish(result: "failed")
        let saved = try text(root)
        #expect(saved.contains("first ") && saved.contains("second ") && saved.contains("after ") && saved.contains("tail line"))
        #expect(saved.contains("output gap") && saved.contains("interactive section omitted"))
        #expect(!saved.contains("typed-secret-echo"))
        #expect(saved.hasSuffix("[setup failed]\r\n"))
        let detached = await terminal.detached, resets = await terminal.resets
        #expect(detached && resets == 1)
    }

    @Test func abortMarksTheFile() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let terminal = ScriptedTerminal([.frame("partial")])
        let recorder = ProvisioningSetupRecorder(reader: terminal, writer: try ProvisioningSetupLogWriter(root: root, replace: true, header: "apply"))
        await recorder.start(); try await Task.sleep(for: .milliseconds(100))
        await recorder.abort()
        #expect(try text(root).contains("recording ended early"))
    }
}
