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
        .executableTarget(name: "Dropy", dependencies: ["DropyCore"]),
        .testTarget(name: "DropyCoreTests", dependencies: ["DropyCore"]),
    ]
)
