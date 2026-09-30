// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SimpleTokenKit",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "Features", targets: ["Features"]),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "DesignSystem", resources: [.copy("Resources/logos")]),
        .target(name: "Features", dependencies: ["Core", "DesignSystem"]),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
