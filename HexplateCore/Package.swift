// swift-tools-version:6.0
import PackageDescription

// Hexplate's logic, kept apart from the UI so `swift test` runs it on the Mac.
let package = Package(
    name: "HexplateCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "HexplateCore", targets: ["HexplateCore"])],
    targets: [
        .target(name: "HexplateCore"),
        .testTarget(
            name: "HexplateCoreTests",
            dependencies: ["HexplateCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
