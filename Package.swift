// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MemeMe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MemeMe", targets: ["MemeMeApp"]),
        .library(name: "MemeMeCore", targets: ["MemeMeCore"]),
    ],
    targets: [
        .target(
            name: "MemeMeCore",
            path: "Sources/MemeMeCore"
        ),
        .executableTarget(
            name: "MemeMeApp",
            dependencies: ["MemeMeCore"],
            path: "Sources/MemeMeApp"
        ),
        .testTarget(
            name: "MemeMeCoreTests",
            dependencies: ["MemeMeCore"],
            path: "Tests/MemeMeCoreTests"
        ),
        .testTarget(
            name: "MemeMeAppTests",
            dependencies: ["MemeMeApp", "MemeMeCore"],
            path: "Tests/MemeMeAppTests"
        ),
    ]
)
