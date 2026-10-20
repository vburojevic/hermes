// swift-tools-version: 6.0
import PackageDescription

// Mac-only pieces of the app, kept out of iOS builds: Sparkle (the Developer ID DMG's updater)
// is linked only when building for macOS.
let package = Package(
    name: "HermesMacSupport",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "HermesMacSupport", targets: ["HermesMacSupport"]),
    ],
    dependencies: [
        // The studio's pinned Sparkle.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .target(
            name: "HermesMacSupport",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ]
        ),
    ]
)
