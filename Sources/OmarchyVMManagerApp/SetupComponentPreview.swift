#if DEBUG
import AppKit
import OmarchyProvisioningTerminalUI
import OmarchyVMManagerCore
import SwiftUI

/// Standalone, opt-in renderer runs before AppModel, instance locks, delegate
/// registration or windows. It uses actual components with labelled fixture data.
@MainActor enum SetupComponentPreview {
    static func render(to output: URL) throws {
        let parent = output.deletingLastPathComponent().resolvingSymlinksInPath().path
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let sharedTemporary = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path
        guard output.path.hasPrefix("/"), !output.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              parent == sharedTemporary || parent.hasPrefix(sharedTemporary + "/") || parent == temporary || parent.hasPrefix(temporary + "/"),
              output.pathExtension == "png", !FileManager.default.fileExists(atPath: output.path) else { throw ProvisioningReviewFailure.invalid }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let screen = ProvisioningTerminalScreen()
        screen.render(Data("Synthetic rendering fixture — no provisioning job\r\n\r\nPLAY [Rendering sample] ********************\r\n\u{001B}[32mok: [synthetic-fixture]\u{001B}[0m\r\n\u{001B}[33mchanged: [synthetic-fixture]\u{001B}[0m\r\n\r\nUnicode: → café ✓\r\n".utf8))
        let view = NSHostingView(rootView: content(screen).environment(\.colorScheme, .dark))
        view.frame = .init(x: 0, y: 0, width: 1120, height: 900)
        view.appearance = NSAppearance(named: .darkAqua)
        // A hidden backing window gives AppKit terminal drawing a scale/context.
        // It is never ordered, activated, attached to the manager or shown.
        let backing = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        backing.isReleasedWhenClosed = false; backing.contentView = view
        defer { backing.close() }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ProvisioningReviewFailure.unavailable }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // NSHostingView's bitmap cache omits the embedded layer-backed AppKit
        // terminal. Draw that actual Core Graphics view in the same bitmap.
        guard screen.search("Synthetic rendering fixture") == 1, let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw ProvisioningReviewFailure.unavailable }
        let rect = screen.view.convert(screen.view.bounds, to: view)
        NSGraphicsContext.saveGraphicsState()
        let context = graphics.cgContext
        context.saveGState()
        context.translateBy(x: rect.minX, y: view.bounds.height - rect.maxY)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        screen.view.draw(screen.view.bounds)
        context.restoreGState(); NSGraphicsContext.restoreGraphicsState()
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw ProvisioningReviewFailure.unavailable }
        try bytes.write(to: output, options: .withoutOverwriting)
    }
    private static func content(_ screen: ProvisioningTerminalScreen) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Developer setup · component preview").font(.largeTitle.bold())
            Text("Synthetic fixture · No VM, registry, credentials, dependency check or provisioning job").foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Source", selection: .constant("developer")) { Text("developer").tag("developer") }
                    ProvisioningFeatureSelectionView(selection: .constant(.init(enable: [.cli, .docker], disable: [.languages])), initiallyExpanded: true)
                    Text("Creating a VM saves its reviewed selection. Apply, custom tasks and sudo require separate review.").font(Theme.sans(13)).foregroundStyle(.secondary)
                    Label("Setup execution disabled", systemImage: "lock.fill").font(Theme.sans(13))
                }.frame(width: 400)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Terminal rendering sample · synthetic").font(Theme.sans(14, weight: .semibold))
                    ProvisioningNativeTerminal(screen: screen).frame(height: 440)
                    Text(screen.message).font(.caption).foregroundStyle(.secondary)
                    Text("This image checks component layout and rendering only. Full Setup/New VM interaction and real guest output remain separate acceptance checks.").font(Theme.sans(13)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding(30).frame(width: 1120, height: 900).background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
