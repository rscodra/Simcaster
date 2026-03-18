// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Simcaster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "simcasterd", targets: ["SimcasterDaemon"]),
        .executable(name: "simcasterctl", targets: ["SimcasterCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SimcasterCore",
            dependencies: []
        ),
        .executableTarget(
            name: "SimcasterDaemon",
            dependencies: [
                "SimcasterCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ]
        ),
        .executableTarget(
            name: "SimcasterCLI",
            dependencies: [
                "SimcasterCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
