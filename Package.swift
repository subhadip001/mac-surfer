// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoiceMac",
            path: "Sources/VoiceMac",
            swiftSettings: [
                // Language mode 5: we use actors/async throughout, but strict
                // Sendable enforcement across AppKit/AX C APIs is more noise
                // than signal for a single-user app.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ]
)
