// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Prune",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PruneCore"),
        .executableTarget(name: "Prune", dependencies: ["PruneCore"]),
        .executableTarget(name: "prune-cli", dependencies: ["PruneCore"]),
        .testTarget(name: "PruneCoreTests", dependencies: ["PruneCore"]),
    ],
    swiftLanguageModes: [.v5]
)
