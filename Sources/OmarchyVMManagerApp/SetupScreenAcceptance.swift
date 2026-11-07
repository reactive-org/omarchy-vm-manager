#if DEBUG
import AppKit
import OmarchyProvisioningTerminalUI
import OmarchyVMManagerCore
import SwiftUI

/// Own-process offscreen, nonactivating windows only. Never AXUIElement/system events, an on-display
/// window, the installed manager, personal registry, Keychain or a real runtime.
@MainActor private final class AcceptanceResult<Value> { var result: Result<Value, any Error>? }
private extension Optional { func unwrap() throws -> Wrapped { guard let self else { throw AcceptanceFailure.check }; return self } }
/// Records what would reach the Dock and Notification Centre; touches neither.
@MainActor private final class RecordingAttentionSurfaces: SetupAttentionSurfaces {
    var events: [String] = []
    func notify(_ attention: SetupAttention, guestName: String) {
        let text = SystemAttentionSurfaces.text(attention, guestName: guestName)
        events.append("notify:" + text.title + ":" + text.body)
    }
    func clear(_ vmID: UUID) { events.append("clear:" + vmID.uuidString) }
    func bounce() { events.append("bounce") }
    func marker(_ shown: Bool) { events.append("marker:" + String(shown)) }
}
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
            // Fill the requested size: compact sheets otherwise shrink the hosting view to their
            // content, and the capture must stay at least the size the harness asked for.
            let labelled = VStack(spacing: 0) { Text("ISOLATED ACCEPTANCE · Synthetic data · No VM or real transport").font(.caption).padding(8); content }
                .frame(minWidth: width, minHeight: height, alignment: .top)
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
        /// Like `until`, but names the wait that timed out.
        func waitFor(_ label: String, _ condition: () -> Bool) throws {
            do { try until(condition) } catch { print("timed out: " + label); throw error }
        }
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
            try check(driver.state("editor", "canSave") == "false" && driver.state("editor", "validation").contains("Enter a name"), suffix + "-empty-name-explained")
            try driver.send("editor", .name(" \n ")); tick()
            try check(driver.state("editor", "canSave") == "false" && driver.state("editor", "validation").contains("Enter a name"), suffix + "-whitespace-name-explained")
            try driver.send("editor", .save); tick()
            try check(returned.isEmpty, suffix + "-empty-name-refused")
            let beforeCapture = service.captures
            try driver.send("editor", .name("Synthetic none " + suffix)); tick()
            try check(driver.state("editor", "canSave") == "true" && driver.state("editor", "validation").isEmpty, suffix + "-none-create-unblocked")
            try driver.send("editor", .save); try until { returned.count == 1 }
            try check(model.snapshots.first(where: { $0.id == returned[0] })?.profile.developerSetup == nil && service.captures == beforeCapture, suffix + "-none-creates-without-capture")
            returned.removeAll()
            try driver.send("editor", .name("Synthetic " + suffix)); try driver.send("editor", .resources(8, 4, 128)); tick()
            try driver.send("selection", .source("local")); tick()
            try check(driver.state("editor", "canSave") == "false" && driver.state("editor", "validation").contains("Choose a local setup folder"), suffix + "-local-folder-explained")
            try driver.send("selection", .source("bundled")); tick()
            try check(driver.state("editor", "canSave") == "true" && driver.state("editor", "hasSetup") == "true", suffix + "-bundled-direct-create-ready")
            try check(service.captures == beforeCapture, suffix + "-selection-does-not-freeze-or-save")
            try capture(host, "new-vm-selections-" + suffix + ".png")
            try driver.send("selection", .profiles([])); tick()
            try check(driver.state("editor", "validation").contains("Select at least one profile"), suffix + "-missing-profiles-explained")
            let calls = service.savedCalls
            try driver.send("editor", .save); tick()
            try check(service.savedCalls == calls && service.captures == beforeCapture, suffix + "-invalid-profiles-refused-before-capture")
            try check(driver.state("selection", "trimAvailable") == "true" && driver.state("selection", "trim") == "false", suffix + "-official-trim-defaults-off")
            try driver.send("selection", .trim(true)); tick()
            try driver.send("selection", .profiles(["developer", "web"])); tick()
            try until { driver.scopes["appearance"] != nil }
            try check(driver.state("appearance", "card") == "omarchy-default", suffix + "-layout-starts-at-omarchy-default")
            try until { driver.state("layout-cards", "count") == "7" }
            try check(driver.state("layout-cards", "cards") == "four-terminals,terminal-browser,vscode-browser,claude-two-terminals-browser,multi-workspace,claude-browser-code-terminals,small-screen,omarchy-default,custom-file", suffix + "-bundled-cards-omit-setup-folder")
            try driver.send("appearance", .themeChoice(.repository)); tick()
            try check(driver.state("editor", "canSave") == "false" && driver.state("editor", "validation").contains("Enter a GitHub repository URL"), suffix + "-appearance-error-explained")
            try driver.send("appearance", .themeRepository("https://github.com/example/omarchy-fixture-theme")); tick()
            try check(driver.state("selection", "theme") == "https://github.com/example/omarchy-fixture-theme" && driver.state("editor", "canSave") == "true", suffix + "-repository-draft-ready")
            try driver.send("appearance", .themeChoice(.popular)); tick()
            try check(driver.state("selection", "theme") == "most-starred", suffix + "-most-starred-draft")
            try driver.send("appearance", .themeChoice(.random)); tick()
            try check(driver.state("selection", "theme") == "random", suffix + "-random-draft")
            host.scroll(fraction: 0.35); tick(); try capture(host, "new-vm-trim-" + suffix + ".png"); host.scroll(bottom: false); tick()
            host.scroll(fraction: 0.50); tick(); try capture(host, "new-vm-appearance-" + suffix + ".png"); host.scroll(bottom: false); tick()
            try driver.send("appearance", .layoutExample(nil)); tick()
            try until { driver.state("layout-cards", "count") == "7" }
            try check(driver.state("appearance", "card") == "omarchy-default" && driver.state("selection", "layout").isEmpty && driver.state("editor", "canSave") == "true", suffix + "-omarchy-default-adds-no-layout")
            try driver.send("layout-cards", .layoutExample(.fourTerminals)); tick()
            try check(driver.state("selection", "layout") == ProvisioningLayoutExampleID.fourTerminals.rawValue && driver.state("editor", "canSave") == "true", suffix + "-layout-card-draft-ready")
            host.scroll(fraction: 0.53); tick(); try capture(host, "new-vm-layout-cards-" + suffix + ".png")
            try driver.send("layout-cards", .layoutExample(.vscodeBrowser)); tick()
            try check(driver.state("selection", "layout") == ProvisioningLayoutExampleID.vscodeBrowser.rawValue && driver.state("editor", "canSave") == "true", suffix + "-layout-edits-need-no-review")
            try driver.send("selection", .trim(false)); tick()
            try check(driver.state("editor", "canSave") == "true", suffix + "-trim-edit-needs-no-review")
            try driver.send("selection", .trim(true)); tick()
            try driver.send("editor", .factory("synthetic-custom")); tick()
            try check(driver.state("selection", "trimAvailable") == "false" && driver.state("selection", "trim") == "false", suffix + "-custom-factory-hides-resets-trim")
            try driver.send("editor", .factory("official")); tick()
            try check(driver.state("selection", "trimAvailable") == "true" && driver.state("selection", "trim") == "false", suffix + "-official-return-no-implicit-trim")
            try driver.send("selection", .trim(true)); tick()
            try check(service.captures == beforeCapture && service.savedCalls == calls, suffix + "-all-draft-edits-have-no-backend-effects")
            let executions = service.preparations, submissions = service.submissions, reads = service.taskReads
            service.holdNext = true
            try driver.send("editor", .save); try until { service.waiting }
            try check(driver.state("editor", "canSave") == "false" && driver.state("editor", "validation").contains("Preparing setup and creating VM"), suffix + "-create-busy-explained")
            try driver.send("editor", .save); tick()
            try check(service.savedCalls == calls && service.captures == beforeCapture + 1, suffix + "-duplicate-in-flight-create-refused")
            // Debug commands deliberately bypass disabled controls to prove that
            // suspension cannot mix late edits into the submitted configuration.
            try driver.send("selection", .profiles(["python"])); try driver.send("editor", .resources(4, 6, 256)); tick()
            service.release(); try until { returned.count == 1 }
            let created = try model.snapshots.first(where: { $0.id == returned[0] }).unwrap()
            let reviewID = try created.profile.developerSetup.unwrap().reviewID
            let frozenSource = try service.sources[reviewID].unwrap()
            try check(frozenSource.profiles == ["developer", "web"] && frozenSource.trimOptionalApps == true && frozenSource.appearance?.theme == "random" && frozenSource.appearance?.layoutExample == .vscodeBrowser, suffix + "-create-freezes-exact-pressed-selections")
            try check(created.profile.memoryMiB == 8192 && created.profile.cpus == 4 && created.profile.diskGiB == 128 && created.profile.factory == .official && service.saved[reviewID]?.0.factory == "official", suffix + "-manager-resources-factory-captured-before-await")
            try check(created.sessionID == nil && service.preparations == executions && service.submissions == submissions && service.taskReads == reads, suffix + "-create-grants-no-execution-or-task-trust")
            if dark, let review = service.creations[reviewID] {
                let object = try JSONSerialization.jsonObject(with: review.proposal)
                try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("new-vm-proposal.json"), options: .withoutOverwriting)
            }
            try driver.send("selection", .profiles(["developer", "web"])); try driver.send("editor", .resources(8, 4, 128)); tick()
            let frozenCaptures = service.captures
            try driver.send("editor", .save); try until { returned.count == 2 }
            try check(returned[0] == returned[1] && service.captures == frozenCaptures, suffix + "-identical-retry-reuses-frozen-inputs-and-uuid")
            try driver.send("selection", .profiles(["python"])); tick()
            service.failNext = true
            let beforeFailure = service.savedCalls
            try driver.send("editor", .save); try until { !driver.state("editor", "failure").isEmpty && driver.state("editor", "saving") == "false" }
            try check(driver.state("editor", "failure").contains("Could not prepare developer setup") && service.savedCalls == beforeFailure && returned.count == 2, suffix + "-preparation-failure-shown-without-saving")
            try check(driver.state("editor", "canSave") == "true", suffix + "-failed-create-can-retry")
            try capture(host, "new-vm-creation-error-" + suffix + ".png")
            try driver.send("editor", .save); try until { returned.count == 3 }
            let retry = try model.snapshots.first(where: { $0.id == returned[2] }).unwrap()
            try check(retry.id != created.id && retry.profile.developerSetup?.reviewID != reviewID && model.configurationError == nil, suffix + "-changed-selection-gets-new-successful-attempt")
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
            try until { setupDriver.state("layout-cards", "count") == "7" }
            try check(setupDriver.state("layout-cards", "cards").contains("setup-folder") && setupDriver.state("appearance", "card") == "setup-folder", suffix + "-local-cards-offer-setup-folder")
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
            try until { setupDriver.state("layout-cards", "count") == "7" }
            try setupDriver.send("layout-cards", .layoutExample(.claudeWorkspace)); tick()
            try setupDriver.send("setup", .preview); try until { !setupDriver.state("setup", "preview").isEmpty }
            let chosenLayoutID = try UUID(uuidString: setupDriver.state("setup", "preview")).unwrap()
            try check(setupDriver.state("appearance", "card") == "claude-two-terminals-browser" && service.sources[chosenLayoutID]?.appearance?.layoutExample == .claudeWorkspace, suffix + "-existing-layout-card-forwarded")
            setup.scroll(fraction: 0.55); tick(); try capture(setup, "setup-layout-cards-" + suffix + ".png", screen: setupDriver.terminalScreen)
            let wrongID = UUID(); _ = try run { try await service.preview(id: wrongID, vmID: UUID(), source: .init(preset: "web")) }
            let original = setupDriver.state("setup", "preview")
            try setupDriver.send("setup", .lookup(wrongID)); try until { setupDriver.state("setup", "failure") == "true" }
            try check(setupDriver.state("setup", "preview") == original, suffix + "-cross-guest-preview-rejected")
            let missing = UUID(); try setupDriver.send("setup", .lookup(missing)); tick()
            try check(setupDriver.state("setup", "failure") == "true", suffix + "-lost-review-not-reconstructed")
            setup.close(); host.close()

            let localDriver = SetupUIAcceptanceDriver()
            var localCreated: [UUID] = []
            let localHost = Host(VMEditor(model: model, profile: nil, saved: { localCreated.append($0) }), driver: localDriver, width: 640, height: 820, dark: dark)
            tick(); try until { localDriver.scopes["selection"] != nil }
            try localDriver.send("editor", .name("Synthetic local " + suffix))
            try localDriver.send("selection", .source("local")); tick()
            try localDriver.send("selection", .folder(output.appendingPathComponent("synthetic-local-source"))); tick()
            let localSaves = service.savedCalls, localPreparations = service.preparations, localSubmissions = service.submissions, localTaskReads = service.taskReads
            let localCaptures = service.captures
            try check(localDriver.state("editor", "canSave") == "true" && service.savedCalls == localSaves, suffix + "-local-selection-direct-create-ready")
            try localDriver.send("editor", .save); try until { localCreated.count == 1 }
            let localProfile = try model.snapshots.first(where: { $0.id == localCreated[0] }).unwrap().profile
            let localReview = try localProfile.developerSetup.unwrap().reviewID
            try check(service.saved[localReview]?.1.id == localCreated[0] && service.sources[localReview]?.directory?.hasSuffix("synthetic-local-source") == true && service.sources[localReview]?.profiles == nil && service.captures == localCaptures + 1, suffix + "-local-create-captures-selected-folder")
            try check(service.preparations == localPreparations && service.submissions == localSubmissions && service.taskReads == localTaskReads, suffix + "-local-create-grants-no-execution-or-task-trust")
            localHost.close()

            let unavailableModel = AppModel(isolatedManager: manager, support: support, snapshots: [], service: nil,
                save: { try await service.save($0, consent: $1) })
            let unavailableDriver = SetupUIAcceptanceDriver()
            let unavailableHost = Host(VMEditor(model: unavailableModel, profile: nil, saved: { _ in }), driver: unavailableDriver, width: 640, height: 820, dark: dark)
            tick(); try until { unavailableDriver.scopes["selection"] != nil }
            try unavailableDriver.send("editor", .name("Synthetic unavailable " + suffix))
            try unavailableDriver.send("selection", .source("bundled")); tick()
            try check(unavailableDriver.state("editor", "canSave") == "false" && unavailableDriver.state("editor", "validation").contains("Developer setup is unavailable"), suffix + "-unavailable-setup-explained")
            let savedCalls = service.savedCalls
            try unavailableDriver.send("editor", .save); tick()
            try check(service.savedCalls == savedCalls, suffix + "-unavailable-setup-cannot-save")
            try capture(unavailableHost, "new-vm-setup-unavailable-" + suffix + ".png")
            try unavailableDriver.send("selection", .source("local")); tick()
            try check(unavailableDriver.state("editor", "canSave") == "false" && unavailableDriver.state("editor", "validation").contains("Developer setup is unavailable"), suffix + "-unavailable-local-explained")
            try unavailableDriver.send("selection", .source("none")); tick()
            try check(unavailableDriver.state("editor", "canSave") == "true" && unavailableDriver.state("editor", "validation").isEmpty, suffix + "-unavailable-service-none-unblocked")
            unavailableHost.close()
        }
        // Saved account values apply even when schema-1's obsolete global
        // switch is false. This fixture never reads any credential or real data.
        model.ownerDefaults = .init(enabled: false, configuration: .init(username: "fixture_owner", timezone: "UTC", keyboardID: "English (UK)"), credentialReference: UUID())
        for dark in [true, false] {
            let suffix = dark ? "dark" : "light", driver = SetupUIAcceptanceDriver()
            var returned: [UUID] = []
            let host = Host(VMEditor(model: model, profile: nil, saved: { returned.append($0) }), driver: driver, width: 640, height: 820, dark: dark)
            tick(); try until { driver.scopes["editor"] != nil }
            try driver.send("editor", .name("Synthetic saved defaults " + suffix)); tick()
            try check(driver.state("editor", "ownerDefaults") == "true", suffix + "-saved-inputs-default-on-despite-legacy-off")
            try driver.send("editor", .factory("synthetic-custom")); tick()
            try check(driver.state("editor", "ownerDefaults") == "true", suffix + "-custom-factory-keeps-account-defaults")
            try driver.send("editor", .factory("official")); tick()
            host.scroll(fraction: 0.80); tick(); try capture(host, "new-vm-saved-defaults-" + suffix + ".png")
            try driver.send("editor", .save); try until { returned.count == 1 }
            try check(service.savedConfigurations.last?.ownerDefaults == true, suffix + "-create-forwards-saved-account-defaults")
            try driver.send("editor", .ownerDefaults(false)); tick()
            try check(driver.state("editor", "ownerDefaults") == "false", suffix + "-manual-account-opt-out-explicit")
            try driver.send("editor", .save); try until { returned.count == 2 }
            try check(service.savedConfigurations.last?.ownerDefaults == false, suffix + "-manual-choice-forwarded-without-changing-defaults")
            try check(model.ownerDefaults?.isConfigured == true && model.ownerDefaults?.enabled == false, suffix + "-legacy-settings-not-rewritten-by-form")
            host.close()
        }
        let defaultsHost = Host(ScrollView { OwnerDefaultsView(model: model).padding(24) }.frame(width: 1200, height: 1100), driver: SetupUIAcceptanceDriver(), width: 1200, height: 1140, dark: true)
        tick(); try capture(defaultsHost, "guest-defaults-no-global-checkbox-dark.png"); defaultsHost.close()
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
        try check(actionDriver.state("setup", "updateReviewed") == "true", "system-update-included-in-apply-review")
        try actionDriver.send("setup", .submit); tick(); try check(enabled.submissions == 0, "apply-without-grants-refused")
        try actionDriver.send("setup", .grant(true, false, true)); try actionDriver.send("setup", .submit); tick(); try check(enabled.submissions == 0, "docker-consent-independent")
        try actionDriver.send("setup", .grant(true, true, true)); try actionDriver.send("setup", .submit); tick(); try check(enabled.submissions == 0, "uninspected-task-cannot-submit")
        try actionDriver.send("setup", .inspect); try until { actionDriver.state("setup", "inspected") == "1" }
        try actionDriver.send("setup", .grant(true, true, false)); try actionDriver.send("setup", .submit); tick(); try check(enabled.submissions == 0, "task-trust-independent")
        try actionDriver.send("setup", .grant(true, true, true)); tick(); actionHost.scroll(bottom: true); tick(); try capture(actionHost, "setup-fake-consent-dark.png", screen: actionDriver.terminalScreen)
        try actionDriver.send("setup", .submit); try until { enabled.submissions == 1 }
        try actionDriver.send("setup", .submit); tick(); try check(enabled.submissions == 1, "submission-attempt-not-replayed")
        actionHost.close()
        let failedHistory = try enabled.row(UUID(), stage: "failed")
        let completedHistory = try enabled.row(UUID(), stage: "succeeded")
        enabledModel.setupWorkflows = [failedHistory, completedHistory]
        try check(enabledModel.setupSummary(for: profile.id)?.title == "Setup history (2 runs)", "home-does-not-infer-history-order-from-uuid")
        enabledModel.setupWorkflows.reverse()
        try check(enabledModel.setupSummary(for: profile.id)?.title == "Setup history (2 runs)", "home-history-order-independent")
        let cleanupHistory = try enabled.row(UUID(), stage: "cleanupRequired", cleanupRequired: true)
        enabledModel.setupWorkflows.append(cleanupHistory)
        try check(enabledModel.setupSummary(for: profile.id)?.cleanupRequired == true, "home-prioritizes-unresolved-cleanup")
        let workflow = try enabled.row(UUID(), stage: "running")
        enabledModel.setupWorkflows = [workflow]
        enabledModel.snapshots = [.init(profile: profile, state: .running, sessionID: workflow.originalSessionID,
            sshReadiness: .ready(user: "fixture_owner", command: "synthetic-unused"))]
        let runningDriver = SetupUIAcceptanceDriver()
        let running = Host(ManagerView(model: enabledModel, acceptanceGuestID: profile.id), driver: runningDriver, width: 1200, height: 960, dark: true)
        defer { running.close() }; tick(); try until { runningDriver.terminalScreen != nil }
        let screen = runningDriver.terminalScreen!
        try check(screen.follow, "terminal-default-follows-output")
        screen.render(Data("first\nsecond".utf8))
        try check(String(decoding: screen.view.getBufferAsData(), as: UTF8.self).contains("\nsecond"), "terminal-pipe-lf-starts-at-column-zero")
        screen.resetScreen(); screen.render(Data("first\r".utf8)); screen.render(Data("\nsecond".utf8))
        try check(String(decoding: screen.view.getBufferAsData(), as: UTF8.self).contains("\nsecond"), "terminal-split-pty-crlf-remains-single-newline")
        screen.resetScreen()

        screen.render(Data("SYNTHETIC ACCEPTANCE OUTPUT — no live job\r\n\u{001B}[32mok: [fixture]\u{001B}[0m\r\nUnicode → café ✓\r\n".utf8))
        try runningDriver.send("setup", .search("café")); try check(runningDriver.state("setup", "matches") == "1", "full-screen-literal-terminal-search")
        screen.jumpToLatest(); tick(); try check(screen.follow, "terminal-jump-to-latest-restores-follow")
        screen.scrolled(source: screen.view, position: 0); try check(screen.follow, "terminal-layout-scroll-does-not-disable-follow")
        try check(screen.fontSize == 11 && screen.view.font.pointSize <= 11, "terminal-denser-default-font")
        let dimensions = screen.view.terminalStateSnapshot().dimensions
        try check(dimensions.cols >= 120 && dimensions.rows >= 30, "terminal-modern-grid-fits-normal-manager-width")

        try runningDriver.send("setup", .requestCancel); tick(); try check(enabled.cancellations == 0 && runningDriver.state("setup", "cancelPending") == "true", "cancel-needs-confirmation")
        try runningDriver.send("setup", .confirmCancel); try until { enabled.cancellations == 1 }
        try check(!screen.connected && !screen.ownsInput, "synthetic-output-grants-no-input")
        running.scroll(bottom: true); tick(); try capture(running, "setup-terminal-dark.png", screen: screen)
        enabledModel.setupWorkflows = [completedHistory]; tick()
        try check(runningDriver.state("setup", "continuation") == "Setup has finished. Its result remains saved.", "completed-setup-does-not-claim-running")
        running.close(); tick(); try check(enabled.cancellations == 1, "view-disappear-detaches-not-cancels")
        // Home renders from synthetic snapshots only; nothing here is launched.
        var downloading = VMProfile(id: UUID(), name: "Synthetic downloading"); downloading.diskGiB = 64
        let failed = VMProfile(id: UUID(), name: "Synthetic failed")
        enabledModel.setupWorkflows = []
        enabledModel.snapshots = [.init(profile: profile, state: .stopped), .init(profile: downloading, state: .downloading(phase: .downloading, percent: 48), sessionID: UUID()),
            .init(profile: failed, state: .failed(VMFailure(code: "synthetic", message: "The download could not finish.")), lastFailure: VMFailure(code: "synthetic", message: "The download could not finish."))]
        for page in ["Home", "Network", "SSH", "Spaces"] {
            let pageHost = Host(ManagerView(model: enabledModel, acceptanceGuestID: profile.id, acceptancePage: page), driver: SetupUIAcceptanceDriver(), width: 1200, height: 960, dark: true)
            tick(); try capture(pageHost, "guest-" + page.lowercased() + "-dark.png"); pageHost.close()
        }
        // First run: synthetic guest, SSH and workflow states only; nothing is launched.
        let digest = String(repeating: "e", count: 64)
        var firstRun = profile
        firstRun.developerSetup = try JSONDecoder().decode(ProvisioningSelectionReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "reviewID": UUID().uuidString, "vmID": profile.id.uuidString, "reviewIdentity": digest, "planDigest": digest,
            "inputDigest": digest, "engineDigest": digest, "configurationDigest": digest]))
        let session = UUID()
        func progress(_ state: VMState, ssh: SSHReadiness = .stopped, _ rows: [ProvisioningWorkflowSnapshot] = [], jobs: [UUID: ProvisioningJobSnapshot] = [:]) -> FirstRunProgress? {
            FirstRunProgress.make(.init(profile: firstRun, state: state, sessionID: state == .stopped ? nil : session, sshReadiness: ssh), workflows: rows, jobs: jobs)
        }
        try check(FirstRunProgress.make(.init(profile: profile, state: .running, sshReadiness: .ready(user: "fixture_owner", command: "synthetic-unused")), workflows: [], jobs: [:]) == nil, "first-run-only-for-setup-guests")
        try check(progress(.stopped)?.step == .created && progress(.stopped)?.setupAction == nil, "first-run-stopped-waits-for-explicit-launch")
        try check(progress(.running, ssh: .waitingForOwner)?.step == .firstBoot, "first-run-owner-step-from-ssh-state")
        try check(progress(.running, ssh: .connecting)?.step == .connecting, "first-run-connecting-from-ssh-state")
        let approveNoJob = progress(.running, ssh: .ready(user: "fixture_owner", command: "synthetic-unused"))
        try check(approveNoJob?.step == .approve && approveNoJob?.tone == .needsYou && approveNoJob?.setupAction != nil, "first-run-approval-routes-to-setup-review")
        try check(progress(.running, ssh: .ready(user: "fixture_owner", command: "synthetic-unused"), [completedHistory]) == nil, "first-run-hidden-after-success")
        try check(progress(.running, ssh: .ready(user: "fixture_owner", command: "synthetic-unused"), [failedHistory, try enabled.row(UUID(), stage: "cancelled")])?.tone == .problem, "first-run-unordered-history-not-guessed")
        let installing = try enabled.row(UUID(), stage: "running")
        let job = try JSONDecoder().decode(ProvisioningJobSnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "jobID": UUID().uuidString, "vmID": profile.id.uuidString, "sessionID": session.uuidString, "sequence": 1, "state": "running",
            "cleanupFailures": [] as [Any], "cleanupRequired": true, "workerOutstanding": true]))
        try check(progress(.running, [installing])?.terminal == nil, "first-run-terminal-waits-for-admitted-job")
        try check(progress(.running, [installing], jobs: [installing.id: job])?.terminal?.workflowID == installing.id, "first-run-terminal-attaches-admitted-job")
        enabledModel.setupCompletedThisRun = []
        enabledModel.noteSetupCompletions(previous: [installing], current: [try enabled.row(installing.id, stage: "succeeded")])
        try check(enabledModel.setupCompletedThisRun == [profile.id], "first-run-completion-observed-transition-only")
        enabledModel.setupCompletedThisRun = []
        enabledModel.noteSetupCompletions(previous: [], current: [completedHistory])
        try check(enabledModel.setupCompletedThisRun.isEmpty, "first-run-old-success-not-announced")
        for (name, ssh, rows, jobs) in [
            ("first-run-connecting-dark.png", SSHReadiness.connecting, [ProvisioningWorkflowSnapshot](), [UUID: ProvisioningJobSnapshot]()),
            ("first-run-approve-dark.png", .ready(user: "fixture_owner", command: "synthetic-unused"), [try enabled.row(UUID(), stage: "readyForReview")], [:]),
            ("first-run-installing-dark.png", .ready(user: "fixture_owner", command: "synthetic-unused"), [installing], [installing.id: job])
        ] {
            enabledModel.snapshots = [.init(profile: firstRun, state: .running, sessionID: session, sshReadiness: ssh)]
            enabledModel.setupWorkflows = rows; enabledModel.setupJobs = jobs
            let pageHost = Host(ManagerView(model: enabledModel, acceptanceGuestID: profile.id, acceptancePage: "Home"), driver: SetupUIAcceptanceDriver(), width: 1200, height: 960, dark: true)
            tick(); try capture(pageHost, name); pageHost.close(); tick()
        }
        // A failed run says what failed from recorded categories and keeps its ended terminal entry.
        let failedRun = try enabled.row(installing.id, stage: "failed")
        let failedJob = try JSONDecoder().decode(ProvisioningJobSnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "jobID": job.jobID.uuidString, "vmID": profile.id.uuidString, "sessionID": session.uuidString, "sequence": 2, "state": "failed",
            "engineFailure": "adapterFailed", "cleanupFailures": [] as [Any], "cleanupRequired": false, "workerOutstanding": false]))
        let failedProgress = progress(.running, ssh: .ready(user: "fixture_owner", command: "synthetic-unused"), [failedRun], jobs: [failedRun.id: failedJob])
        try check(failedProgress?.tone == .problem && failedProgress?.note.contains("task failed inside the guest") == true, "first-run-failure-names-recorded-category")
        try check(failedProgress?.terminal?.workflowID == failedRun.id && failedProgress?.terminal?.live == false, "first-run-failed-keeps-ended-terminal")
        // Installing finished and the run waits for a reviewed restart: say so, don't look stuck.
        let restartRun = try enabled.row(installing.id, stage: "restartRequired")
        let restartJob = try JSONDecoder().decode(ProvisioningJobSnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "jobID": job.jobID.uuidString, "vmID": profile.id.uuidString, "sessionID": session.uuidString, "sequence": 2, "state": "restartRequired",
            "cleanupFailures": [] as [Any], "cleanupRequired": false, "workerOutstanding": false]))
        let restartProgress = progress(.running, ssh: .ready(user: "fixture_owner", command: "synthetic-unused"), [restartRun], jobs: [restartRun.id: restartJob])
        try check(restartProgress?.step == .restart && restartProgress?.tone == .needsYou && restartProgress?.setupAction == "Review restart…"
                  && restartProgress?.note.hasPrefix("Software installed") == true && restartProgress?.terminal?.live == false, "first-run-restart-required-is-not-installing")
        // Official image download shows where the image comes from, from pinned manifests only.
        do {
            let source = try OfficialFactorySource.acceptanceFixture().unwrap()
            try check(source.releaseTag == "v1.3.0" && source.parts.count == 3, "factory-source-fixture-parses")
            var downloadingProfile = profile; downloadingProfile.factory = .official
            let downloadingSnapshot = VMSnapshot(profile: downloadingProfile, state: .downloading(phase: .downloading, percent: 48), sessionID: UUID())
            try check(GuestFactoryDownloadCard.phase(downloadingSnapshot) != nil
                      && GuestFactoryDownloadCard.phase(.init(profile: downloadingProfile, state: .running, sessionID: session)) == nil, "factory-download-card-only-while-downloading")
            enabledModel.officialFactorySource = source
            enabledModel.snapshots = [downloadingSnapshot]; enabledModel.setupWorkflows = []; enabledModel.setupJobs = [:]
            let pageHost = Host(ManagerView(model: enabledModel, acceptanceGuestID: profile.id, acceptancePage: "Home"), driver: SetupUIAcceptanceDriver(), width: 1200, height: 960, dark: true)
            tick(); try capture(pageHost, "guest-factory-download-dark.png"); pageHost.close(); tick()
        }
        // Home setup card (replaces the Setup tab): state only from recorded workflow and job state.
        func card(_ rows: [ProvisioningWorkflowSnapshot], jobs: [UUID: ProvisioningJobSnapshot] = [:], auto: AutoSetupState? = nil, profile p: VMProfile? = nil) -> SetupCardState {
            SetupCardState.make(.init(profile: p ?? firstRun, state: .running, sessionID: session), workflows: rows, jobs: jobs, autoSetup: auto)
        }
        try check(card([], profile: profile).kind == .none && card([]).kind == .configured, "setup-card-none-and-configured")
        try check(card([installing], jobs: [installing.id: job]).kind == .running && card([installing], jobs: [installing.id: job]).progress == 0, "setup-card-running-shows-progress")
        try check(card([restartRun]).kind == .needsYou && card([restartRun]).run.contains("Restart"), "setup-card-manual-restart-needs-review")
        let followingAuto = AutoSetupState.following(receipt: try firstRun.developerSetup.unwrap(), workflowID: restartRun.id, attempted: [.restart])
        try check(card([restartRun], auto: followingAuto).kind == .running, "setup-card-approved-restart-is-progress")
        try check(card([try enabled.row(installing.id, stage: "failed", cleanupRequired: true)]).kind == .cleanup, "setup-card-cleanup-needs-recovery")
        try check(card([failedRun], jobs: [failedRun.id: failedJob]).kind == .failed && card([try enabled.row(installing.id, stage: "checked")]).kind == .succeeded, "setup-card-failed-and-succeeded")
        do {
            enabledModel.snapshots = [.init(profile: firstRun, state: .running, sessionID: session, sshReadiness: .ready(user: "fixture_owner", command: "synthetic-unused"))]
            enabledModel.setupWorkflows = [try enabled.row(installing.id, stage: "checked")]; enabledModel.setupJobs = [:]
            let pageHost = Host(ManagerView(model: enabledModel, acceptanceGuestID: profile.id, acceptancePage: "Home"), driver: SetupUIAcceptanceDriver(), width: 1200, height: 960, dark: true)
            tick(); pageHost.scroll(bottom: true); tick(); try capture(pageHost, "guest-setup-card-dark.png"); pageHost.close(); tick()
            let current = enabledModel.snapshots[0]
            for (name, mode, title) in [("setup-change-sheet-dark.png", DeveloperSetupView.Mode.change, "Change setup"), ("setup-output-sheet-dark.png", .output, "Setup output")] {
                let status = mode == .output ? SetupCardState.make(current, workflows: enabledModel.setupWorkflows, jobs: [:], autoSetup: nil) : nil
                let sheet = Host(SetupSheetFrame(title: title, subtitle: current.profile.name, status: status, close: {}) { DeveloperSetupView(model: enabledModel, snapshot: current, mode: mode) },
                                 driver: SetupUIAcceptanceDriver(), width: 960, height: 820, dark: true)
                tick(); try capture(sheet, name); sheet.close(); tick()
            }
            enabledModel.setupWorkflows = []
        }
        enabledModel.snapshots = [.init(profile: firstRun, state: .running, sessionID: session, sshReadiness: .ready(user: "fixture_owner", command: "synthetic-unused"))]
        enabledModel.setupWorkflows = [failedRun]; enabledModel.setupJobs = [failedRun.id: failedJob]
        let failedHost = Host(ManagerView(model: enabledModel, acceptanceGuestID: profile.id, acceptancePage: "Home"), driver: SetupUIAcceptanceDriver(), width: 1200, height: 960, dark: true)
        // A freshly built page never watched this run, so no empty output panel appears.
        tick(); try capture(failedHost, "first-run-failed-dark.png"); failedHost.close(); tick()
        // The Setup tab shows the saved last-run log for a finished run, read-only.
        enabled.savedLog = Data("[Omarchy VM Manager setup output · apply · synthetic fixture]\r\nTASK [synthetic : Install packages] ***\r\n\u{001B}[31mfatal: [workstation]: FAILED! synthetic saved failure\u{001B}[0m\r\n\r\n[setup failed]\r\n".utf8)
        let attemptsBeforeLog = enabled.terminalAttempts
        enabledModel.snapshots = [.init(profile: firstRun, state: .running, sessionID: session, sshReadiness: .ready(user: "fixture_owner", command: "synthetic-unused"))]
        enabledModel.setupWorkflows = [failedRun]; enabledModel.setupJobs = [failedRun.id: failedJob]
        let logDriver = SetupUIAcceptanceDriver()
        let logHost = Host(ManagerView(model: enabledModel, acceptanceGuestID: profile.id, acceptancePage: "Setup"), driver: logDriver, width: 1200, height: 960, dark: true)
        tick(); try until { logDriver.state("setup", "savedLog") == "true" }
        try check(logDriver.terminalScreen != nil, "setup-tab-saved-log-screen-bound")
        let logScreen = logDriver.terminalScreen!
        try check(String(decoding: logScreen.view.getBufferAsData(), as: UTF8.self).contains("synthetic saved failure"), "setup-tab-shows-saved-log")
        try check(enabled.terminalAttempts == attemptsBeforeLog, "setup-tab-saved-log-does-not-reattach-ended-job")
        logHost.scroll(bottom: true); tick(); try capture(logHost, "setup-saved-log-dark.png", screen: logScreen); logHost.close(); tick()
        enabled.savedLog = nil
        // Loading mark: a filmstrip across both laps (back square, then front square).
        let line = StrokeStyle(lineWidth: 120 * 7 / 300, lineCap: .round, lineJoin: .round)
        let strip = VStack(spacing: 16) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 16) {
                    ForEach(0..<6, id: \.self) { column in
                        CyclingFramesFrame(time: CyclingFramesFrame.lap * (Double(row) + (Double(column) + 0.5) / 6), frame: Theme.idleFrame, tracer: Theme.green, line: line)
                            .frame(width: 120, height: 120)
                    }
                }
            }
        }.padding(24).frame(width: 880, height: 780).background(Theme.ground)
        let stripHost = Host(strip, driver: SetupUIAcceptanceDriver(), width: 880, height: 780, dark: true)
        tick(); try capture(stripHost, "loading-mark-filmstrip-dark.png"); stripHost.close(); tick()
        // Approve at creation: one automatic first apply, admin access only, single use.
        let autoID = UUID()
        let autoPreview = try run { try await enabled.preview(id: autoID, vmID: profile.id, source: .init(preset: "developer")) }
        var autoProfile = profile
        autoProfile.ssh = SSHOptions(hostPort: 2222)
        autoProfile.developerSetup = try JSONDecoder().decode(ProvisioningSelectionReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "reviewID": autoID.uuidString, "vmID": profile.id.uuidString, "reviewIdentity": digest, "planDigest": autoPreview.planDigest,
            "inputDigest": autoPreview.inputDigest, "engineDigest": autoPreview.engineDigest, "configurationDigest": digest]))
        let ready = SSHReadiness.ready(user: "fixture_owner", command: "synthetic-unused")
        func autoSnapshot(_ session: UUID?, _ ssh: SSHReadiness) -> VMSnapshot { .init(profile: autoProfile, state: session == nil ? .stopped : .running, sessionID: session, sshReadiness: ssh) }
        func renderAuto(_ name: String) throws {
            let pageHost = Host(ManagerView(model: enabledModel, acceptanceGuestID: profile.id, acceptancePage: "Home"), driver: SetupUIAcceptanceDriver(), width: 1200, height: 960, dark: true)
            tick(); try capture(pageHost, name); pageHost.close(); tick()
        }
        enabledModel.setupWorkflows = []; enabledModel.setupJobs = [:]; enabledModel.autoSetup = [:]
        let submissionsBefore = enabled.submissions
        enabled.reviewSession = session
        enabledModel.snapshots = [autoSnapshot(session, .connecting)]
        enabledModel.armAutoSetup(profile.id); enabledModel.advanceAutoSetup()
        let armed = FirstRunProgress.make(enabledModel.snapshots[0], workflows: [], jobs: [:], autoSetup: enabledModel.autoSetup[profile.id])
        try check(armed?.approvedAtCreation == true && armed?.steps.contains(.approve) == false && armed?.step == .connecting, "auto-setup-armed-has-no-approve-step")
        try renderAuto("first-run-auto-connecting-dark.png")
        enabledModel.snapshots = [autoSnapshot(session, ready)]; enabledModel.advanceAutoSetup()
        try until { enabledModel.autoSetup[profile.id] != .applying }
        try check(enabledModel.autoSetup[profile.id]?.blockedReason?.contains("Docker") == true && enabled.submissions == submissionsBefore, "auto-setup-refuses-wider-permissions")
        let blocked = FirstRunProgress.make(enabledModel.snapshots[0], workflows: [], jobs: [:], autoSetup: enabledModel.autoSetup[profile.id])
        try check(blocked?.step == .approve && blocked?.tone == .needsYou && blocked?.setupAction != nil, "auto-setup-blocked-falls-back-to-review")
        try renderAuto("first-run-auto-blocked-dark.png")
        enabled.adminOnlyReview = true; enabled.reviewSession = session; enabled.lastConsent = nil
        enabledModel.autoSetup = [:]; enabledModel.snapshots = [autoSnapshot(session, .connecting)]
        enabledModel.armAutoSetup(profile.id); enabledModel.advanceAutoSetup()
        enabledModel.snapshots = [autoSnapshot(session, ready)]; enabledModel.advanceAutoSetup()
        try until { enabledModel.autoSetup[profile.id] != .applying && enabled.lastConsent != nil }
        try check(enabled.submissions == submissionsBefore + 1 && enabled.lastConsent?.persistentGrantAcknowledged == true
                  && enabled.lastConsent?.dockerRootAccessAcknowledged == false && enabled.lastConsent?.taskTrustIdentity == nil, "auto-setup-submits-admin-only-consent")
        enabledModel.advanceAutoSetup(); tick()
        let following: Bool = { if case .following(_, let id, let tried) = enabledModel.autoSetup[profile.id], id == autoID, tried.isEmpty { return true }; return false }()
        try check(enabled.submissions == submissionsBefore + 1 && following, "auto-setup-single-use")
        // The same approval finishes setup: restart once, then check once; never recovery.
        enabled.actionSubmissions = []
        // While installing, the run is marked cleanup-required until admin access is removed; keep following.
        enabledModel.setupWorkflows = [try enabled.row(autoID, stage: "running", cleanupRequired: true)]; enabledModel.advanceAutoSetup(); tick()
        let stillFollowing: Bool = { if case .following = enabledModel.autoSetup[profile.id] { return true }; return false }()
        try check(stillFollowing && enabled.actionSubmissions.isEmpty, "auto-setup-follows-through-install-cleanup")
        enabledModel.setupWorkflows = [try enabled.row(autoID, stage: "restartRequired")]; enabledModel.advanceAutoSetup()
        try until { enabled.actionSubmissions == [.restart] }
        let restarting = FirstRunProgress.make(enabledModel.snapshots[0], workflows: enabledModel.setupWorkflows, jobs: [:], autoSetup: enabledModel.autoSetup[profile.id])
        try check(restarting?.step == .restart && restarting?.tone == .working && restarting?.setupAction == nil, "auto-setup-restart-shown-as-progress")
        enabledModel.advanceAutoSetup(); tick()
        try check(enabled.actionSubmissions == [.restart], "auto-setup-restarts-once")
        // After the restart the run waits for rebind; the check starts once the new session's SSH is ready.
        let newSession = UUID()
        var rebind = try enabled.row(autoID, stage: "waitingForRebind")
        rebind = try JSONDecoder().decode(ProvisioningWorkflowSnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "id": autoID.uuidString, "vmID": profile.id.uuidString, "originalSessionID": session.uuidString, "sequence": 3,
            "stage": "waitingForRebind", "cleanupRequired": false, "applyJobID": autoID.uuidString, "newSessionID": newSession.uuidString]))
        enabledModel.snapshots = [autoSnapshot(newSession, .connecting)]
        enabledModel.setupWorkflows = [rebind]; enabledModel.advanceAutoSetup(); tick()
        try check(enabled.actionSubmissions == [.restart], "auto-setup-check-waits-for-new-session-ssh")
        enabledModel.snapshots = [autoSnapshot(newSession, ready)]; enabledModel.advanceAutoSetup()
        try until { enabled.actionSubmissions == [.restart, .check] }
        enabledModel.advanceAutoSetup(); tick()
        try check(enabled.actionSubmissions == [.restart, .check], "auto-setup-checks-once")
        enabledModel.setupWorkflows = [try enabled.row(autoID, stage: "failed", cleanupRequired: true)]; enabledModel.advanceAutoSetup(); tick()
        try check(enabled.actionSubmissions == [.restart, .check] && enabledModel.autoSetup[profile.id] == .consumed, "auto-setup-never-recovers")
        enabledModel.setupWorkflows = []
        enabledModel.autoSetup = [:]; enabledModel.snapshots = [autoSnapshot(session, .connecting)]
        enabledModel.armAutoSetup(profile.id); enabledModel.advanceAutoSetup()
        enabledModel.snapshots = [autoSnapshot(UUID(), ready)]; enabledModel.advanceAutoSetup(); tick()
        try check(enabledModel.autoSetup[profile.id]?.blockedReason?.contains("restarted") == true && enabled.submissions == submissionsBefore + 1, "auto-setup-bound-to-first-session")
        enabledModel.autoSetup = [:]; enabledModel.snapshots = [.init(profile: profile, state: .running, sessionID: session, sshReadiness: ready)]
        enabledModel.armAutoSetup(profile.id)
        try check(enabledModel.autoSetup.isEmpty, "auto-setup-needs-setup-and-ssh")
        enabled.adminOnlyReview = false; enabled.reviewSession = nil
        enabledModel.setupWorkflows = []; enabledModel.setupJobs = [:]
        enabledModel.snapshots = [.init(profile: profile, state: .stopped), .init(profile: downloading, state: .downloading(phase: .downloading, percent: 48), sessionID: UUID()),
            .init(profile: failed, state: .failed(VMFailure(code: "synthetic", message: "The download could not finish.")), lastFailure: VMFailure(code: "synthetic", message: "The download could not finish."))]
        // Setup attention (issue #16): one Core state read by the card, first-run tracker, sidebar,
        // Dock and notifications. Recording surfaces only: no Dock, notification or permission.
        do {
            func jobState(_ id: UUID, _ state: String, extra: [String: Any] = [:]) throws -> ProvisioningJobSnapshot {
                let unfinished = ["running", "awaitingAuthorization"].contains(state)
                var object: [String: Any] = ["jobID": id.uuidString, "vmID": profile.id.uuidString, "sessionID": session.uuidString, "sequence": 2, "state": state,
                                             "cleanupFailures": [] as [Any], "cleanupRequired": unfinished, "workerOutstanding": unfinished]
                object.merge(extra) { $1 }
                return try JSONDecoder().decode(ProvisioningJobSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            }
            let receipt = try firstRun.developerSetup.unwrap()
            let autos: [AutoSetupState?] = [nil, .armed(receipt: receipt, sessionID: session), .following(receipt: receipt, workflowID: UUID(), attempted: []),
                                            .blocked("Synthetic blocked reason."), .consumed]
            let stages = ["waitingForSSH", "readyForReview", "running", "restartRequired", "waitingForExit", "restarting", "waitingForRebind",
                          "readyForCheck", "checking", "succeeded", "checked", "failed", "cancelled", "interrupted", "cleanupRequired"]
            var disagreements: [String] = []
            func compare(_ snapshot: VMSnapshot, _ rows: [ProvisioningWorkflowSnapshot], _ jobs: [UUID: ProvisioningJobSnapshot], _ auto: AutoSetupState?, _ label: String) {
                let reason = SetupAttention.make(snapshot, workflows: rows, jobs: jobs, auto: SetupAutoApproval(auto))?.reason
                if !rows.isEmpty {
                    let kind = SetupCardState.make(snapshot, workflows: rows, jobs: jobs, autoSetup: auto).kind
                    let cardAgrees = reason == nil ? ![.needsYou, .cleanup].contains(kind) : reason == .cleanup ? kind == .cleanup : kind == .needsYou
                    if !cardAgrees { disagreements.append("card " + label) }
                }
                if let tracker = FirstRunProgress.make(snapshot, workflows: rows, jobs: jobs, autoSetup: auto) {
                    let trackerAgrees = (tracker.tone == .needsYou) == (reason != nil && reason != .cleanup) && (reason != .cleanup || tracker.tone == .problem)
                    if !trackerAgrees { disagreements.append("tracker " + label) }
                }
            }
            let readySnapshot = VMSnapshot(profile: firstRun, state: .running, sessionID: session, sshReadiness: ready)
            for stage in stages {
                for state in [nil, "running", "awaitingAuthorization"] as [String?] {
                    for cleanup in [false, true] {
                        for (index, auto) in autos.enumerated() {
                            let id = UUID(), row = try enabled.row(id, stage: stage, cleanupRequired: cleanup)
                            let jobs = try state.map { [id: try jobState(id, $0)] } ?? [:]
                            compare(readySnapshot, [row], jobs, auto, "\(stage) \(state ?? "-") \(cleanup) \(index)")
                        }
                    }
                }
            }
            for (index, auto) in autos.enumerated() {
                for (name, snapshot) in [("ready", readySnapshot), ("connecting", VMSnapshot(profile: firstRun, state: .running, sessionID: session, sshReadiness: .connecting)),
                                         ("stopped", VMSnapshot(profile: firstRun, state: .stopped))] {
                    compare(snapshot, [], [:], auto, "no-run \(name) \(index)")
                }
            }
            if !disagreements.isEmpty { print("attention disagreements: " + disagreements.joined(separator: "; ")) }
            try check(disagreements.isEmpty, "attention-card-and-first-run-agree")
            let timedOut = try enabled.row(UUID(), stage: "failed")
            let timedOutJob = try jobState(timedOut.id, "timedOut", extra: ["engineFailure": "timedOut", "timedOutOperation": "requestPersistentGrant"])
            try check(SetupCardState.make(readySnapshot, workflows: [timedOut], jobs: [timedOut.id: timedOutJob], autoSetup: nil).note
                      == "Setup timed out: Omarchy’s passwordless sudo prompt wasn’t answered within an hour.", "attention-timeout-names-the-step")

            // Issue #24: a stopped guest's unverifiable cleanup can only be released, never recovered.
            let heldRow = try enabled.row(UUID(), stage: "failed", cleanupRequired: true)
            try check(DeveloperSetupView.visibleActions(heldRow, guestRunning: false) == [.release]
                      && DeveloperSetupView.visibleActions(heldRow, guestRunning: true) == [.recover], "cleanup-release-offered-only-when-stopped")
            let confirmation = DeveloperSetupView.releaseConfirmation
            try check(confirmation.contains("wasn’t verified") && confirmation.contains("passwordless sudo"), "cleanup-release-confirmation-says-unverified")
            let stoppedHeld = SetupCardState.make(VMSnapshot(profile: firstRun, state: .stopped), workflows: [heldRow], jobs: [:], autoSetup: nil)
            try check(stoppedHeld.kind == .cleanup && stoppedHeld.note.contains("can’t be verified"), "cleanup-stopped-card-explains-release")
            let releasedRow = try JSONDecoder().decode(ProvisioningWorkflowSnapshot.self, from: JSONSerialization.data(withJSONObject: [
                "id": heldRow.id.uuidString, "vmID": profile.id.uuidString, "originalSessionID": session.uuidString, "sequence": 3, "stage": "failed",
                "cleanupRequired": false, "applyJobID": heldRow.id.uuidString, "cleanupRelease": "unverified"]))
            let released = SetupCardState.make(VMSnapshot(profile: firstRun, state: .stopped), workflows: [releasedRow], jobs: [:], autoSetup: nil)
            try check(released.kind == .failed && released.note.contains("released without verification")
                      && SetupAttention.make(VMSnapshot(profile: firstRun, state: .stopped), workflows: [releasedRow], jobs: [:]) == nil
                      && releasedRow.title == "Cleanup released without verification", "cleanup-released-history-says-unverified")

            // Sidebar: a badge only on the guest that is waiting; clicking it opens the right place.
            let second = VMProfile(id: UUID(), name: "Synthetic second guest", clipboardEnabled: false)
            // Its own model: earlier closed hosts still observe the shared fixture model.
            let attentionModel = AppModel(isolatedManager: manager, support: support, snapshots: [], service: enabled, save: { try await enabled.save($0, consent: $1) })
            let sudoRow = try enabled.row(UUID(), stage: "running")
            attentionModel.snapshots = [readySnapshot, .init(profile: second, state: .stopped)]
            attentionModel.setupWorkflows = [sudoRow]; attentionModel.setupJobs = [sudoRow.id: try jobState(sudoRow.id, "awaitingAuthorization")]; attentionModel.autoSetup = [:]
            let sideDriver = SetupUIAcceptanceDriver()
            let side = Host(ManagerView(model: attentionModel), driver: sideDriver, width: 1200, height: 960, dark: true)
            tick(); try waitFor("attention-wait-1") { sideDriver.scopes["manager"] != nil && sideDriver.scopes["needs-you:" + profile.id.uuidString] != nil }
            try check(sideDriver.scopes["needs-you:" + second.id.uuidString] == nil && attentionModel.setupAttention.keys.sorted() == [profile.id], "attention-sidebar-badge-only-for-waiting-guest")
            try capture(side, "attention-sidebar-dark.png")
            try sideDriver.send("needs-you:" + profile.id.uuidString, .submit)
            tick(0.3) // Let the window handle the route before polling its state.
            try waitFor("attention-wait-2") { sideDriver.state("manager", "guest") == profile.id.uuidString && sideDriver.state("manager", "sheet") == "output" }
            try check(sideDriver.state("manager", "page") == "Home", "attention-badge-opens-output-at-sudo-prompt")
            try check(attentionModel.visibleGuest == profile.id, "attention-visible-guest-reported")
            // A notification click calls the same route, worked out when clicked.
            attentionModel.setupWorkflows = [try enabled.row(sudoRow.id, stage: "restartRequired")]; attentionModel.setupJobs = [:]
            attentionModel.openAttention(profile.id)
            tick(0.5)
            try waitFor("attention-wait-3") { sideDriver.state("manager", "sheet") == "change" }
            try check(sideDriver.state("manager", "guest") == profile.id.uuidString, "attention-notification-click-opens-review")
            attentionModel.openAttention(second.id)
            tick(0.5) // Sheet dismissal and the guest switch settle over a few run-loop turns.
            try waitFor("attention-wait-4") { sideDriver.state("manager", "guest") == second.id.uuidString }
            tick(); try check(sideDriver.state("manager", "sheet").isEmpty && sideDriver.state("manager", "page") == "Home", "attention-stale-click-opens-home-only")
            side.close(); tick()

            // Dock and notifications through the Core tracker, recorded only.
            let surfaces = RecordingAttentionSurfaces()
            attentionModel.attentionSurfaces = surfaces; attentionModel.attentionTracker = SetupAttentionTracker(); attentionModel.visibleGuest = nil
            attentionModel.snapshots = [VMSnapshot(profile: firstRun, state: .running, sessionID: session, sshReadiness: .connecting), .init(profile: second, state: .stopped)]
            attentionModel.setupWorkflows = []; attentionModel.setupJobs = [:]
            attentionModel.refreshAttention(appActive: false)
            attentionModel.snapshots[0] = readySnapshot
            attentionModel.setupWorkflows = [sudoRow]; attentionModel.setupJobs = [sudoRow.id: try jobState(sudoRow.id, "awaitingAuthorization")]
            attentionModel.refreshAttention(appActive: false)
            try check(surfaces.events == ["bounce", "notify:" + firstRun.name + ":Omarchy is asking to enable passwordless sudo.", "marker:true"], "attention-blocked-guest-notifies-bounces-and-marks-dock")
            attentionModel.refreshAttention(appActive: false); attentionModel.refreshAttention(appActive: true)
            try check(surfaces.events.count == 3, "attention-no-repeat-notifications")
            attentionModel.setupJobs = [sudoRow.id: try jobState(sudoRow.id, "running")]
            attentionModel.refreshAttention(appActive: true)
            try check(surfaces.events.suffix(2) == ["clear:" + profile.id.uuidString, "marker:false"], "attention-handled-clears-notification-and-marker")
            attentionModel.setupWorkflows = [try enabled.row(UUID(), stage: "readyForReview")]; attentionModel.setupJobs = [:]
            attentionModel.refreshAttention(appActive: false)
            try check(surfaces.events.count == 5 && attentionModel.setupAttention[profile.id]?.reason == .review, "attention-saved-review-no-notification-or-dock")
            attentionModel.setupWorkflows = [try enabled.row(UUID(), stage: "restartRequired")]; attentionModel.visibleGuest = profile.id
            attentionModel.refreshAttention(appActive: true)
            try check(surfaces.events.count == 6 && surfaces.events.last == "marker:true", "attention-on-screen-guest-not-notified")
            attentionModel.attentionSurfaces = nil; attentionModel.attentionTracker = SetupAttentionTracker(); attentionModel.visibleGuest = nil
        }
        for page in ["permissions", "runtime"] {
            let pageHost = Host(ManagerView(model: enabledModel, acceptanceManagerPage: page), driver: SetupUIAcceptanceDriver(), width: 1200, height: 960, dark: true)
            tick(); try capture(pageHost, page + "-dark.png"); pageHost.close()
        }
        for dark in [true, false] {
            // Layout comes before Customise, and choosing a layout turns setup on.
            let suffix = dark ? "dark" : "light", layoutDriver = SetupUIAcceptanceDriver()
            let layoutHost = Host(VMEditor(model: enabledModel, profile: nil, saved: { _ in }), driver: layoutDriver, width: 640, height: 820, dark: dark)
            tick(); try until { layoutDriver.scopes["selection"] != nil && layoutDriver.scopes["layout-cards"] != nil && layoutDriver.state("layout-cards", "count") == "7" }
            try check(layoutDriver.state("editor", "panes") == "layout,customise,resources,access", suffix + "-layout-pane-before-customise")
            try check(layoutDriver.state("selection", "source") == "none" && layoutDriver.state("editor", "hasSetup") == "false", suffix + "-layout-pane-starts-without-setup")
            try layoutDriver.send("editor", .name("Layout first")); try layoutDriver.send("layout-cards", .layoutExample(.vscodeBrowser)); tick()
            try check(layoutDriver.state("selection", "source") == "bundled" && layoutDriver.state("selection", "profiles") == "developer"
                      && layoutDriver.state("selection", "layout") == "vscode-browser" && layoutDriver.state("editor", "hasSetup") == "true"
                      && layoutDriver.state("editor", "canSave") == "true", suffix + "-layout-card-turns-setup-on")
            if dark { try layoutDriver.send("editor", .section("layout")); tick(); try capture(layoutHost, "new-vm-layout-dark.png") }
            try layoutDriver.send("layout-cards", .layoutExample(nil)); tick()
            try check(layoutDriver.state("selection", "source") == "bundled" && layoutDriver.state("selection", "layout").isEmpty
                      && layoutDriver.state("editor", "hasSetup") == "true", suffix + "-omarchy-default-keeps-setup-on")
            layoutHost.close()
        }
        for (section, name) in [("customise", "new-vm-customise-dark.png"), ("resources", "new-vm-pane-resources-dark.png"), ("access", "new-vm-access-dark.png")] {
            let sheetDriver = SetupUIAcceptanceDriver()
            let sheet = Host(VMEditor(model: enabledModel, profile: nil, saved: { _ in }), driver: sheetDriver, width: 640, height: 820, dark: true)
            tick(); try until { sheetDriver.scopes["selection"] != nil }
            try sheetDriver.send("editor", .name("Development"))
            try sheetDriver.send("selection", .source("bundled")); try sheetDriver.send("editor", .section(section)); tick()
            try capture(sheet, name); sheet.close()
        }
        let configureDriver = SetupUIAcceptanceDriver()
        let configure = Host(VMEditor(model: enabledModel, profile: profile, saved: { _ in }), driver: configureDriver, width: 640, height: 820, dark: true)
        tick(); try until { configureDriver.scopes["editor"] != nil }
        try configureDriver.send("editor", .section("access")); tick()
        try capture(configure, "configure-vm-dark.png"); configure.close()
        let homeHost = Host(ManagerView(model: enabledModel), driver: SetupUIAcceptanceDriver(), width: 1200, height: 960, dark: true)
        defer { homeHost.close() }; tick(); try capture(homeHost, "home-dark.png")
        enabledModel.snapshots = []; tick(); try capture(homeHost, "home-empty-dark.png")
        homeHost.close(); tick()
        let loadingHost = Host(ManagerLoadingView(), driver: SetupUIAcceptanceDriver(), width: 1200, height: 960, dark: true)
        tick(); try capture(loadingHost, "loading-dark.png"); loadingHost.close(); tick()
        try check(runtime.startRequests.isEmpty && !FileManager.default.fileExists(atPath: support.path), "zero-runtime-starts-or-support-access")
        try check(NSApplication.shared.windows.filter { $0.isVisible }.isEmpty, "zero-visible-windows")
        let report: [String: Any] = ["schema": 1, "checks": checks, "realExecution": false, "runtimeStarts": runtime.startRequests.count, "captures": service.captures, "images": images, "fakeSubmissions": enabled.submissions, "physicalInputTested": false, "visibleWindows": NSApplication.shared.windows.filter(\.isVisible).count, "gate": "unchanged-disabled", "onscreenWindows": 0, "activation": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"), options: .withoutOverwriting)
        print("setup-screen-acceptance: PASS (\(checks.count) checks; synthetic services only)")
    }
}
#endif
