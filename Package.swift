// swift-tools-version: 5.9
// SwiftPM manifest: the moderation engine as a portable library plus a thin HTTP service target.

import PackageDescription

let package = Package(
    name: "WayzyyModeration",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "WayzyyModeration", targets: ["WayzyyModeration"]),
        .executable(name: "wayzyy-moderate", targets: ["ModerationService"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "WayzyyModeration",
            path: "WayzyyChat/Moderation"
        ),
        .executableTarget(
            name: "ModerationService",
            dependencies: [
                "WayzyyModeration",
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/ModerationService"
        ),
        .testTarget(
            name: "WayzyyModerationTests",
            dependencies: ["WayzyyModeration"],
            path: "Tests/WayzyyModerationTests"
        ),
    ]
)
