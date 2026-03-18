// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SimView",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "simviewerd", targets: ["SimViewDaemon"]),
        .executable(name: "simviewctl", targets: ["SimViewCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SimViewCore",
            dependencies: []
        ),
        .executableTarget(
            name: "SimViewDaemon",
            dependencies: [
                "SimViewCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ]
        ),
        .executableTarget(
            name: "SimViewCLI",
            dependencies: [
                "SimViewCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
