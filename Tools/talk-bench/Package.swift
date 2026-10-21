// swift-tools-version: 6.2
import PackageDescription

// The Talk noise bench (docs/voice.md §12): noise under a Bot reply, heard by the Mac's own
// on-device transcriber in real time, scored for the barge-in and end-of-turn decisions.
let package = Package(
    name: "TalkBench",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../../Packages/HermesKit")],
    targets: [
        .executableTarget(
            name: "talk-bench",
            dependencies: [.product(name: "HermesKit", package: "HermesKit")],
            path: "Sources/TalkBench"
        ),
    ],
    swiftLanguageModes: [.v6]
)
