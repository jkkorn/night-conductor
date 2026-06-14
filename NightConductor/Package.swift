// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NightConductor",
    platforms: [.macOS(.v15)], // MeshGradient, richer SwiftUI effects (glass gated to 26)
    targets: [
        .executableTarget(
            name: "NightConductor",
            path: "Sources/NightConductor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NightConductorTests",
            dependencies: ["NightConductor"],
            path: "Tests/NightConductorTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
