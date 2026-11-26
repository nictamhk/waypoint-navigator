// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NavigationCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NavigationCore", targets: ["NavigationCore"]),
    ],
    targets: [
        .target(
            name: "NavigationCore",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "NavigationCoreTests",
            dependencies: ["NavigationCore"]
        ),
    ]
)
