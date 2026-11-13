// swift-tools-version: 6.2
import PackageDescription
// Library-only export: one reviewed source bound, no executable/plugin/dependency.
let package = Package(name: "SwiftTerm", platforms: [.macOS(.v15)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", path: "Sources/SwiftTerm",
        exclude: ["iOS", "Documentation.docc", "LocalProcess.swift", "HeadlessTerminal.swift", "Pty.swift", "Mac/MacLocalTerminalView.swift", "Mac/README.md", "Apple/Metal/Shaders.metal"])],
    swiftLanguageModes: [.v6])
