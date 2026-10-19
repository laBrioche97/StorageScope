// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StorageScope",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StorageCore", targets: ["StorageCore"]),
        .executable(name: "StorageScope", targets: ["StorageScope"]),
        .executable(name: "StorageCoreTests", targets: ["StorageCoreTests"])
    ],
    // Sparkle 2.9.6, pinned to its immutable source revision.
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", revision: "ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a")],
    targets: [
        .target(name: "StorageCore"),
        .executableTarget(
            name: "StorageScope",
            dependencies: ["StorageCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "StorageCoreTests",
            dependencies: ["StorageCore"],
            path: "Tests/StorageCoreTests"
        )
    ]
)
