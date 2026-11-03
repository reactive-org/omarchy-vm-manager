import AppKit
import OmarchyVMManagerCore
import SwiftUI
import SwiftTerm

/// UI owns only a viewer. Output stays in the bounded emulator; no output mirror,
/// log, restoration archive or automatic input queue. All work runs on MainActor.
@MainActor public final class ProvisioningTerminalScreen: NSObject, ObservableObject, @preconcurrency TerminalViewDelegate {
    public let view: TerminalView
    @Published public var follow = true
    @Published public private(set) var connected = false
    @Published public private(set) var ownsInput = false
    @Published public private(set) var acceptsInput = false
    @Published public private(set) var message = "Live output appears when a job is attached."
    @Published public var fontSize: Double = 13 { didSet { view.font = .monospacedSystemFont(ofSize: min(24, max(10, fontSize)), weight: .regular) } }
    private var rendering = false
    private var display = ProvisioningTerminalDisplay()
    private var attachment: ProvisioningTerminalAttachment?
    private var invocation: UUID?
    private var generation = UUID()
    private var polling: Task<Void, Never>?
    private var controlPending = false
    private var operation = false
    private var pendingInput: [(UUID, Data)] = []
    private var pendingBytes = 0
    private var sentSize = (24, 80)
    private var size = (24, 80)
    public override init() {
        view = TerminalView(frame: .init(x: 0, y: 0, width: 800, height: 360))
        super.init()
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = .black; view.nativeForegroundColor = .white
        view.allowMouseReporting = false
        view.configureProvisioningDisplay()
        view.terminalDelegate = self

    }
    deinit { polling?.cancel() }
    public func attach(service: any ProvisioningObserving, workflowID: UUID) async {
        await detach()
        let generation = UUID(); self.generation = generation
        resetScreen()
        do {
            let value = try await service.attachTerminal(workflowID)
            guard self.generation == generation, !Task.isCancelled else { await value.detach(); return }
            attachment = value; connected = true; message = "View only · Take input to answer a prompt."
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    guard self?.generation == generation else { return }
                    await self?.poll(generation)
                    do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                }
            }
        } catch { if self.generation == generation { message = "The original live terminal is unavailable. Job state is preserved." } }
    }
    public func detach() async {
        generation = UUID(); polling?.cancel(); polling = nil
        let prior = attachment; attachment = nil; connected = false; ownsInput = false; acceptsInput = false; invocation = nil
        pendingInput.removeAll(); pendingBytes = 0
        await prior?.detach()
    }
    private func poll(_ generation: UUID) async {
        guard !operation, !controlPending, let attachment else { return }
        operation = true; defer { operation = false }
        do {
            let page = try await attachment.poll()
            guard self.generation == generation else { return }
            if page.resetRequired {
                resetScreen()
                view.feed(text: "[Output gap: screen reset at the live tail; input released.]\r\n")
                pendingInput.removeAll(); pendingBytes = 0
                ownsInput = false; acceptsInput = false; invocation = nil
                _ = try await attachment.acknowledgeReset()
                message = "Output gap · Screen reset. Take input again when ready."
            } else {
                if invocation != page.activeInvocationID || !page.acceptsInput { pendingInput.removeAll(); pendingBytes = 0 }
                ownsInput = page.ownsInput; acceptsInput = page.acceptsInput; invocation = page.activeInvocationID
                for frame in page.frames { render(frame.bytes) }
                if ownsInput, acceptsInput, let invocation, sentSize != size {
                    let current = size
                    try await attachment.resize(rows: current.0, columns: current.1, invocationID: invocation)
                    guard self.generation == generation else { return }; sentSize = current
                }
                try await flushInput(attachment, generation: generation)
            }
        } catch ProvisioningTerminalDenial.busy { }
        catch { if self.generation == generation { await attachment.detach(); pendingInput.removeAll(); pendingBytes = 0; connected = false; ownsInput = false; acceptsInput = false; message = "Terminal disconnected. Setup continues; job status remains available."; polling?.cancel() } }
    }
    /// Byte filter carries UTF-8 and escape state across frames. Kept public for
    /// deterministic local rendering fixtures; callers provide actual job bytes.
    public func render(_ data: Data) {
        rendering = true; defer { rendering = false }
        let position = view.scrollPosition
        let bytes = display.consume(data)
        if !bytes.isEmpty { view.feed(byteArray: Array(bytes)[...]) }
        if follow { view.scroll(toPosition: 1) } else { view.scroll(toPosition: position) }
    }
    public func resetScreen() {
        display.reset(); view.resetToInitialState()
        view.needsDisplay = true
    }
    private func idle(_ generation: UUID) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(7)
        while operation, self.generation == generation, ContinuousClock.now < deadline, !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        }
        return !operation && generation == self.generation && !Task.isCancelled
    }
    public func takeInput() async {
        guard !controlPending, !ownsInput, let attachment else { return }
        controlPending = true; defer { controlPending = false }
        let generation = generation
        guard await idle(generation) else { return }
        operation = true; defer { operation = false }
        do {
            try await attachment.claimInput(rows: size.0, columns: size.1)
            guard generation == self.generation else { return }
            ownsInput = true; sentSize = size; message = "Input owned here · Password input is handled by the native guest prompt."
            view.window?.makeFirstResponder(view)
        } catch { if generation == self.generation { message = "Input was refused. Another viewer may own it, or the job scope has ended." } }
    }
    public func releaseInput() async {
        guard !controlPending, let attachment else { return }
        controlPending = true; defer { controlPending = false }
        ownsInput = false; acceptsInput = false; pendingInput.removeAll(); pendingBytes = 0
        let generation = generation
        guard await idle(generation) else { await attachment.detach(); return }
        operation = true; defer { operation = false }
        do { try await attachment.releaseInput() } catch { await attachment.detach() }
    }
    public func jumpToLatest() { follow = true; view.scroll(toPosition: 1) }
    /// Literal, bounded, in-memory search. Never evaluates patterns or opens URLs.
    public func search(_ query: String) -> Int {
        guard !query.isEmpty, query.utf8.count <= 256 else { return 0 }
        let text = String(decoding: view.getBufferAsData(), as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        let matches = lines.indices.filter { lines[$0].range(of: query, options: .caseInsensitive) != nil }
        if let first = matches.first { follow = false; view.scroll(toPosition: Double(first) / Double(max(1, lines.count - 1))) }
        return matches.count
    }
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        size = (min(500, max(1, newRows)), min(1000, max(1, newCols)))
        // Coalesce dimensions. The next serialized poll sends them only for the
        // current owner/invocation, never concurrently with an input mutation.
    }
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !controlPending, ownsInput, acceptsInput, let invocation, let attachment, !data.isEmpty, data.count <= 4096 else { return }
        guard pendingBytes + data.count <= 16 * 1024 else {
            pendingInput.removeAll(); pendingBytes = 0; ownsInput = false; acceptsInput = false
            message = "Input buffer full. Reconnect before reclaiming input."
            Task { await attachment.detach() }; return
        }
        pendingInput.append((invocation, Data(data))); pendingBytes += data.count
        // A bounded transient queue avoids losing keys while a read is in
        // flight. Each chunk is removed before its single delivery attempt.
        guard !operation else { return }
        operation = true
        let generation = generation
        Task {
            defer { operation = false }
            do { try await flushInput(attachment, generation: generation) }
            catch { await inputFailed(attachment, generation: generation) }
        }
    }
    private func flushInput(_ attachment: ProvisioningTerminalAttachment, generation: UUID) async throws {
        for _ in 0..<4 {
            guard generation == self.generation, ownsInput, acceptsInput, !pendingInput.isEmpty else { return }
            let value = pendingInput.removeFirst(); pendingBytes -= value.1.count
            guard value.0 == invocation else { pendingInput.removeAll(); pendingBytes = 0; return }
            try await attachment.send(value.1, invocationID: value.0)
        }
    }
    private func inputFailed(_ attachment: ProvisioningTerminalAttachment, generation: UUID) async {
        guard generation == self.generation else { return }
        pendingInput.removeAll(); pendingBytes = 0; ownsInput = false; acceptsInput = false; connected = false
        message = "Input acknowledgement failed. Reconnect before reclaiming input."
        await attachment.detach()
    }
    public func scrolled(source: TerminalView, position: Double) { if !rendering, position < 0.99 { follow = false } }
    public func setTerminalTitle(source: TerminalView, title: String) { }
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { }
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { }
    public func bell(source: TerminalView) { }
    public func clipboardCopy(source: TerminalView, content: Data) { }
    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { }
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) { }
}

public struct ProvisioningNativeTerminal: NSViewRepresentable {
    @ObservedObject var screen: ProvisioningTerminalScreen
    public init(screen: ProvisioningTerminalScreen) { self.screen = screen }
    public func makeNSView(context: Context) -> TerminalView { screen.view }
    public func updateNSView(_ nsView: TerminalView, context: Context) { }
}
