// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OmarchyVMManager",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "OmarchyVMManager", targets: ["OmarchyVMManagerApp"]),
        .executable(name: "omarchy-vm", targets: ["OmarchyVMCLI"]),
        .library(name: "OmarchyVMManagerCore", targets: ["OmarchyVMManagerCore"]),
        .executable(name: "OmarchyVMStorageHelper", targets: ["OmarchyVMStorageHelper"]),
        .executable(name: "OmarchyVMProvisioningHelper", targets: ["OmarchyVMProvisioningHelper"]),
        .executable(name: "OmarchyProvisioningLaunchFixture", targets: ["OmarchyProvisioningLaunchFixture"])
    ],
    dependencies: [.package(path: ".build/runtime-source/macos"), .package(path: "Vendor/dev-vm"), .package(path: "Vendor/SwiftTerm")],
    targets: [
        .target(name: "OmarchyVMManagerCore", dependencies: [
            .product(name: "TryOmarchyKitClient", package: "macos"),
            .product(name: "DevVMProvisioningCore", package: "dev-vm")
        ], resources: [.process("Resources")]),
        .target(name: "OmarchyProvisioningTerminalUI", dependencies: ["OmarchyVMManagerCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "OmarchyVMManagerApp", dependencies: ["OmarchyVMManagerCore", "OmarchyProvisioningTerminalUI"]),
        .executableTarget(name: "OmarchyVMCLI", dependencies: ["OmarchyVMManagerCore"]),
        .executableTarget(name: "OmarchyVMStorageHelper", dependencies: ["OmarchyVMManagerCore"]),
        .executableTarget(name: "OmarchyVMProvisioningHelper", dependencies: ["OmarchyVMManagerCore"]),
        .executableTarget(name: "OmarchyProvisioningLaunchFixture", dependencies: ["OmarchyVMManagerCore"], path: "Tests/ProvisioningLaunchFixture"),
        .testTarget(name: "OmarchyVMManagerCoreTests", dependencies: ["OmarchyVMManagerCore", "OmarchyProvisioningTerminalUI", .product(name: "SwiftTerm", package: "SwiftTerm")])
    ],
    swiftLanguageModes: [.v6]
)
