import AppKit
import Darwin
import Foundation
import TryOmarchyKitClient

/// One launch-scoped request. Cancellation and the final side effect share
/// the lock so an already queued main-actor probe cannot outlive a stop.
final class GuestLaunchForegrounding: @unchecked Sendable {
    enum Readiness { case waiting, ready, gone }
    typealias Probe = @MainActor @Sendable (VMRunDisplayProcess) -> Readiness
    typealias Activate = @MainActor @Sendable (VMRunDisplayProcess) -> Bool

    private let lock = NSLock()
    private let intent: VMLaunchIntent
    private let probe: Probe
    private let activate: Activate
    private let unavailable: @Sendable () -> Void
    private let timeout: Duration
    private var began = false
    private var finished = false
    private var task: Task<Void, Never>?

    init(intent: VMLaunchIntent, timeout: Duration = .seconds(15),
         probe: @escaping Probe = GuestLaunchForegrounding.readiness,
         activate: @escaping Activate = GuestLaunchForegrounding.activate,
         unavailable: @escaping @Sendable () -> Void = {}) {
        self.intent = intent; self.timeout = timeout
        self.probe = probe; self.activate = activate; self.unavailable = unavailable
    }

    func displayReady(_ process: VMRunDisplayProcess) {
        lock.withLock {
            guard intent == .foreground, !began, !finished else { return }
            began = true
            let deadline = ContinuousClock.now.advanced(by: timeout)
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard self?.poll(process, deadline: deadline) == true else { return }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        }
    }

    func cancel() {
        lock.withLock {
            finished = true
            task?.cancel(); task = nil
        }
    }

    @MainActor private func poll(_ process: VMRunDisplayProcess, deadline: ContinuousClock.Instant) -> Bool {
        let result: (wait: Bool, failed: Bool) = lock.withLock {
            guard !finished else { return (false, false) }
            guard ContinuousClock.now < deadline else {
                finished = true; task = nil
                return (false, true)
            }
            switch probe(process) {
            case .waiting: return (true, false)
            case .gone:
                finished = true; task = nil
                return (false, true)
            case .ready:
                finished = true; task = nil
                return (false, !activate(process))
            }
        }
        if result.failed { unavailable() }
        return result.wait
    }

    private static func matches(_ process: VMRunDisplayProcess) -> Bool {
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let count = withUnsafeMutablePointer(to: &information) {
            proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, $0, size)
        }
        return count == size && information.pbi_start_tvsec == process.startSeconds
            && information.pbi_start_tvusec == process.startMicroseconds
    }

    @MainActor private static func readiness(_ process: VMRunDisplayProcess) -> Readiness {
        guard matches(process) else { return .gone }
        guard let app = NSRunningApplication(processIdentifier: process.processIdentifier) else { return .waiting }
        guard !app.isTerminated else { return .gone }
        guard app.isFinishedLaunching, app.activationPolicy == .regular else { return .waiting }
        // Window metadata needs no screen capture or Accessibility grant.
        // Include other Spaces; activation leaves placement to macOS.
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let hasDisplay = windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber, let height = bounds["Height"] as? NSNumber else { return false }
            return width.doubleValue > 1 && height.doubleValue > 1
        }
        return hasDisplay ? .ready : .waiting
    }

    @MainActor private static func activate(_ process: VMRunDisplayProcess) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: process.processIdentifier), !app.isTerminated, matches(process) else { return false }
        NSApplication.shared.yieldActivation(to: app)
        return app.activate(from: .current, options: [])
    }
}
