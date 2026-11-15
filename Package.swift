// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSDPlayer",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "DSDPlayer",
            path: "Sources/DSDPlayer"
        ),
        .testTarget(
            name: "DSDPlayerTests",
            dependencies: ["DSDPlayer"],
            path: "Tests/DSDPlayerTests"
        )
    ]
)
