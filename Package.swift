// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmarchyVMManager",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "OmarchyVMManager", targets: ["OmarchyVMManagerApp"]),
        .executable(name: "omarchy-vm", targets: ["OmarchyVMCLI"]),
        .library(name: "OmarchyVMManagerCore", targets: ["OmarchyVMManagerCore"]),
        .executable(name: "OmarchyVMStorageHelper", targets: ["OmarchyVMStorageHelper"])
    ],
    dependencies: [.package(path: "Vendor/try-omarchy/macos")],
    targets: [
        .target(name: "OmarchyVMManagerCore", dependencies: [
            .product(name: "TryOmarchyKitClient", package: "macos")
        ], resources: [.process("Resources")]),
        .executableTarget(name: "OmarchyVMManagerApp", dependencies: ["OmarchyVMManagerCore"]),
        .executableTarget(name: "OmarchyVMCLI", dependencies: ["OmarchyVMManagerCore"]),
        .executableTarget(name: "OmarchyVMStorageHelper", dependencies: ["OmarchyVMManagerCore"]),
        .testTarget(name: "OmarchyVMManagerCoreTests", dependencies: ["OmarchyVMManagerCore"])
    ],
    swiftLanguageModes: [.v6]
)
