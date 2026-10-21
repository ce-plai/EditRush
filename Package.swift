// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EditRush",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "EditRush", targets: ["EditRush"]),
    ],
    targets: [
        .target(name: "EditRushCore", path: "Sources/EditRushCore"),
        .executableTarget(name: "EditRush", dependencies: ["EditRushCore"], path: "Sources/EditRush"),
        .testTarget(name: "EditRushCoreTests", dependencies: ["EditRushCore"], path: "Tests/EditRushCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
