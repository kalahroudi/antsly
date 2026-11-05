// swift-tools-version:6.0
import PackageDescription

// No third-party dependencies: keeps the binary small and the memory footprint low.
let package = Package(
    name: "antsly",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Antsly", targets: ["Antsly"]),
        .executable(name: "antsly-mcp", targets: ["antsly-mcp"]),
        .library(name: "AntslyKit", targets: ["AntslyKit"]),
    ],
    targets: [
        // UI-free core: everything that touches the system, parses output or decides something. Unit tested.
        .target(name: "AntslyKit"),
        // The menu bar + Dock app.
        .executableTarget(name: "Antsly", dependencies: ["AntslyKit"]),
        // Model Context Protocol server (stdio) so agents can drive the app's capabilities.
        .executableTarget(name: "antsly-mcp", dependencies: ["AntslyKit"]),
        .testTarget(name: "AntslyKitTests", dependencies: ["AntslyKit"]),
    ],
    swiftLanguageModes: [.v5]
)
