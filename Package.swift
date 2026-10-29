// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dictation",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "DictationCore"
        ),
        .executableTarget(
            name: "DictationApp",
            dependencies: ["DictationCore"]
        ),
        .testTarget(
            name: "DictationCoreTests",
            dependencies: ["DictationCore"]
        )
    ]
)
