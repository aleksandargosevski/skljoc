// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Skljoc",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Skljoc",
            dependencies: ["SkljocCore"],
            path: "Sources/Skljoc",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "SkljocCore",
            path: "Sources/SkljocCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SkljocCoreTests",
            dependencies: ["SkljocCore"],
            path: "Tests/SkljocCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
