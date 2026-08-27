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
    targets: [
        .target(name: "StorageCore"),
        .executableTarget(
            name: "StorageScope",
            dependencies: ["StorageCore"]
        ),
        .executableTarget(
            name: "StorageCoreTests",
            dependencies: ["StorageCore"],
            path: "Tests/StorageCoreTests"
        )
    ]
)
