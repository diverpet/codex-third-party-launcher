// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexThirdParty",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Launcher", targets: ["Launcher"])],
    targets: [
        .target(name: "GatewayCore"),
        .target(name: "DesktopInstallation"),
        .executableTarget(name: "Launcher", dependencies: ["GatewayCore", "DesktopInstallation"]),
        .executableTarget(name: "GatewayChecks", dependencies: ["GatewayCore", "DesktopInstallation"], path: "Tests/GatewayCoreTests"),
    ]
)
