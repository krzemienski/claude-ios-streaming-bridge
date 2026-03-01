// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StreamingBridge",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "StreamingBridge",
            targets: ["StreamingBridge"]
        ),
    ],
    targets: [
        .target(
            name: "StreamingBridge",
            path: "Sources/StreamingBridge"
        ),
    ]
)
