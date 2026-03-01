// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "StreamingBridgeExample",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../"),
    ],
    targets: [
        .executableTarget(
            name: "ExampleApp",
            dependencies: [
                .product(name: "StreamingBridge", package: "StreamingBridge"),
            ],
            path: "Sources/ExampleApp"
        ),
    ]
)
