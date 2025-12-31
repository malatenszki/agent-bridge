// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentBridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "agent-bridge-daemon", targets: ["AgentBridgeDaemon"]),
        .executable(name: "agent-bridge", targets: ["AgentBridgeCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AgentBridgeDaemon",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/AgentBridgeDaemon"
        ),
        .executableTarget(
            name: "AgentBridgeCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AgentBridgeCLI"
        )
    ]
)
