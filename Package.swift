// swift-tools-version: 5.9
//
// The moderation engine as a portable, dependency-free library plus a JSON adapter.
//
// There is deliberately no web-framework dependency. The adapter speaks newline-delimited
// JSON over stdin/stdout, which means:
//   * `swift build` and `swift test` work offline, so CI needs no package resolution
//   * the engine can be driven by any transport — Hummingbird, Vapor, gRPC, a Lambda
//     handler or a sidecar process — by wrapping the adapter rather than modifying it
//   * the request/response contract is exercised by tests, not by a running server

import PackageDescription

let package = Package(
    name: "WayzyyModeration",
    // `platforms` constrains Apple platforms only; Linux is supported and is where the service
    // actually runs. CI builds this package inside a Swift Linux container for that reason.
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "WayzyyModeration", targets: ["WayzyyModeration"]),
        .executable(name: "wayzyy-moderate", targets: ["ModerationService"]),
        .executable(name: "wayzyy-moderate-http", targets: ["ModerationHTTP"]),
        .executable(name: "wayzyy-invariants", targets: ["InvariantChecks"]),
        .executable(name: "CoconutTest", targets: ["CoconutTest"]),
    ],
    targets: [
        .target(
            name: "WayzyyModeration",
            path: "WayzyyChat/Moderation"
        ),
        .executableTarget(
            name: "ModerationService",
            dependencies: ["WayzyyModeration"],
            path: "Sources/ModerationService"
        ),
        // The HTTP front end. On POSIX sockets rather than a web framework so that the package
        // stays dependency-free and CI keeps working with no network — see HTTPServer.swift.
        .executableTarget(
            name: "ModerationHTTP",
            dependencies: ["WayzyyModeration"],
            path: "Sources/ModerationHTTP"
        ),
        // The invariant gate. An executable rather than a test target because XCTest
        // requires a full Xcode toolchain, which CI runners frequently lack; this runs
        // anywhere `swift build` runs and exits non-zero on any violation.
        .executableTarget(
            name: "InvariantChecks",
            dependencies: ["WayzyyModeration"],
            path: "Sources/InvariantChecks"
        ),
        .executableTarget(
            name: "CoconutTest",
            dependencies: ["WayzyyModeration"],
            path: "Sources/CoconutTest"
        ),
    ]
)
