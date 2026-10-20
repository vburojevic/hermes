// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HermesKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "HermesKit", targets: ["HermesKit"]),
        // Push notifications: what the app shares with its extensions (crypto, notices, Live Activities).
        .library(name: "HermesPush", targets: ["HermesPush"]),
        .library(name: "HermesMarkdown", targets: ["HermesMarkdown"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "HermesKit",
            dependencies: ["HermesPush", "HermesMarkdown"],
            // The widget contract: schemas, catalogue, semantic rules and examples (docs/widgets.md).
            resources: [.copy("Widgets/Spec")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "HermesPush",
            resources: [.process("Resources")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "HermesMarkdown",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "HermesKitTests",
            dependencies: ["HermesKit", "HermesPush", "HermesMarkdown"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "HermesMarkdownTests",
            dependencies: ["HermesMarkdown"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
