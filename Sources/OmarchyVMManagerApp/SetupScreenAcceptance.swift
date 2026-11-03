#if DEBUG
import AppKit
import OmarchyProvisioningTerminalUI
import OmarchyVMManagerCore
import SwiftUI

/// Own-process offscreen, nonactivating windows only. Never AXUIElement/system events, an on-display
/// window, the installed manager, personal registry, Keychain or a real runtime.
@MainActor private final class AcceptanceResult<Value> { var result: Result<Value, any Error>? }
private extension Optional { func unwrap() throws -> Wrapped { guard let self else { throw AcceptanceFailure.check }; return self } }
@MainActor enum SetupScreenAcceptance {
    final class OffscreenWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }
    @MainActor final class Host {
        let window: NSWindow
        let view: NSHostingView<AnyView>
        let root: @MainActor (Bool) -> AnyView
        init<V: View>(_ content: V, driver: SetupUIAcceptanceDriver, width: CGFloat, height: CGFloat, dark: Bool) {
            let labelled = VStack(spacing: 0) { Text("ISOLATED ACCEPTANCE · Synthetic data · No VM or real transport").font(.caption).padding(8); content }
            let makeRoot: @MainActor (Bool) -> AnyView = { scheme in
                AnyView(labelled.environment(\.setupAcceptance, driver)
                    .environment(\.colorScheme, scheme ? .dark : .light)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .background(Color(nsColor: .windowBackgroundColor)))
            }
            root = makeRoot; view = NSHostingView(rootView: makeRoot(dark))
            view.frame = .init(x: 0, y: 0, width: width, height: height)
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window = OffscreenWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = view.appearance; window.contentView = view
            view.layoutSubtreeIfNeeded()
        }
        func scroll(bottom: Bool) { scroll(fraction: bottom ? 1 : 0) }
        func scroll(fraction: CGFloat) {
            var queue = view.subviews, candidates: [NSScrollView] = []
            while let next = queue.popLast() { queue += next.subviews; if let scroll = next as? NSScrollView, let document = scroll.documentView, document.bounds.height > scroll.contentView.bounds.height + 5 { candidates.append(scroll) } }
            if let scroll = candidates.max(by: { $0.frame.height < $1.frame.height }), let document = scroll.documentView {
                let low = document.bounds.minY, high = max(low, document.bounds.maxY - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: .init(x: 0, y: low + (high - low) * (document.isFlipped ? fraction : 1 - fraction))); scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        func close() { window.close() }
        func capture(_ url: URL, screen: ProvisioningTerminalScreen? = nil) throws {
            view.layoutSubtreeIfNeeded()
            let displays = NSScreen.screens.map(\.frame)
            window.setFrameOrigin(.init(x: (displays.map(\.maxX).max() ?? 0) + 10000, y: (displays.map(\.maxY).max() ?? 0) + 10000))
            guard displays.allSatisfy({ !window.frame.intersects($0) }), !window.canBecomeKey, !window.canBecomeMain else { throw AcceptanceFailure.check }
            // Permit AppKit to draw a backing surface, wholly outside every
            // display, without activating, focusing or taking desktop input.
            window.ignoresMouseEvents = true; window.orderBack(nil)
            defer { window.orderOut(nil) }
            SetupScreenAcceptance.tick(0.03)
            guard !window.isKeyWindow, !window.isMainWindow, !NSApplication.shared.isActive,
                  displays.allSatisfy({ !window.frame.intersects($0) }) else { throw AcceptanceFailure.check }
            // Invalidate cached text display lists while preserving the exact
            // view identity and @State graph. Capture returns to the fixture
            // appearance before reading the backing surface.
            let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let alternate = NSAppearance(named: dark ? .aqua : .darkAqua)
            let restored = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = alternate; view.appearance = alternate
            view.rootView = root(!dark); SetupScreenAcceptance.tick(0.08)
            window.appearance = restored; view.appearance = restored
            view.rootView = root(dark); SetupScreenAcceptance.tick(0.08)
            view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.display()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AcceptanceFailure.check }
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            if let screen, let graphics = NSGraphicsContext(bitmapImageRep: bitmap), screen.view.window != nil {
                let rect = screen.view.convert(screen.view.bounds, to: view)
                NSGraphicsContext.saveGraphicsState(); graphics.cgContext.saveGState()
                var clip = rect.intersection(view.bounds), ancestor = screen.view.superview
                while let value = ancestor, value !== view {
                    if value is NSClipView { clip = clip.intersection(value.convert(value.bounds, to: view)) }
                    ancestor = value.superview
                }
                graphics.cgContext.clip(to: .init(x: clip.minX, y: view.bounds.height - clip.maxY, width: clip.width, height: clip.height))
                graphics.cgContext.translateBy(x: rect.minX, y: view.bounds.height - rect.maxY)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics.cgContext, flipped: false)
                screen.view.draw(screen.view.bounds)
                graphics.cgContext.restoreGState(); NSGraphicsContext.restoreGraphicsState()
            }
            guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw AcceptanceFailure.check }
            try bytes.write(to: url, options: .withoutOverwriting)
        }
    }
    static func tick(_ seconds: Double = 0.06) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }
    static func until(_ condition: () -> Bool) throws {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { tick(0.01) }
        guard condition() else { throw AcceptanceFailure.check }
    }
    static func run<T>(_ operation: @escaping @MainActor () async throws -> T) throws -> T {
        let box = AcceptanceResult<T>()
        Task { @MainActor in do { box.result = .success(try await operation()) } catch { box.result = .failure(error) } }
        try until { box.result != nil }; return try box.result!.get()
    }
    static func run(output: URL) throws {
        let temporary = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path
        let parent = output.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard (parent == temporary || parent.hasPrefix(temporary + "/")), !FileManager.default.fileExists(atPath: output.path) else { throw AcceptanceFailure.check }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks: [String] = []
        func check(_ value: Bool, _ label: String) throws { guard value else { print("failed check: " + label); throw AcceptanceFailure.check }; checks.append(label) }
        let runtime = FakeRuntime(), profile = VMProfile(id: UUID(), name: "Synthetic acceptance guest", clipboardEnabled: false)
        let support = output.appendingPathComponent("unused-support")
        let manager = VMManager(runtime: runtime, profiles: [profile], applicationSupport: support)
        let service = SetupAcceptanceService(vmID: profile.id)
        let model = AppModel(isolatedManager: manager, support: support, snapshots: [.init(profile: profile, state: .stopped)], service: service, save: { try await service.save($0, consent: $1) })
        var images: [String] = []
        func capture(_ host: Host, _ name: String, screen: ProvisioningTerminalScreen? = nil) throws {
            try host.capture(output.appendingPathComponent(name), screen: screen); images.append(name)
        }
        for dark in [true, false] {
            let suffix = dark ? "dark" : "light", driver = SetupUIAcceptanceDriver()
            var returned: [UUID] = []
            let host = Host(VMEditor(model: model, profile: nil, saved: { returned.append($0) }), driver: driver, width: 640, height: 820, dark: dark)
            defer { host.close() }
            tick(); try until { driver.scopes["editor"] != nil && driver.scopes["selection"] != nil }
            try check(driver.state("editor", "ready") == "true", suffix + "-none-ready")
            try driver.send("editor", .save); tick()
            try check(returned.isEmpty, suffix + "-empty-name-refused")
            let beforeCapture = service.captures
            try driver.send("selection", .preview); tick(); try check(service.captures == beforeCapture, suffix + "-none-preview-inert")
            try driver.send("editor", .name("Synthetic none " + suffix)); try driver.send("editor", .save); try until { returned.count == 1 }
            try check(model.snapshots.first(where: { $0.id == returned[0] })?.profile.developerSetup == nil, suffix + "-none-creates-metadata-without-setup")
            returned.removeAll()
            try driver.send("editor", .name("Synthetic " + suffix)); try driver.send("editor", .resources(8, 4, 128)); tick()
            try driver.send("selection", .source("bundled")); tick()
            try check(driver.state("editor", "ready") == "false", suffix + "-selection-needs-review")
            try driver.send("selection", .profiles([])); tick()
            let beforeEmpty = service.captures
            try driver.send("selection", .preview); tick()
            try check(service.captures == beforeEmpty && driver.state("editor", "ready") == "false", suffix + "-empty-bundled-profiles-inert")
            let calls = service.savedCalls
            try driver.send("editor", .save); tick(); try check(service.savedCalls == calls, suffix + "-unreviewed-create-refused")
            try check(driver.state("selection", "trimAvailable") == "true" && driver.state("selection", "trim") == "false", suffix + "-official-trim-defaults-off")
            try driver.send("selection", .trim(true)); tick()
            try driver.send("selection", .profiles(["developer", "web"])); tick()
            try until { driver.scopes["appearance"] != nil }
            try check(driver.state("appearance", "expanded") == "false", suffix + "-appearance-starts-collapsed")
            try driver.send("appearance", .appearanceExpanded(true)); tick()
            try check(driver.state("appearance", "columns") == "1", suffix + "-appearance-narrow-stacks")
            try driver.send("appearance", .themeChoice(.repository)); tick()
            let beforeEmptyRepository = service.captures
            try driver.send("selection", .preview); tick()
            try check(driver.state("appearance", "valid") == "false" && service.captures == beforeEmptyRepository, suffix + "-github-choice-requires-url")
            try driver.send("selection", .appearance(.init(theme: "random", minimumStars: 10, layoutFile: "/private/tmp/synthetic-layout.lua"))); tick()
            try driver.send("appearance", .themeChoice(.source)); tick()
            try driver.send("selection", .preview); try until { !driver.state("selection", "review").isEmpty }
            let keptID = try UUID(uuidString: driver.state("selection", "review")).unwrap()
            try check(service.sources[keptID]?.appearance?.theme == nil && service.sources[keptID]?.appearance?.layoutFile == "/private/tmp/synthetic-layout.lua", suffix + "-keep-theme-retains-layout")
            try driver.send("appearance", .themeChoice(.popular)); tick()
            try driver.send("selection", .preview); try until { !driver.state("selection", "review").isEmpty }
            let popularID = try UUID(uuidString: driver.state("selection", "review")).unwrap()
            try check(service.sources[popularID]?.appearance?.theme == "most-starred", suffix + "-popular-theme-forwards-marker")
            try driver.send("appearance", .themeChoice(.random)); tick()
            try driver.send("selection", .preview); try until { !driver.state("selection", "review").isEmpty }
            let firstID = driver.state("selection", "review")
            let selected = service.sources[UUID(uuidString: firstID)!]
            try check(selected?.bundled == true && selected?.profiles == ["developer", "web"], suffix + "-multiple-profile-selection-forwarded")
            try check(selected?.appearance?.theme == "random" && selected?.appearance?.layoutFile == "/private/tmp/synthetic-layout.lua", suffix + "-theme-layout-choice-forwarded")
            try check(selected?.trimOptionalApps == true && ProvisioningTrim.isRequested(in: service.creations[UUID(uuidString: firstID)!]!.proposal), suffix + "-trim-choice-frozen")
            try check(driver.state("editor", "consent") == "false", suffix + "-review-alone-no-consent")
            try driver.send("selection", .acknowledge(true)); tick(); try check(driver.state("editor", "ready") == "true", suffix + "-ack-enables-create")
            try capture(host, "new-vm-review-" + suffix + ".png")
            host.scroll(fraction: 0.35); tick(); try capture(host, "new-vm-trim-" + suffix + ".png"); host.scroll(bottom: false); tick()
            host.scroll(fraction: 0.50); tick(); try capture(host, "new-vm-appearance-" + suffix + ".png"); host.scroll(bottom: false); tick()
            try driver.send("appearance", .layoutExample(nil)); tick()
            try until { driver.state("layout-cards", "count") == "4" }
            let beforeEmptyLayout = service.captures
            try driver.send("selection", .preview); tick()
            try check(driver.state("appearance", "valid") == "false" && service.captures == beforeEmptyLayout, suffix + "-example-gallery-requires-selection")
            try driver.send("layout-cards", .layoutExample(.fourTerminals)); tick()
            try driver.send("selection", .preview); try until { !driver.state("selection", "review").isEmpty }
            let exampleID = try UUID(uuidString: driver.state("selection", "review")).unwrap()
            try check(service.sources[exampleID]?.appearance?.layoutExample == .fourTerminals && ProvisioningAppearanceSummary(proposal: service.creations[exampleID]!.proposal).layoutExample?.id == .fourTerminals, suffix + "-layout-card-forwards-frozen-example")
            try driver.send("selection", .acknowledge(true)); tick()
            host.scroll(fraction: 0.53); tick(); try capture(host, "new-vm-layout-cards-" + suffix + ".png")
            try driver.send("layout-cards", .layoutExample(.vscodeBrowser)); tick()
            try check(driver.state("selection", "review").isEmpty && driver.state("editor", "consent") == "false", suffix + "-layout-card-edit-invalidates-review")
            try driver.send("selection", .appearance(.init(theme: "random", minimumStars: 10, layoutFile: "/private/tmp/synthetic-layout.lua"))); tick()
            try driver.send("selection", .preview); try until { !driver.state("selection", "review").isEmpty }
            try driver.send("selection", .acknowledge(true)); tick()
            try driver.send("appearance", .themeRepository("https://github.com/example/omarchy-other-theme")); tick()
            try check(driver.state("selection", "review").isEmpty && driver.state("editor", "consent") == "false", suffix + "-appearance-edit-invalidates-review")
            try driver.send("selection", .appearance(nil)); tick()
            try driver.send("selection", .preview); try until { !driver.state("selection", "review").isEmpty }
            try driver.send("selection", .acknowledge(true)); tick()
            if dark, let id = UUID(uuidString: firstID), let review = service.creations[id] {
                let object = try JSONSerialization.jsonObject(with: review.proposal)
                try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("new-vm-proposal.json"), options: .withoutOverwriting)
            }
            try driver.send("selection", .trim(false)); tick()
            try check(driver.state("selection", "review").isEmpty && driver.state("editor", "consent") == "false", suffix + "-trim-edit-invalidates-consent")
            try driver.send("selection", .trim(true)); tick()
            try driver.send("editor", .factory("synthetic-custom")); tick()
            try check(driver.state("selection", "trimAvailable") == "false" && driver.state("selection", "trim") == "false" && driver.state("editor", "consent") == "false", suffix + "-custom-factory-hides-resets-trim")
            try driver.send("editor", .factory("official")); tick()
            try check(driver.state("selection", "trimAvailable") == "true" && driver.state("selection", "trim") == "false", suffix + "-official-return-no-implicit-trim")
            try driver.send("selection", .profiles(["python"])); tick()
            try check(driver.state("selection", "review").isEmpty && driver.state("editor", "consent") == "false", suffix + "-profile-edit-invalidates-review-and-ack")
            service.holdNext = true; try driver.send("selection", .preview); try until { service.waiting }
            try driver.send("selection", .profiles(["developer", "project-managed"])); tick(); service.release(); tick()
            try check(driver.state("selection", "review").isEmpty && driver.state("editor", "ready") == "false", suffix + "-late-capture-discarded")
            service.failNext = true; try driver.send("selection", .preview); try until { driver.state("selection", "failure") == "true" }
            try check(driver.state("editor", "consent") == "false", suffix + "-capture-error-no-consent")
            try driver.send("selection", .preview); try until { !driver.state("selection", "review").isEmpty }
            try check(driver.state("selection", "review") != firstID, suffix + "-new-selection-new-review")
            try driver.send("selection", .acknowledge(true)); tick(); try driver.send("editor", .save); try until { returned.count == 1 }
            let created = try model.snapshots.first(where: { $0.id == returned[0] }).unwrap()
            try check(created.profile.memoryMiB == 8192 && created.profile.cpus == 4 && created.profile.diskGiB == 128 && created.profile.factory == .official && service.saved[created.profile.developerSetup!.reviewID]?.0.factory == "official", suffix + "-manager-resources-factory-preserved")
            try check(created.profile.developerSetup?.reviewID.uuidString == driver.state("selection", "review") && created.sessionID == nil, suffix + "-frozen-handoff-without-start")
            try driver.send("editor", .save); try until { returned.count == 2 }; try check(returned[0] == returned[1], suffix + "-duplicate-save-one-uuid")
            host.scroll(bottom: true); tick(); try capture(host, "new-vm-resources-" + suffix + ".png")
            let setupDriver = SetupUIAcceptanceDriver()
            let setup = Host(ManagerView(model: model, acceptanceGuestID: created.id), driver: setupDriver, width: 1200, height: 960, dark: dark)
            defer { setup.close() }; tick()
            try until { setupDriver.state("setup", "preview") == created.profile.developerSetup?.reviewID.uuidString }
            try check(setupDriver.state("setup", "execution") == "false", suffix + "-product-surface-gate-disabled")
            let preparations = service.preparations
            try setupDriver.send("setup", .prepareApply); tick(); try check(service.preparations == preparations, suffix + "-disabled-prepare-never-delegates")
            try setupDriver.send("setup", .inspect); try until { setupDriver.state("setup", "inspected") == "1" }
            try check(setupDriver.state("setup", "taskBytes") == String(service.task.count), suffix + "-complete-chunked-task-inspection")
            try capture(setup, "setup-handoff-" + suffix + ".png", screen: setupDriver.terminalScreen)
            try setupDriver.send("setup", .source("local")); tick()
            try check(setupDriver.state("setup", "preview").isEmpty && setupDriver.state("setup", "inspected") == "0", suffix + "-source-edit-clears-inspection")
            try setupDriver.send("setup", .trim(true)); tick()
            try until { setupDriver.scopes["appearance"] != nil }
            try setupDriver.send("appearance", .appearanceExpanded(true)); tick()
            try check(setupDriver.state("appearance", "columns") == "2", suffix + "-appearance-wide-columns")
            try setupDriver.send("setup", .appearance(.init(theme: "https://github.com/example/omarchy-fixture-theme", removeLayout: true))); tick()
            try setupDriver.send("setup", .folder(output.appendingPathComponent("selected-source"))); try setupDriver.send("setup", .preview)
            try until { !setupDriver.state("setup", "preview").isEmpty }
            try check(service.sources.values.contains(where: { $0.directory?.hasSuffix("selected-source") == true }), suffix + "-explicit-local-source")
            try check(service.sources.values.contains(where: { $0.directory?.hasSuffix("selected-source") == true && $0.profiles == nil }), suffix + "-local-profiles-inherited")
            try check(setupDriver.state("setup", "trimAvailable") == "true" && service.sources.values.contains(where: { $0.directory?.hasSuffix("selected-source") == true && $0.trimOptionalApps == true }), suffix + "-existing-official-trim-forwarded")
            setup.scroll(fraction: 0.45); tick(); try capture(setup, "setup-trim-" + suffix + ".png", screen: setupDriver.terminalScreen)
            let localID = try UUID(uuidString: setupDriver.state("setup", "preview")).unwrap()
            try check(service.sources[localID]?.appearance?.removeLayout == true && service.sources[localID]?.appearance?.theme?.hasPrefix("https://github.com/") == true, suffix + "-existing-theme-layout-forwarded")
            try capture(setup, "setup-appearance-" + suffix + ".png", screen: setupDriver.terminalScreen)
            try setupDriver.send("appearance", .layoutExample(nil)); tick()
            try until { setupDriver.state("layout-cards", "count") == "4" }
            try setupDriver.send("layout-cards", .layoutExample(.claudeWorkspace)); tick()
            try setupDriver.send("setup", .preview); try until { !setupDriver.state("setup", "preview").isEmpty }
            let chosenLayoutID = try UUID(uuidString: setupDriver.state("setup", "preview")).unwrap()
            try check(setupDriver.state("appearance", "columns") == "1" && service.sources[chosenLayoutID]?.appearance?.layoutExample == .claudeWorkspace, suffix + "-existing-layout-gallery-full-width")
            setup.scroll(fraction: 0.55); tick(); try capture(setup, "setup-layout-cards-" + suffix + ".png", screen: setupDriver.terminalScreen)
            let wrongID = UUID(); _ = try run { try await service.preview(id: wrongID, vmID: UUID(), source: .init(preset: "web")) }
            let original = setupDriver.state("setup", "preview")
            try setupDriver.send("setup", .lookup(wrongID)); try until { setupDriver.state("setup", "failure") == "true" }
            try check(setupDriver.state("setup", "preview") == original, suffix + "-cross-guest-preview-rejected")
            let missing = UUID(); try setupDriver.send("setup", .lookup(missing)); tick()
            try check(setupDriver.state("setup", "failure") == "true", suffix + "-lost-review-not-reconstructed")
            setup.close(); host.close()
        }
        // Separate fake-enabled service exercises consent controls, never the
        // real execution gate or any process/guest backend.
        let enabled = SetupAcceptanceService(vmID: profile.id, enabled: true)
        let enabledModel = AppModel(isolatedManager: manager, support: support, snapshots: [.init(profile: profile, state: .stopped)], service: enabled, save: { try await enabled.save($0, consent: $1) })
        let actionDriver = SetupUIAcceptanceDriver()
        let actionHost = Host(ManagerView(model: enabledModel, acceptanceGuestID: profile.id), driver: actionDriver, width: 1200, height: 960, dark: true)
        defer { actionHost.close() }; tick(); try until { actionDriver.scopes["setup"] != nil }
        try actionDriver.send("setup", .source("bundled")); tick()
        try actionDriver.send("setup", .profiles(["web"])); tick()
        try actionDriver.send("setup", .preview); try until { !actionDriver.state("setup", "preview").isEmpty }
        try actionDriver.send("setup", .prepareApply); try until { !actionDriver.state("setup", "review").isEmpty }
        try actionDriver.send("setup", .submit); tick(); try check(enabled.submissions == 0, "apply-without-grants-refused")
        try actionDriver.send("setup", .grant(true, false, true)); try actionDriver.send("setup", .submit); tick(); try check(enabled.submissions == 0, "docker-consent-independent")
        try actionDriver.send("setup", .grant(true, true, true)); try actionDriver.send("setup", .submit); tick(); try check(enabled.submissions == 0, "uninspected-task-cannot-submit")
        try actionDriver.send("setup", .inspect); try until { actionDriver.state("setup", "inspected") == "1" }
        try actionDriver.send("setup", .grant(true, true, false)); try actionDriver.send("setup", .submit); tick(); try check(enabled.submissions == 0, "task-trust-independent")
        try actionDriver.send("setup", .grant(true, true, true)); tick(); actionHost.scroll(bottom: true); tick(); try capture(actionHost, "setup-fake-consent-dark.png", screen: actionDriver.terminalScreen)
        try actionDriver.send("setup", .submit); try until { enabled.submissions == 1 }
        try actionDriver.send("setup", .submit); tick(); try check(enabled.submissions == 1, "submission-attempt-not-replayed")
        actionHost.close()
        let workflow = try enabled.row(UUID(), stage: "running")
        enabledModel.setupWorkflows = [workflow]
        enabledModel.snapshots = [.init(profile: profile, state: .running, sessionID: workflow.originalSessionID,
            sshReadiness: .ready(user: "fixture_owner", command: "synthetic-unused"))]
        let runningDriver = SetupUIAcceptanceDriver()
        let running = Host(ManagerView(model: enabledModel, acceptanceGuestID: profile.id), driver: runningDriver, width: 1200, height: 960, dark: true)
        defer { running.close() }; tick(); try until { runningDriver.terminalScreen != nil }
        let screen = runningDriver.terminalScreen!
        screen.render(Data("SYNTHETIC ACCEPTANCE OUTPUT — no live job\r\n\u{001B}[32mok: [fixture]\u{001B}[0m\r\nUnicode → café ✓\r\n".utf8))
        try runningDriver.send("setup", .search("café")); try check(runningDriver.state("setup", "matches") == "1", "full-screen-literal-terminal-search")
        try runningDriver.send("setup", .expand(true)); tick(); try check(runningDriver.state("setup", "expanded") == "true", "full-screen-expand-terminal")
        try runningDriver.send("setup", .requestCancel); tick(); try check(enabled.cancellations == 0 && runningDriver.state("setup", "cancelPending") == "true", "cancel-needs-confirmation")
        try runningDriver.send("setup", .confirmCancel); try until { enabled.cancellations == 1 }
        try check(!screen.connected && !screen.ownsInput, "synthetic-output-grants-no-input")
        try runningDriver.send("setup", .expand(false)); tick()
        running.scroll(bottom: true); tick(); try capture(running, "setup-terminal-dark.png", screen: screen)
        running.close(); tick(); try check(enabled.cancellations == 1, "view-disappear-detaches-not-cancels")
        try check(runtime.startRequests.isEmpty && !FileManager.default.fileExists(atPath: support.path), "zero-runtime-starts-or-support-access")
        try check(NSApplication.shared.windows.filter { $0.isVisible }.isEmpty, "zero-visible-windows")
        let report: [String: Any] = ["schema": 1, "checks": checks, "realExecution": false, "runtimeStarts": runtime.startRequests.count, "captures": service.captures, "images": images, "fakeSubmissions": enabled.submissions, "physicalInputTested": false, "visibleWindows": NSApplication.shared.windows.filter(\.isVisible).count, "gate": "unchanged-disabled", "onscreenWindows": 0, "activation": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"), options: .withoutOverwriting)
        print("setup-screen-acceptance: PASS (\(checks.count) checks; synthetic services only)")
    }
}
#endif
