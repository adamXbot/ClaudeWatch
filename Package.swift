// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeWatch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Pure, headless logic (parsing, scanning, HTML rendering) — unit-testable
        // without launching the UI. The SwiftUI app links against it.
        .library(name: "ClaudeWatchCore", targets: ["ClaudeWatchCore"]),
        .executable(name: "ClaudeWatch", targets: ["ClaudeWatch"]),
    ],
    targets: [
        .target(
            name: "ClaudeWatchCore",
            path: "Sources/ClaudeWatchCore"
        ),
        .executableTarget(
            name: "ClaudeWatch",
            dependencies: ["ClaudeWatchCore"],
            path: "Sources/ClaudeWatch"
        ),
        .testTarget(
            name: "ClaudeWatchTests",
            dependencies: ["ClaudeWatchCore"],
            path: "Tests/ClaudeWatchTests"
        ),
    ]
)
