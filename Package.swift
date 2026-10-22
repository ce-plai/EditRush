// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EditRush",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "EditRush", targets: ["EditRush"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "EditRushCore", path: "Sources/EditRushCore"),
        .executableTarget(
            name: "EditRush",
            dependencies: ["EditRushCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/EditRush",
            // Sparkle.framework is embedded in EditRush.app/Contents/Frameworks by Scripts/build_app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "EditRushCoreTests", dependencies: ["EditRushCore"], path: "Tests/EditRushCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
