// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dropy",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Dropy", targets: ["Dropy"]),
        .library(name: "DropyCore", targets: ["DropyCore"]),
    ],
    targets: [
        .target(name: "DropyCore"),
        // CoreGraphics' private virtual-display classes, for the Stage.
        .target(name: "DropyStageShim", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(name: "Dropy", dependencies: ["DropyCore", "DropyStageShim"]),
        .testTarget(name: "DropyCoreTests", dependencies: ["DropyCore"]),
    ]
)
