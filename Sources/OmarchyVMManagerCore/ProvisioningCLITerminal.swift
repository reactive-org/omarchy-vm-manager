import Darwin
import Foundation

/// CLI-only scoped signal observation; never installed by app composition.
private final class ProvisioningCLIInterrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    private var sources: [DispatchSourceSignal] = []
    private var old: [(Int32, sigaction)] = []
    init() throws {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            var previous = sigaction(), ignored = sigaction()
            ignored.__sigaction_u.__sa_handler = SIG_IGN
            sigemptyset(&ignored.sa_mask)
            guard sigaction(number, nil, &previous) == 0, sigaction(number, &ignored, nil) == 0 else { throw ProvisioningTerminalDenial.unavailable }
            old.append((number, previous))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in self?.lock.withLock { self?.interrupted = true } }
            sources.append(source); source.resume()
        }
    }
    var stopped: Bool { lock.withLock { interrupted } }
    deinit { sources.forEach { $0.cancel() }; for (number, saved) in old { var saved = saved; _ = sigaction(number, &saved, nil) } }
}

/// Duplicate owns the original open-file description. Nonblocking output and an
/// absolute write deadline keep a stopped viewer from stranding raw TTY state.
private final class ProvisioningCLIOutput {
    let descriptor: Int32
    private let flags: Int32
    private var restored = false
    init(_ source: Int32) throws {
        let fd = fcntl(source, F_DUPFD_CLOEXEC, 10)
        guard fd >= 0 else { throw ProvisioningTerminalDenial.unavailable }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { close(fd); throw ProvisioningTerminalDenial.unavailable }
        descriptor = fd; self.flags = flags
    }
    @discardableResult func restore() -> Bool {
        if restored { return true }
        restored = fcntl(descriptor, F_SETFL, flags) == 0
        return restored
    }
    deinit { restore(); close(descriptor) }
}

public enum ProvisioningCLITerminal {
    /// Attach is view-only by default. --input explicitly requests ownership.
    /// Ctrl-] detaches; cancellation is a separate setup cancel command. No input
    /// is retained or replayed. Uses safe display bytes, never raw host escapes.
    public static func attach(client: ProvisioningExternalClient, workflowID: UUID, interactive: Bool,
                              input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) async throws {
        guard isatty(output) == 1, !interactive || isatty(input) == 1 else {
            throw commandFailure("tty-required", "Attach needs a terminal. Use setup status --events for automation.")
        }
        let outputLease = try ProvisioningCLIOutput(output)
        let output = outputLease.descriptor
        var interrupt: ProvisioningCLIInterrupt?
        defer { outputLease.restore(); withExtendedLifetime(interrupt) {} }
        let attached = try await client.request(.attach, workflowID: workflowID)
        guard attached.failure == nil else { throw commandFailure("terminal-unavailable", "The original live job terminal is unavailable.") }
        var enteredScreen = false
        var raw: ProvisioningLocalTerminal?
        do {
            interrupt = try ProvisioningCLIInterrupt()
            if interactive {
                let size = dimensions(output)
                let claim = try await client.request(.claim, workflowID: workflowID, rows: size.0, columns: size.1)
                guard claim.failure == nil else { throw commandFailure("input-unavailable", "Input ownership was refused. Another viewer may own the prompt.") }
                raw = try ProvisioningLocalTerminal(descriptor: input)
            }
            enteredScreen = true
            try writeAll(output, Data("\u{1b}[?1049h\u{1b}[?25h".utf8))
            try await loop(client: client, workflowID: workflowID, interactive: interactive, input: input, output: output, interrupt: interrupt!)
            guard raw?.restore() != false else { throw ProvisioningTerminalDenial.unavailable }
            try writeAll(output, Data("\u{1b}[0m\u{1b}[?2004l\u{1b}[?25h\u{1b}[?1049l".utf8))
            _ = try? await client.request(.detach, workflowID: workflowID)
            await client.close()
        } catch {
            _ = raw?.restore()
            if enteredScreen { try? writeAll(output, Data("\u{1b}[0m\u{1b}[?2004l\u{1b}[?25h\u{1b}[?1049l".utf8)) }
            await client.close() // Disconnect revokes only this attachment.
            throw error
        }
    }
    private static func loop(client: ProvisioningExternalClient, workflowID: UUID, interactive: Bool,
                             input: Int32, output: Int32, interrupt: ProvisioningCLIInterrupt) async throws {
        var display = ProvisioningTerminalDisplay(), size = dimensions(output)
        var lastStatus = ContinuousClock.now - .seconds(2)
        while !Task.isCancelled, !interrupt.stopped {
            let reply = try await client.request(.read, workflowID: workflowID)
            if reply.failure == "busy" { try await Task.sleep(for: .milliseconds(40)); continue }
            guard reply.failure == nil, let page = reply.page else { throw ProvisioningTerminalDenial.unavailable }
            if page.resetRequired {
                display.reset()
                try writeAll(output, Data("\u{1b}c\r\n[Output gap: screen reset; input released. Detach and use --input to reclaim.]\r\n".utf8))
                let reset = try await client.request(.reset, workflowID: workflowID)
                guard reset.failure == nil else { throw ProvisioningTerminalDenial.resetRequired }
            } else {
                for frame in page.frames { try writeAll(output, display.consume(frame.bytes)) }
                if interactive, page.acceptsInput, let invocation = page.activeInvocationID {
                    let current = dimensions(output)
                    if current != size {
                        let resized = try await client.request(.resize, workflowID: workflowID, invocationID: invocation, rows: current.0, columns: current.1)
                        guard resized.failure == nil else { throw ProvisioningTerminalDenial.ownership }; size = current
                    }
                }
                // Poll even when view-only, allowing Ctrl-] without raw mode.
                // View-only leaves termios unchanged (Ctrl-] then Return).
                var event = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
                if isatty(input) == 1, poll(&event, 1, 0) > 0 {
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let count = Darwin.read(input, &bytes, bytes.count)
                    if count == 0 { return }
                    if count > 0 {
                        let data = Data(bytes.prefix(count))
                        if data.contains(29) { return } // Never forward detach keystroke.
                        if interactive, page.acceptsInput, let invocation = page.activeInvocationID {
                            let sent = try await client.request(.input, workflowID: workflowID, invocationID: invocation, bytes: data)
                            guard sent.failure == nil else { throw ProvisioningTerminalDenial.ownership }
                        }
                    }
                }
            }
            if page.frames.isEmpty, ContinuousClock.now - lastStatus >= .seconds(1) {
                let status = try await client.request(.status, workflowID: workflowID); lastStatus = .now
                guard status.failure == nil, let row = status.workflows?.first else { throw ProvisioningTerminalDenial.unavailable }
                if !row.canCancel { return }
            }
            if page.frames.isEmpty { try await Task.sleep(for: .milliseconds(40)) }
        }
    }
    private static func dimensions(_ fd: Int32) -> (Int, Int) {
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0 else { return (24, 80) }
        return (min(500, Int(size.ws_row)), min(1000, Int(size.ws_col)))
    }
    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            let deadline = ContinuousClock.now + .seconds(1)
            while offset < buffer.count, ContinuousClock.now < deadline {
                var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&event, 1, 50)
                if ready < 0, errno == EINTR { continue }
                guard ready >= 0 else { throw ProvisioningTerminalDenial.unavailable }
                if ready == 0 { continue }
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                guard n > 0 else { throw ProvisioningTerminalDenial.unavailable }; offset += n
            }
            guard offset == buffer.count else { throw ProvisioningTerminalDenial.unavailable }
        }
    }
}
