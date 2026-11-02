// swift-tools-version: 6.0
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
    dependencies: [.package(path: ".build/runtime-source/macos"), .package(path: "Vendor/dev-vm")],
    targets: [
        .target(name: "OmarchyVMManagerCore", dependencies: [
            .product(name: "TryOmarchyKitClient", package: "macos"),
            .product(name: "DevVMProvisioningCore", package: "dev-vm")
        ], resources: [.process("Resources")]),
        .executableTarget(name: "OmarchyVMManagerApp", dependencies: ["OmarchyVMManagerCore"]),
        .executableTarget(name: "OmarchyVMCLI", dependencies: ["OmarchyVMManagerCore"]),
        .executableTarget(name: "OmarchyVMStorageHelper", dependencies: ["OmarchyVMManagerCore"]),
        .executableTarget(name: "OmarchyVMProvisioningHelper", dependencies: ["OmarchyVMManagerCore"]),
        .executableTarget(name: "OmarchyProvisioningLaunchFixture", dependencies: ["OmarchyVMManagerCore"], path: "Tests/ProvisioningLaunchFixture"),
        .testTarget(name: "OmarchyVMManagerCoreTests", dependencies: ["OmarchyVMManagerCore"])
    ],
    swiftLanguageModes: [.v6]
)
