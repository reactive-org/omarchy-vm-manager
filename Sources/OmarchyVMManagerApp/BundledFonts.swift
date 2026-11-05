import AppKit
import CoreText

/// Registers the design's typefaces (Inter and JetBrains Mono, SIL OFL 1.1) for this process only.
/// Missing files leave the system fonts in place, so text never disappears.
enum BundledFonts {
    static let files = ["Inter-Regular.ttf", "Inter-Medium.ttf", "Inter-SemiBold.ttf", "JetBrainsMono-Regular.ttf", "JetBrainsMono-Medium.ttf"]

    static func register() {
        guard let directory = location() else { return }
        let urls = files.map { directory.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    private static func location() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts"), FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        #if DEBUG
        // Offscreen acceptance runs the unbundled debug binary from the source tree.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Fonts")
        if FileManager.default.fileExists(atPath: source.path) { return source }
        #endif
        return nil
    }
}

/// Artwork shipped in Contents/Resources. Offscreen acceptance runs the unbundled debug
/// binary, so debug builds fall back to the same files in App/Assets.
enum AppArtwork {
    static func image(_ name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Assets/\(name).png")
        return NSImage(contentsOf: source)
        #else
        return nil
        #endif
    }
}
