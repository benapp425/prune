// swift-tools-version:6.0
import PackageDescription

// Debug builds get the launch hooks used for screenshots (PRUNE_HOOKS). Release builds don't.
let hooks: [SwiftSetting] = [.define("PRUNE_HOOKS", .when(configuration: .debug))]

let package = Package(
    name: "Prune",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PruneCore", swiftSettings: hooks),
        .executableTarget(name: "Prune", dependencies: ["PruneCore"], swiftSettings: hooks),
        .executableTarget(name: "prune-cli", dependencies: ["PruneCore"]),
        .testTarget(name: "PruneCoreTests", dependencies: ["PruneCore"]),
    ],
    swiftLanguageModes: [.v5]
)
