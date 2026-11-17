// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSDPlayer",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "Cdstdec",
            path: "Sources/Cdstdec",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "DSDPlayer",
            dependencies: ["Cdstdec"],
            path: "Sources/DSDPlayer"
        ),
        .testTarget(
            name: "DSDPlayerTests",
            dependencies: ["DSDPlayer"],
            path: "Tests/DSDPlayerTests"
        )
    ]
)
