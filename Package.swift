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
    dependencies: [
        // In-app auto-update. Only the app target depends on it; Core stays dependency-free.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "ClaudeWatchCore",
            path: "Sources/ClaudeWatchCore"
        ),
        .executableTarget(
            name: "ClaudeWatch",
            dependencies: [
                "ClaudeWatchCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ClaudeWatch"
        ),
        .testTarget(
            name: "ClaudeWatchTests",
            dependencies: ["ClaudeWatchCore"],
            path: "Tests/ClaudeWatchTests"
        ),
    ]
)
