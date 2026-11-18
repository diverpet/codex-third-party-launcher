// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexThirdParty",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Launcher", targets: ["Launcher"])],
    targets: [
        .target(name: "GatewayCore"),
        .executableTarget(name: "Launcher", dependencies: ["GatewayCore"]),
        .executableTarget(name: "GatewayChecks", dependencies: ["GatewayCore"], path: "Tests/GatewayCoreTests"),
    ]
)
