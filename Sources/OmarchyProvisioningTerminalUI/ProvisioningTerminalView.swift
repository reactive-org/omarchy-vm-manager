import AppKit
import OmarchyVMManagerCore
import SwiftUI
import SwiftTerm

/// A direct click expresses input intent. Output, focus changes and reconnects
/// never claim the single-writer lease, and no keystrokes queue before admission.
@MainActor private final class ClickableProvisioningTerminal: TerminalView {
    var inputRequested: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.type == .leftMouseDown { inputRequested?() }
    }
}

/// Fits the preferred 120-column grid on normal manager widths. Wide windows
/// retain the user's font size; narrow windows use a bounded smaller font.
@MainActor private final class ProvisioningTerminalContainer: NSView {
    let screen: ProvisioningTerminalScreen
    init(screen: ProvisioningTerminalScreen) {
        self.screen = screen
        super.init(frame: .zero)
        addSubview(screen.view)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layout() {
        super.layout()
        screen.fit(width: bounds.width)
        screen.view.frame = bounds
    }
}

/// UI owns only a viewer. Output stays in the bounded emulator; no output mirror,
/// log, restoration archive or automatic input queue. All work runs on MainActor.
@MainActor public final class ProvisioningTerminalScreen: NSObject, ObservableObject, @preconcurrency TerminalViewDelegate {
    public let view: TerminalView
    @Published public var follow = true
    @Published public private(set) var connected = false
    @Published public private(set) var ownsInput = false
    @Published public private(set) var acceptsInput = false
    @Published public private(set) var message = "Live output appears when a job is attached."
    @Published public var fontSize: Double = 11 { didSet { fit(width: view.bounds.width) } }
    private var display = ProvisioningTerminalDisplay()
    private var attachment: ProvisioningTerminalAttachment?
    private var invocation: UUID?
    private var generation = UUID()
    private var polling: Task<Void, Never>?
    private var controlPending = false
    private var operation = false
    private var pendingInput: [(UUID, Data)] = []
    private var pendingBytes = 0
    private var sentSize = (30, 120)
    private var size = (30, 120)
    private let readPage: @MainActor (ProvisioningTerminalAttachment) async throws -> ProvisioningTerminalPage
    public override convenience init() { self.init(readPage: { try await $0.poll() }) }
    /// Internal read seam lets local fixtures hold a reply across a control
    /// transition without changing the authenticated attachment or its commands.
    init(readPage: @escaping @MainActor (ProvisioningTerminalAttachment) async throws -> ProvisioningTerminalPage) {
        self.readPage = readPage
        // Pipe-based Ansible output uses LF; PTY output may already use CRLF.
        // The display must start both at column zero without modifying job bytes.
        view = ClickableProvisioningTerminal(frame: .init(x: 0, y: 0, width: 800, height: 420), options: .init(cols: 120, rows: 30, convertEol: true))
        super.init()
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.nativeBackgroundColor = .black; view.nativeForegroundColor = .white
        view.allowMouseReporting = false
        view.configureProvisioningDisplay()
        view.terminalDelegate = self
        (view as? ClickableProvisioningTerminal)?.inputRequested = { [weak self] in
            Task { await self?.takeInput() }
        }

    }
    deinit { polling?.cancel() }
    public func attach(service: any ProvisioningObserving, workflowID: UUID) async {
        await detach()
        let generation = UUID(); self.generation = generation
        follow = true; resetScreen()
        do {
            let value = try await beforeDispatchBusy { try await service.attachTerminal(workflowID) }
            guard self.generation == generation, !Task.isCancelled else { await value.detach(); return }
            attachment = value; connected = true; message = "Click in the terminal to type."
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
            let page = try await readPage(attachment)
            guard self.generation == generation else { return }
            if page.resetRequired {
                resetScreen()
                view.feed(text: "[Output gap: screen reset at the live tail; input released.]\r\n")
                pendingInput.removeAll(); pendingBytes = 0
                ownsInput = false; acceptsInput = false; invocation = nil
                _ = try await attachment.acknowledgeReset()
                message = "Output gap · Screen reset. Click in the terminal to type again."
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
    /// A busy client rejects before sending anything. Briefly wait for another
    /// viewer's read; never replay dispatched input/claims or a lost reply.
    private func beforeDispatchBusy<T: Sendable>(_ action: () async throws -> T) async throws -> T {
        let deadline = ContinuousClock.now + .milliseconds(250)
        while true {
            do { return try await action() }
            catch ProvisioningTerminalDenial.busy {
                guard ContinuousClock.now < deadline, !Task.isCancelled else { throw ProvisioningTerminalDenial.busy }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
    public func takeInput() async {
        guard !controlPending, !ownsInput, let attachment else { return }
        controlPending = true; defer { controlPending = false }
        let generation = generation
        guard await idle(generation) else { return }
        operation = true; defer { operation = false }
        do {
            try await beforeDispatchBusy { try await attachment.claimInput(rows: size.0, columns: size.1) }
            guard generation == self.generation else { return }
            let page = try await beforeDispatchBusy { try await attachment.poll() }
            guard self.generation == generation else { return }
            if page.resetRequired {
                resetScreen(); _ = try await attachment.acknowledgeReset()
                message = "Output gap · Screen reset. Click in the terminal to type again."
                return
            }
            ownsInput = page.ownsInput; acceptsInput = page.acceptsInput; invocation = page.activeInvocationID
            for frame in page.frames { render(frame.bytes) }
            sentSize = size; message = "Keyboard connected · Type directly in the terminal."
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
        // An already-dispatched poll may have published its old ownership while
        // idle() yielded. Clear again after it finishes, before releasing the
        // lease; controlPending/operation now prevent another poll or input send.
        ownsInput = false; acceptsInput = false; pendingInput.removeAll(); pendingBytes = 0
        do { try await beforeDispatchBusy { try await attachment.releaseInput() }; message = "Click in the terminal to type." } catch { await attachment.detach() }
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
            try await beforeDispatchBusy { try await attachment.send(value.1, invocationID: value.0) }
        }
    }
    private func inputFailed(_ attachment: ProvisioningTerminalAttachment, generation: UUID) async {
        guard generation == self.generation else { return }
        pendingInput.removeAll(); pendingBytes = 0; ownsInput = false; acceptsInput = false; connected = false
        message = "Input acknowledgement failed. Reconnect before reclaiming input."
        await attachment.detach()
    }
    // Layout, resize and output can all emit scroll callbacks. Only the Follow
    // toggle, search and Jump to latest change follow intent.
    public func scrolled(source: TerminalView, position: Double) { }
    func fit(width: CGFloat) {
        guard width > 0 else { return }
        let preferred = min(24, max(9, fontSize))
        let sample = NSFont.monospacedSystemFont(ofSize: preferred, weight: .regular)
        let cell = ("M" as NSString).size(withAttributes: [.font: sample]).width
        let fitted = max(9, min(preferred, preferred * max(1, width - 12) / ((fontSize <= 11 ? 120 : 80) * cell)))
        if abs(view.font.pointSize - fitted) > 0.05 { view.font = .monospacedSystemFont(ofSize: fitted, weight: .regular) }
    }
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
    public func makeNSView(context: Context) -> NSView { ProvisioningTerminalContainer(screen: screen) }
    public func updateNSView(_ nsView: NSView, context: Context) { nsView.needsLayout = true }
}
